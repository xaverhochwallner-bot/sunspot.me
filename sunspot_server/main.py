from flask import Flask, jsonify, request, Response, stream_with_context
from flask_cors import CORS
from shapely.geometry import Polygon, box as shapely_box, mapping
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely.strtree import STRtree
from datetime import datetime
import osmium
import pickle
import pytz
import math
import os
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading
import pysolar.solar as ps

app = Flask(__name__)
CORS(app)

# Path to the local OSM PBF file — place it next to main.py
PBF_PATH = os.path.join(os.path.dirname(__file__), "austria-latest.osm.pbf")

# ---------------------------------------------------------------------------
# Shadow cache — keyed by (hour, month, day, zoom, lat_grid, lon_grid)
# Stores sunlit_filtered geometry; viewport overlay is recomputed cheaply on hit
# ---------------------------------------------------------------------------
_shadow_cache = {}
MAX_CACHE     = 2000

# Cache grid snaps lat/lon so nearby viewports share a cached result.
# Coarser grid at low zoom → many more cache hits when panning at z12-13.
def _cache_grid(zoom):
    if zoom <= 12: return 0.05   # ~5 km  — whole-city tile
    if zoom == 13: return 0.02   # ~2 km
    if zoom == 14: return 0.01   # ~1 km
    return 0.005                 # zoom ≥ 15 — ~500 m

def _cache_key(hour, month, day, lat, lon, zoom):
    g = _cache_grid(zoom)
    return (hour, month, day, zoom,
            round(round(lat / g) * g, 6),
            round(round(lon / g) * g, 6))


# ---------------------------------------------------------------------------
# Sun position
# ---------------------------------------------------------------------------

def get_sun_angles(lat, lon, at_time):
    at_time_utc = at_time.astimezone(pytz.utc)
    elevation = ps.get_altitude(lat, lon, at_time_utc)
    azimuth   = ps.get_azimuth(lat, lon, at_time_utc)
    if elevation < 0:
        elevation = 0
    return elevation, azimuth


# ---------------------------------------------------------------------------
# Building data — loaded once at startup from local PBF
# ---------------------------------------------------------------------------

_buildings_polys   = []   # list of Shapely Polygon (full detail)
_buildings_heights = []   # list of float
_buildings_tree    = None # STRtree spatial index

# Pre-simplified polygon sets built at startup — keyed by zoom level.
# Same heights as _buildings_heights; only geometry is simplified.
# Tolerances chosen so shadows are indistinguishable at each zoom level.
_simplified_polys  = {}   # zoom → list[Polygon]
_simplified_trees  = {}   # zoom → STRtree

PRE_SIMPLIFY = {
    12: 0.00020,  # ~20 m — buildings become pentagons
    13: 0.00008,  # ~8 m
    14: 0.00003,  # ~3 m
}

MIN_BUILDING_AREA = 5e-9  # ~25 m²

# Bounding box filter applied during parsing — keeps only relevant buildings
# Covers greater Vienna area; expand if you want to support other cities
LOAD_BBOX = (48.05, 16.10, 48.40, 16.65)  # (min_lat, min_lon, max_lat, max_lon)



# Typical heights by building type — used when no explicit height/levels tag exists
_BUILDING_TYPE_HEIGHTS = {
    # Low structures
    "garage":             3.0,
    "garages":            3.0,
    "carport":            3.0,
    "shed":               3.0,
    "hut":                3.0,
    "kiosk":              3.0,
    "roof":               4.0,
    "canopy":             4.0,
    # Single-family residential
    "house":              7.0,
    "detached":           7.0,
    "semidetached_house": 7.0,
    "bungalow":           4.0,
    "farm":               6.0,
    "farm_auxiliary":     5.0,
    "barn":               8.0,
    "greenhouse":         4.0,
    # Multi-family / dense urban (Vienna Gründerzeit default)
    "apartments":        16.0,
    "residential":       16.0,
    "dormitory":         12.0,
    # Commercial / office
    "commercial":        10.0,
    "retail":             6.0,
    "shop":               6.0,
    "office":            20.0,
    "hotel":             20.0,
    # Civic / public
    "school":            10.0,
    "university":        12.0,
    "hospital":          18.0,
    "public":            10.0,
    "government":        12.0,
    # Industrial
    "industrial":         9.0,
    "warehouse":          9.0,
    "storage_tank":      10.0,
    "service":            5.0,
    # Religious
    "church":            18.0,
    "cathedral":         25.0,
    "chapel":            10.0,
    "mosque":            15.0,
    "synagogue":         12.0,
    "temple":            12.0,
    # Misc
    "stadium":           20.0,
    "sports_hall":       10.0,
    "train_station":     15.0,
    "transportation":    10.0,
    "parking":            8.0,
}

LEVELS_HEIGHT  = 3.5   # metres per above-ground level (Austrian/German standard)
ROOF_HEIGHT    = 1.5   # metres per roof level
DEFAULT_HEIGHT = 14.0  # Vienna dense urban default — ~4-storey equivalent

# Self-occlusion: buildings above this height act as shadow occluders.
# Shorter buildings whose centroid falls within an occluder's shadow are skipped —
# they receive no direct sunlight and would otherwise extend the dark zone.
OCCLUDER_HEIGHT = 18.0  # m (~5 storeys)


def _parse_height(tags):
    try:
        if "height" in tags:
            return float(str(tags["height"]).replace("m", "").strip())

        levels     = None
        roof_extra = 0.0

        if "building:levels" in tags:
            levels = float(tags["building:levels"])
        elif "levels" in tags:
            levels = float(tags["levels"])

        if "roof:levels" in tags:
            roof_extra = float(tags["roof:levels"]) * ROOF_HEIGHT

        if levels is not None:
            return max(levels * LEVELS_HEIGHT + roof_extra, 2.0)

        # No numeric tags — fall back to building-type lookup
        btype = str(tags.get("building", "")).lower()
        if btype and btype != "yes":
            return _BUILDING_TYPE_HEIGHTS.get(btype, DEFAULT_HEIGHT)

    except (ValueError, KeyError):
        pass
    return DEFAULT_HEIGHT


class BuildingHandler(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.main_polys    = []   # ways with building=* (full outlines)
        self.main_heights  = []
        self.part_polys    = []   # ways with building:part=* (individual sections)
        self.part_heights  = []
        self._bbox         = LOAD_BBOX

    def way(self, w):
        has_building = "building" in w.tags
        has_part     = "building:part" in w.tags
        if not has_building and not has_part:
            return
        try:
            coords = [(n.lon, n.lat) for n in w.nodes if n.location.valid()]
            if len(coords) < 3:
                return

            # Bbox pre-filter
            min_lat_b, min_lon_b, max_lat_b, max_lon_b = self._bbox
            lats = [c[1] for c in coords]
            lons = [c[0] for c in coords]
            if max(lats) < min_lat_b or min(lats) > max_lat_b:
                return
            if max(lons) < min_lon_b or min(lons) > max_lon_b:
                return

            poly = Polygon(coords)
            if not poly.is_valid:
                poly = poly.buffer(0)
            if poly.is_empty or poly.area < MIN_BUILDING_AREA:
                return
            poly = poly.simplify(0.00002, preserve_topology=False)
            if poly.is_empty:
                return

            if has_part:
                self.part_polys.append(poly)
                self.part_heights.append(_parse_height(w.tags))
            else:
                self.main_polys.append(poly)
                self.main_heights.append(_parse_height(w.tags))
        except Exception:
            pass


CACHE_PATH = os.path.join(os.path.dirname(__file__), "buildings_cache.pkl")

def load_buildings(pbf_path):
    global _buildings_polys, _buildings_heights, _buildings_tree

    # Use cache if it exists and is newer than the PBF
    if os.path.exists(CACHE_PATH):
        if os.path.getmtime(CACHE_PATH) > os.path.getmtime(pbf_path):
            print("Loading buildings from cache ...")
            with open(CACHE_PATH, "rb") as f:
                _buildings_polys, _buildings_heights = pickle.load(f)
            _buildings_tree = STRtree(_buildings_polys)
            print(f"Loaded {len(_buildings_polys):,} buildings from cache — ready.")
            _build_simplified_sets()
            return

    print(f"Parsing buildings from {pbf_path} (first run, will cache) ...")
    handler = BuildingHandler()
    handler.apply_file(pbf_path, locations=True)

    # Remove main building outlines that have building:part children inside them.
    # Parts have specific per-section heights; the parent outline is redundant and
    # causes double-counting of shadows.
    print(f"Parsed {len(handler.main_polys):,} building outlines + "
          f"{len(handler.part_polys):,} building parts — deduplicating ...")
    if handler.part_polys:
        part_tree = STRtree(handler.part_polys)
        filtered_main_polys   = []
        filtered_main_heights = []
        for poly, height in zip(handler.main_polys, handler.main_heights):
            candidates = part_tree.query(poly)
            # If any part is contained within this outline, skip the outline
            has_parts = any(
                handler.part_polys[i].within(poly)
                for i in candidates
            )
            if not has_parts:
                filtered_main_polys.append(poly)
                filtered_main_heights.append(height)
    else:
        filtered_main_polys   = handler.main_polys
        filtered_main_heights = handler.main_heights

    _buildings_polys   = filtered_main_polys + handler.part_polys
    _buildings_heights = filtered_main_heights + handler.part_heights
    print(f"After dedup: {len(_buildings_polys):,} buildings kept.")

    print(f"Saving cache to {CACHE_PATH} ...")
    with open(CACHE_PATH, "wb") as f:
        pickle.dump((_buildings_polys, _buildings_heights), f)

    _buildings_tree = STRtree(_buildings_polys)
    print(f"Loaded {len(_buildings_polys):,} buildings — spatial index ready.")
    _build_simplified_sets()


def _build_simplified_sets():
    """Build pre-simplified polygon sets for low zoom levels.
    Called once after buildings are loaded. Pays the simplification cost
    upfront so per-request parallel_union runs on smaller geometries.
    """
    global _simplified_polys, _simplified_trees
    for zoom, tol in PRE_SIMPLIFY.items():
        print(f"Pre-simplifying buildings for zoom {zoom} (tol={tol}) ...")
        simplified = []
        for p in _buildings_polys:
            s = p.simplify(tol, preserve_topology=True)
            simplified.append(s if (s and not s.is_empty and s.is_valid) else p)
        _simplified_polys[zoom] = simplified
        _simplified_trees[zoom] = STRtree(simplified)
        print(f"  zoom {zoom}: {len(simplified):,} polygons ready.")


def get_buildings_for_viewport(min_lat, min_lon, max_lat, max_lon, zoom=None):
    bbox = shapely_box(min_lon, min_lat, max_lon, max_lat)
    # Use pre-simplified set when available — same shadow result, faster union
    if zoom is not None and zoom in _simplified_polys:
        polys = _simplified_polys[zoom]
        tree  = _simplified_trees[zoom]
    else:
        polys = _buildings_polys
        tree  = _buildings_tree
    indices = tree.query(bbox)
    return [(polys[i], _buildings_heights[i]) for i in indices
            if polys[i].intersects(bbox)]


# ---------------------------------------------------------------------------
# Shadow projection
# ---------------------------------------------------------------------------

def project_shadow(polygon, height, elevation_deg, azimuth_deg):
    try:
        if elevation_deg <= 0 or height <= 0:
            return None

        azimuth   = math.radians(azimuth_deg)
        elevation = math.radians(elevation_deg)

        shadow_length = height / math.tan(elevation)

        lat_center         = polygon.centroid.y
        meters_per_deg_lat = 111320.0
        meters_per_deg_lon = 111320.0 * math.cos(math.radians(lat_center))

        dx = (-shadow_length * math.sin(azimuth)) / meters_per_deg_lon
        dy = (-shadow_length * math.cos(azimuth)) / meters_per_deg_lat

        if not polygon.is_valid:
            polygon = polygon.buffer(0)

        coords        = list(polygon.exterior.coords[:-1])
        n             = len(coords)
        shadow_coords = [(x + dx, y + dy) for x, y in coords]

        parts = [polygon, Polygon(shadow_coords)]
        for i in range(n):
            j    = (i + 1) % n
            quad = Polygon([coords[i], coords[j], shadow_coords[j], shadow_coords[i]])
            if quad.is_valid and not quad.is_empty:
                parts.append(quad)

        result = unary_union(parts)
        return result if result.is_valid else result.buffer(0)

    except Exception as e:
        print(f"Shadow projection error: {e}")
        return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _union_chunk(chunk):
    return unary_union(chunk)

def parallel_union(geoms, chunk_size=150, max_workers=8):
    """Union a large list of geometries in parallel chunks, then merge results."""
    if not geoms:
        return None
    if len(geoms) <= chunk_size:
        return unary_union(geoms)
    chunks = [geoms[i:i + chunk_size] for i in range(0, len(geoms), chunk_size)]
    with ThreadPoolExecutor(max_workers=min(len(chunks), max_workers)) as ex:
        partial = list(ex.map(_union_chunk, chunks))
    return unary_union(partial)


def round_coords(obj, precision=5):
    """Recursively round all floats in a GeoJSON geometry dict."""
    if isinstance(obj, list):
        return [round_coords(v, precision) for v in obj]
    if isinstance(obj, float):
        return round(obj, precision)
    return obj


def _min_building_area(zoom):
    """Minimum building footprint (deg²) to include at a given zoom level.
    Only truly tiny structures (sheds, garages) are skipped at low zoom.
    Typical Vienna apartment block (~300 m²) is always included.
    """
    if zoom >= 15: return 5e-9    # ~40 m²  — everything
    if zoom == 14: return 1.5e-8  # ~125 m² — skip tiny sheds
    if zoom == 13: return 3e-8    # ~250 m² — skip garages/sheds
    return 6e-8                   # zoom ≤ 12 — ~500 m², skip small outbuildings


def _min_sunlit_area(zoom):
    """Minimum sunlit patch area (deg²) to keep at a given zoom level.
    Small sunlit spots vanish when zoomed out and reappear when zoomed in.
    Interpolated in log-space so the scaling feels proportional.
      zoom 16+ → ~10 m²     — every courtyard / alley visible
      zoom 12  → ~20,000 m² — only large open sunny areas survive
    """
    z_low, z_high = 12, 16
    a_low, a_high = 2e-6, 1e-9   # deg²  (low zoom → large threshold)
    t = max(0.0, min(1.0, (zoom - z_low) / (z_high - z_low)))
    log_a = math.log10(a_low) + t * (math.log10(a_high) - math.log10(a_low))
    return 10 ** log_a


def _simplify_tolerance(zoom):
    """Geometry simplification tolerance (deg) for a given zoom level.
    More simplification at low zoom merges tiny sunlit gaps into shadow;
    less at high zoom preserves every narrow street or courtyard.
      zoom 16+ → 0.00003 (~3 m)
      zoom 12  → 0.0008  (~90 m)
    """
    z_low, z_high = 12, 16
    t_low, t_high = 0.0008, 0.00003
    t = max(0.0, min(1.0, (zoom - z_low) / (z_high - z_low)))
    return t_low + t * (t_high - t_low)


def _gap_fill(zoom):
    """Morphological close distance (deg) for shadow merging and edge rounding.
    At low zoom: large value — rounds sharp edges and bridges nearby shadow patches
                 into smooth connected blobs.
    At high zoom: small value — only fills hairline gaps between adjacent buildings.
      zoom 11  → ~0.0020 deg (~200 m) — very round, heavily merged
      zoom 16+ → ~0.00003 deg (~3 m)  — tight, preserves fine shadow edges
    Interpolated in log-space.
    """
    z_low, z_high = 11, 16
    g_low, g_high = 0.0020, 0.00003
    t = max(0.0, min(1.0, (zoom - z_low) / (z_high - z_low)))
    log_g = math.log10(g_low) + t * (math.log10(g_high) - math.log10(g_low))
    return 10 ** log_g


def _shadow_erosion_steps(zoom):
    """Two erosion distances (deg) that define the 3-ring contour shadow effect.
    Eroding the sunlit area outward by e1/e2 shrinks the sunlit zone → only
    deep shadow survives at l1/l2.  Wider rings at low zoom = topo-map blobs;
    narrow rings at high zoom = fine street-level contours.
      zoom ≤ 12 : [0.0010, 0.0030]  ~90 m / ~270 m rings
      zoom 13   : [0.0005, 0.0015]  ~45 m / ~135 m
      zoom 14   : [0.0002, 0.0006]  ~18 m / ~54 m
      zoom 15+  : [0.00008, 0.0002] ~6 m  / ~18 m
    """
    if zoom >= 15: return (0.00008, 0.0002)
    if zoom == 14: return (0.0002,  0.0006)
    if zoom == 13: return (0.0005,  0.0015)
    return                (0.0010,  0.0030)


def filter_small_polygons(geom, min_area):
    if geom is None or geom.is_empty:
        return geom
    if geom.geom_type == "Polygon":
        return geom if geom.area >= min_area else geom.__class__()
    elif geom.geom_type == "MultiPolygon":
        parts = [p for p in geom.geoms if p.area >= min_area]
        return unary_union(parts) if parts else geom.__class__()
    return geom


# ---------------------------------------------------------------------------
# Background pre-warming — compute lower-zoom shadows while user browses
# ---------------------------------------------------------------------------

_prewarm_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="prewarm")
_prewarm_in_flight = set()
_prewarm_lock = threading.Lock()

def _compute_shadow_cached(hour, month, day, lat, lon, zoom, vp_w, vp_h):
    """Compute and cache shadow for a given center/zoom if not already cached."""
    ck = _cache_key(hour, month, day, lat, lon, zoom)
    if ck in _shadow_cache:
        return
    try:
        tz  = pytz.timezone("Europe/Vienna")
        now = datetime(2000, month, day, hour, 0, 0, tzinfo=tz)
        elevation, azimuth = get_sun_angles(lat, lon, now)
        if elevation <= 0:
            return

        pad = 0.15
        q_min_lat = lat - vp_h / 2 - vp_h * pad
        q_min_lon = lon - vp_w / 2 - vp_w * pad
        q_max_lat = lat + vp_h / 2 + vp_h * pad
        q_max_lon = lon + vp_w / 2 + vp_w * pad
        compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)

        min_bld_area = _min_building_area(zoom)
        buildings = [(p, h) for p, h in
                     get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon, zoom=zoom)
                     if p.area >= min_bld_area]

        def _proj(args): return project_shadow(args[0], args[1], elevation, azimuth)
        with ThreadPoolExecutor(max_workers=6) as ex:
            all_shadows = list(ex.map(_proj, buildings))

        if zoom >= 14:
            tall_geoms = [sh for (_, h), sh in zip(buildings, all_shadows)
                          if h >= OCCLUDER_HEIGHT and sh and not sh.is_empty]
            occluder_union = parallel_union(tall_geoms) if tall_geoms else None
        else:
            occluder_union = None

        shadow_parts = []
        for (poly, h), sh in zip(buildings, all_shadows):
            if sh is None or sh.is_empty: continue
            if h < OCCLUDER_HEIGHT and occluder_union and occluder_union.covers(poly.centroid): continue
            shadow_parts.append(sh)

        all_parts = [p for p, _ in buildings] + shadow_parts
        if all_parts:
            merged = parallel_union(all_parts)
            gfill  = _gap_fill(zoom)
            stol   = _simplify_tolerance(zoom)
            merged = merged.buffer(gfill).buffer(-gfill * 0.85)
            merged = merged.simplify(stol, preserve_topology=True)
            sunlit = compute_bbox.difference(merged)
        else:
            sunlit = compute_bbox

        stol            = _simplify_tolerance(zoom)
        sunlit_simple   = sunlit.simplify(stol, preserve_topology=True)
        sunlit_filtered = filter_small_polygons(sunlit_simple, _min_sunlit_area(zoom))

        _shadow_cache[ck] = sunlit_filtered
        if len(_shadow_cache) > MAX_CACHE:
            _shadow_cache.pop(next(iter(_shadow_cache)))
        print(f"[prewarm] z={zoom} h={hour} cached")
    except Exception as e:
        print(f"[prewarm] error z={zoom}: {e}")
    finally:
        with _prewarm_lock:
            _prewarm_in_flight.discard(ck)


def _trigger_prewarm(hour, month, day, lat, lon, zoom, vp_w, vp_h):
    """If the user is at zoom ≥ 14, pre-warm zoom 12 and 13 in the background."""
    if zoom < 14:
        return
    targets = [z for z in [13, 12] if z < zoom]
    for z in targets:
        # Scale viewport size for the lower zoom (roughly 2x per zoom step)
        scale = 2 ** (zoom - z)
        w, h  = vp_w * scale, vp_h * scale
        ck = _cache_key(hour, month, day, lat, lon, z)
        with _prewarm_lock:
            if ck in _shadow_cache or ck in _prewarm_in_flight:
                continue
            _prewarm_in_flight.add(ck)
        _prewarm_executor.submit(_compute_shadow_cached, hour, month, day, lat, lon, z, w, h)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

@app.route("/shadow")
def shadow():
    try:
        lat     = request.args.get("lat",    default=48.2082, type=float)
        lon     = request.args.get("lon",    default=16.3738, type=float)
        hour    = request.args.get("hour",   default=None,    type=int)
        month   = request.args.get("month",  default=None,    type=int)
        day     = request.args.get("day",    default=None,    type=int)
        zoom    = request.args.get("zoom",   default=15,      type=int)
        min_lat = request.args.get("minLat", default=None,    type=float)
        min_lon = request.args.get("minLon", default=None,    type=float)
        max_lat = request.args.get("maxLat", default=None,    type=float)
        max_lon = request.args.get("maxLon", default=None,    type=float)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)
        if month is not None and day is not None:
            now = now.replace(month=month, day=day)
        if hour is not None:
            now = now.replace(hour=hour, minute=0, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(lat, lon, now)

        # Full viewport bbox — dark overlay covers this
        if None not in (min_lat, min_lon, max_lat, max_lon):
            viewport_bbox = shapely_box(min_lon, min_lat, max_lon, max_lat)
        else:
            viewport_bbox = shapely_box(lon - 0.01, lat - 0.01, lon + 0.01, lat + 0.01)

        # Night: cover the entire viewport with a single dark polygon, no holes
        if elevation <= 0:
            dark_area = orient(viewport_bbox, sign=1.0)
            return jsonify({
                "time":      now.strftime("%H:%M"),
                "elevation": elevation,
                "azimuth":   azimuth,
                "dark_area": {"type": "FeatureCollection", "features": [
                    {"type": "Feature", "geometry": round_coords(mapping(dark_area)),
                     "properties": {"layer": "shadow-l0"}},
                ]},
            })

        ck  = _cache_key(now.hour, now.month, now.day, lat, lon, zoom)

        if ck in _shadow_cache:
            sunlit_filtered = _shadow_cache[ck]
            print(f"{now.strftime('%H:%M')} | CACHE HIT | elev={elevation:.1f}")
        else:
            # Use the full viewport — no artificial cap
            if None not in (min_lat, min_lon, max_lat, max_lon):
                q_min_lat, q_min_lon = min_lat, min_lon
                q_max_lat, q_max_lon = max_lat, max_lon
            else:
                q_min_lat, q_min_lon = lat - 0.01, lon - 0.01
                q_max_lat, q_max_lon = lat + 0.01, lon + 0.01

            compute_bbox  = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
            min_bld_area  = _min_building_area(zoom)
            buildings     = [(p, h) for p, h in
                             get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon, zoom=zoom)
                             if p.area >= min_bld_area]

            def _project(args):
                poly, height = args
                return project_shadow(poly, height, elevation, azimuth)

            with ThreadPoolExecutor(max_workers=8) as ex:
                all_shadows = list(ex.map(_project, buildings))

            # Self-occlusion: build union of shadows from tall buildings (occluders),
            # then skip shorter buildings whose centroid is already in that shadow.
            # Skip at zoom < 14 — not perceptible and saves significant time.
            if zoom >= 14:
                tall_shadow_geoms = [
                    sh for (_, h), sh in zip(buildings, all_shadows)
                    if h >= OCCLUDER_HEIGHT and sh and not sh.is_empty
                ]
                occluder_union = parallel_union(tall_shadow_geoms) if tall_shadow_geoms else None
            else:
                occluder_union = None

            shadow_parts = []
            for (poly, h), sh in zip(buildings, all_shadows):
                if sh is None or sh.is_empty:
                    continue
                if (h < OCCLUDER_HEIGHT
                        and occluder_union is not None
                        and occluder_union.covers(poly.centroid)):
                    continue  # building is in shadow — skip its projection
                shadow_parts.append(sh)

            t0 = time.time()
            building_polys = [p for p, _ in buildings]
            all_parts      = building_polys + shadow_parts
            if all_parts:
                merged = parallel_union(all_parts)
                gfill  = _gap_fill(zoom)
                stol   = _simplify_tolerance(zoom)
                merged = merged.buffer(gfill).buffer(-gfill * 0.85)
                merged = merged.simplify(stol, preserve_topology=True)
                sunlit = compute_bbox.difference(merged)
            else:
                sunlit = compute_bbox

            stol            = _simplify_tolerance(zoom)
            sunlit_simple   = sunlit.simplify(stol, preserve_topology=True)
            sunlit_filtered = filter_small_polygons(sunlit_simple, _min_sunlit_area(zoom))

            _shadow_cache[ck] = sunlit_filtered
            if len(_shadow_cache) > MAX_CACHE:
                _shadow_cache.pop(next(iter(_shadow_cache)))

            print(f"{now.strftime('%H:%M')} | elev={elevation:.1f} azim={azimuth:.1f} "
                  f"| z={zoom} | buildings={len(buildings)} | {time.time()-t0:.2f}s")

        # Three-ring contour shadow (topo-map style):
        #   l0 — full shadow (widest ring, lightest)
        #   l1 — shadow eroded inward by e1 (medium ring)
        #   l2 — shadow eroded inward by e2 (core, darkest)
        # Stacked in Flutter, edge zones get only l0 (light), deep shadow
        # zones get all three (dark) → topographic density effect.
        e1, e2 = _shadow_erosion_steps(zoom)

        shadow_l0 = orient(viewport_bbox.difference(sunlit_filtered), sign=1.0)
        try:
            shadow_l1 = orient(viewport_bbox.difference(sunlit_filtered.buffer(e1)), sign=1.0)
        except Exception:
            shadow_l1 = shadow_l0
        try:
            shadow_l2 = orient(viewport_bbox.difference(sunlit_filtered.buffer(e2)), sign=1.0)
        except Exception:
            shadow_l2 = shadow_l1

        features = [
            {"type": "Feature", "geometry": round_coords(mapping(shadow_l0)),
             "properties": {"layer": "shadow-l0"}},
            {"type": "Feature", "geometry": round_coords(mapping(shadow_l1)),
             "properties": {"layer": "shadow-l1"}},
            {"type": "Feature", "geometry": round_coords(mapping(shadow_l2)),
             "properties": {"layer": "shadow-l2"}},
        ]

        return jsonify({
            "time":      now.strftime("%H:%M"),
            "elevation": elevation,
            "azimuth":   azimuth,
            "dark_area": {"type": "FeatureCollection", "features": features},
        })

    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Shadow — SSE streaming endpoint (progress events, same shadow logic)
# ---------------------------------------------------------------------------

@app.route("/shadow/stream")
def shadow_stream():
    lat     = request.args.get("lat",    default=48.2082, type=float)
    lon     = request.args.get("lon",    default=16.3738, type=float)
    hour    = request.args.get("hour",   default=None,    type=int)
    month   = request.args.get("month",  default=None,    type=int)
    day     = request.args.get("day",    default=None,    type=int)
    zoom    = request.args.get("zoom",   default=15.0,    type=float)
    min_lat = request.args.get("minLat", default=None,    type=float)
    min_lon = request.args.get("minLon", default=None,    type=float)
    max_lat = request.args.get("maxLat", default=None,    type=float)
    max_lon = request.args.get("maxLon", default=None,    type=float)

    def _evt(progress, stage="", result=None, error=None):
        payload = {"progress": progress, "stage": stage}
        if result is not None:
            payload["result"] = result
        if error is not None:
            payload["error"] = error
        return f"data: {json.dumps(payload)}\n\n"

    def generate():
        try:
            yield _evt(5, "Sun position")

            tz  = pytz.timezone("Europe/Vienna")
            now = datetime.now(tz)
            if month is not None and day is not None:
                now = now.replace(month=month, day=day)
            if hour is not None:
                now = now.replace(hour=hour, minute=0, second=0, microsecond=0)

            elevation, azimuth = get_sun_angles(lat, lon, now)

            VIEWPORT_PAD = 0.15
            if None not in (min_lat, min_lon, max_lat, max_lon):
                _vw = max_lon - min_lon
                _vh = max_lat - min_lat
                viewport_bbox = shapely_box(
                    min_lon - _vw * VIEWPORT_PAD, min_lat - _vh * VIEWPORT_PAD,
                    max_lon + _vw * VIEWPORT_PAD, max_lat + _vh * VIEWPORT_PAD,
                )
                q_min_lat = min_lat - _vh * VIEWPORT_PAD
                q_min_lon = min_lon - _vw * VIEWPORT_PAD
                q_max_lat = max_lat + _vh * VIEWPORT_PAD
                q_max_lon = max_lon + _vw * VIEWPORT_PAD
            else:
                viewport_bbox = shapely_box(lon - 0.012, lat - 0.012, lon + 0.012, lat + 0.012)
                q_min_lat, q_min_lon = lat - 0.012, lon - 0.012
                q_max_lat, q_max_lon = lat + 0.012, lon + 0.012

            # Night — instant response
            if elevation <= 0:
                dark_area = orient(viewport_bbox, sign=1.0)
                yield _evt(100, "Night", result={
                    "time":      now.strftime("%H:%M"),
                    "elevation": elevation,
                    "azimuth":   azimuth,
                    "dark_area": {"type": "FeatureCollection", "features": [
                        {"type": "Feature", "geometry": round_coords(mapping(dark_area)),
                         "properties": {"layer": "shadow-l0"}},
                    ]},
                })
                return

            ck = _cache_key(now.hour, now.month, now.day, lat, lon, zoom)

            if ck not in _shadow_cache:
                compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
                min_bld_area = _min_building_area(zoom)
                buildings = [(p, h) for p, h in
                             get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon, zoom=zoom)
                             if p.area >= min_bld_area]
                n = len(buildings)

                yield _evt(15, f"Projecting {n} buildings")

                all_shadows = [None] * n
                with ThreadPoolExecutor(max_workers=8) as ex:
                    future_to_idx = {
                        ex.submit(project_shadow, poly, height, elevation, azimuth): i
                        for i, (poly, height) in enumerate(buildings)
                    }
                    done, last_pct = 0, 15
                    for fut in as_completed(future_to_idx):
                        idx = future_to_idx[fut]
                        try:    all_shadows[idx] = fut.result()
                        except: all_shadows[idx] = None
                        done += 1
                        pct = 15 + int(45 * done / max(n, 1))
                        if pct >= last_pct + 5:
                            last_pct = pct
                            yield _evt(pct, f"Shadows {done}/{n}")

                yield _evt(60, "Merging geometry")

                if zoom >= 14:
                    tall_shadow_geoms = [
                        sh for (_, h), sh in zip(buildings, all_shadows)
                        if h >= OCCLUDER_HEIGHT and sh and not sh.is_empty
                    ]
                    occluder_union = parallel_union(tall_shadow_geoms) if tall_shadow_geoms else None
                else:
                    occluder_union = None

                shadow_parts = []
                for (poly, h), sh in zip(buildings, all_shadows):
                    if sh is None or sh.is_empty:
                        continue
                    if (h < OCCLUDER_HEIGHT
                            and occluder_union is not None
                            and occluder_union.covers(poly.centroid)):
                        continue
                    shadow_parts.append(sh)

                yield _evt(70, "Unioning shadows")

                building_polys = [p for p, _ in buildings]
                all_parts = building_polys + shadow_parts
                if all_parts:
                    merged = parallel_union(all_parts)
                    gfill  = _gap_fill(zoom)
                    stol   = _simplify_tolerance(zoom)
                    merged = merged.buffer(gfill).buffer(-gfill * 0.85)
                    merged = merged.simplify(stol, preserve_topology=True)
                    sunlit = compute_bbox.difference(merged)
                else:
                    sunlit = compute_bbox

                yield _evt(85, "Simplifying")

                stol            = _simplify_tolerance(zoom)
                sunlit_simple   = sunlit.simplify(stol, preserve_topology=True)
                sunlit_filtered = filter_small_polygons(sunlit_simple, _min_sunlit_area(zoom))

                _shadow_cache[ck] = sunlit_filtered
                if len(_shadow_cache) > MAX_CACHE:
                    _shadow_cache.pop(next(iter(_shadow_cache)))
            else:
                yield _evt(90, "Cached")

            yield _evt(90, "Building response")

            sunlit_filtered = _shadow_cache[ck]
            e1, e2 = _shadow_erosion_steps(zoom)

            shadow_l0 = orient(viewport_bbox.difference(sunlit_filtered), sign=1.0)
            try:    shadow_l1 = orient(viewport_bbox.difference(sunlit_filtered.buffer(e1)), sign=1.0)
            except: shadow_l1 = shadow_l0
            try:    shadow_l2 = orient(viewport_bbox.difference(sunlit_filtered.buffer(e2)), sign=1.0)
            except: shadow_l2 = shadow_l1

            yield _evt(100, "Done", result={
                "time":      now.strftime("%H:%M"),
                "elevation": elevation,
                "azimuth":   azimuth,
                "dark_area": {"type": "FeatureCollection", "features": [
                    {"type": "Feature", "geometry": round_coords(mapping(shadow_l0)),
                     "properties": {"layer": "shadow-l0"}},
                    {"type": "Feature", "geometry": round_coords(mapping(shadow_l1)),
                     "properties": {"layer": "shadow-l1"}},
                    {"type": "Feature", "geometry": round_coords(mapping(shadow_l2)),
                     "properties": {"layer": "shadow-l2"}},
                ]},
            })

            # Pre-warm lower zoom levels in background while user browses
            vp_w = (max_lon - min_lon) if None not in (min_lon, max_lon) else 0.02
            vp_h = (max_lat - min_lat) if None not in (min_lat, max_lat) else 0.02
            _trigger_prewarm(now.hour, now.month, now.day, lat, lon, zoom, vp_w, vp_h)

        except Exception as e:
            import traceback; traceback.print_exc()
            yield _evt(0, error=str(e))

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    load_buildings(PBF_PATH)
    print("Starting Flask server on http://127.0.0.1:5000 ...")
    app.run(host="0.0.0.0", port=5000, debug=True, use_reloader=False, threaded=True)
