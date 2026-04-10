from flask import Flask, jsonify, request, Response, stream_with_context
from flask_cors import CORS
from shapely.geometry import Polygon, box as shapely_box, mapping
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely.strtree import STRtree
from datetime import datetime
try:
    import osmium
    _OSMIUM_AVAILABLE = True
except ImportError:
    _OSMIUM_AVAILABLE = False
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

# ---------------------------------------------------------------------------
# POI / open-space data — loaded once at startup
# ---------------------------------------------------------------------------
_open_spaces     = []   # list of (Polygon, float boost)
_open_space_tree = None
_amenity_pts     = []   # list of shapely Point — cafés, benches, etc.
_amenity_tree    = None
_penalized_areas = []   # list of (Polygon, float penalty factor)
_penalized_tree  = None

# Score boosts for open spaces (multiplied onto the base patch-area score)
_LEISURE_BOOST = {
    'park': 4.0, 'garden': 3.5, 'playground': 2.5, 'pitch': 1.8,
    'recreation_ground': 3.0, 'common': 3.5, 'village_green': 4.0,
}
_LANDUSE_BOOST = {
    'grass': 3.0, 'meadow': 3.0, 'recreation_ground': 3.0,
    'village_green': 4.0, 'greenfield': 2.0,
}
_LANDUSE_PENALTY = {
    'parking': 0.05, 'garages': 0.05,
    'industrial': 0.15, 'commercial': 0.4, 'retail': 0.5,
}
_AMENITY_BOOST_TYPES = {
    'cafe', 'restaurant', 'bar', 'pub', 'biergarten',
    'bench', 'fountain', 'marketplace', 'food_court',
}

# Minimum separation between returned sunny spots (~150 m in degrees)
MIN_SPOT_SEPARATION = 0.0015

PRE_SIMPLIFY = {
    12: 0.00020,  # ~20 m — buildings become pentagons
    13: 0.00008,  # ~8 m
    14: 0.00003,  # ~3 m
    15: 0.000010, # ~1 m — modest reduction, still worth the STRtree cache
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


_OsmiumBase = osmium.SimpleHandler if _OSMIUM_AVAILABLE else object

class BuildingHandler(_OsmiumBase):
    def __init__(self):
        super().__init__()
        self.main_polys    = []   # ways with building=* (full outlines)
        self.main_heights  = []
        self.part_polys    = []   # ways with building:part=* (individual sections)
        self.part_heights  = []
        self.open_spaces   = []   # (Polygon, boost)
        self.penalized     = []   # (Polygon, penalty)
        self._bbox         = LOAD_BBOX

    def _make_area_poly(self, w):
        """Extract a valid closed polygon from a way, or return None."""
        coords = [(n.lon, n.lat) for n in w.nodes if n.location.valid()]
        if len(coords) < 3:
            return None
        min_lat, min_lon, max_lat, max_lon = self._bbox
        lats = [c[1] for c in coords]
        lons = [c[0] for c in coords]
        if max(lats) < min_lat or min(lats) > max_lat: return None
        if max(lons) < min_lon or min(lons) > max_lon: return None
        try:
            poly = Polygon(coords)
            if not poly.is_valid:
                poly = poly.buffer(0)
            return poly if (poly.is_valid and not poly.is_empty) else None
        except Exception:
            return None

    def way(self, w):
        has_building = "building" in w.tags
        has_part     = "building:part" in w.tags

        # --- Open spaces & penalized areas ---
        # Only 2 tag lookups for the 20M+ non-building ways — keep the hot path fast
        if not has_building and not has_part:
            landuse = w.tags.get('landuse', '')
            leisure = w.tags.get('leisure', '')
            boost   = _LEISURE_BOOST.get(leisure) or _LANDUSE_BOOST.get(landuse)
            penalty = _LANDUSE_PENALTY.get(landuse)
            if boost is None and penalty is None:
                return
            poly = self._make_area_poly(w)
            if poly is not None:
                if boost:   self.open_spaces.append((poly, boost))
                if penalty: self.penalized.append((poly, penalty))
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


class AmenityHandler(_OsmiumBase):
    """Separate lightweight handler for amenity nodes only.
    Run as a node-only pass (no location index needed) — much faster than
    embedding node() in BuildingHandler which processes 90M+ nodes."""
    def __init__(self):
        super().__init__()
        self.amenity_pts = []
        self._bbox = LOAD_BBOX

    def node(self, n):
        if not n.location.valid():
            return
        min_lat, min_lon, max_lat, max_lon = self._bbox
        if not (min_lat <= n.location.lat <= max_lat
                and min_lon <= n.location.lon <= max_lon):
            return
        if n.tags.get('amenity') in _AMENITY_BOOST_TYPES:
            self.amenity_pts.append((n.location.lat, n.location.lon))


def _parse_amenities(pbf_path):
    """Fast node-only PBF pass to collect amenity points.
    Uses osmium entity-bits filter so only NODE entities are decoded."""
    try:
        import osmium.io as oio
        # osm_entity_bits.NODE tells osmium to skip way/relation decoding entirely
        reader = oio.Reader(pbf_path, oio.osm_entity_bits.NODE)
        handler = AmenityHandler()
        osmium.apply(reader, handler)
        reader.close()
        print(f"Parsed {len(handler.amenity_pts):,} amenity points.")
        return handler.amenity_pts
    except Exception as e:
        print(f"Amenity node scan skipped ({e}); proximity bonus disabled.")
        return []


CACHE_PATH = os.path.join(os.path.dirname(__file__), "buildings_cache.pkl")

def _build_poi_trees(handler_or_data):
    """Build global STRtrees for open spaces, penalized areas, amenity points."""
    global _open_spaces, _open_space_tree, _amenity_pts, _amenity_tree
    global _penalized_areas, _penalized_tree
    from shapely.geometry import Point as SPoint

    if isinstance(handler_or_data, dict):
        open_spaces  = handler_or_data['open_spaces']
        penalized    = handler_or_data['penalized']
        amenity_pts  = handler_or_data['amenity_pts']
    else:
        open_spaces  = handler_or_data.open_spaces
        penalized    = handler_or_data.penalized
        amenity_pts  = handler_or_data.amenity_pts

    _open_spaces  = open_spaces
    _penalized_areas = penalized
    _amenity_pts  = [SPoint(lon, lat) for lat, lon in amenity_pts]

    _open_space_tree = STRtree([p for p, _ in _open_spaces])  if _open_spaces  else None
    _penalized_tree  = STRtree([p for p, _ in _penalized_areas]) if _penalized_areas else None
    _amenity_tree    = STRtree(_amenity_pts)                   if _amenity_pts   else None

    print(f"POI: {len(_open_spaces):,} open spaces, "
          f"{len(_penalized_areas):,} penalized areas, "
          f"{len(_amenity_pts):,} amenity points indexed.")


def load_buildings(pbf_path=None):
    global _buildings_polys, _buildings_heights, _buildings_tree

    # Use cache if it exists (and is newer than PBF if pbf is present)
    if os.path.exists(CACHE_PATH):
        cache_ok = (pbf_path is None or not os.path.exists(pbf_path) or
                    os.path.getmtime(CACHE_PATH) > os.path.getmtime(pbf_path))
        if cache_ok:
            print("Loading buildings from cache ...")
            with open(CACHE_PATH, "rb") as f:
                cached = pickle.load(f)
            # Cache formats:
            #   2-tuple: (polys, heights)                         — legacy
            #   3-tuple: (polys, heights, poi_data)               — v2
            #   4-tuple: (polys, heights, poi_data, simp_polys)   — v3 (current)
            if isinstance(cached, tuple) and len(cached) >= 3:
                _buildings_polys, _buildings_heights, poi_data = cached[:3]
                simp_polys = cached[3] if len(cached) >= 4 else None
                _buildings_tree = STRtree(_buildings_polys)
                print(f"Loaded {len(_buildings_polys):,} buildings from cache — ready.")
                _build_poi_trees(poi_data)
            else:
                # Legacy format — force full rebuild on next run by returning early
                _buildings_polys, _buildings_heights = cached
                _buildings_tree = STRtree(_buildings_polys)
                print("Old cache format — delete buildings_cache.pkl to rebuild with POI data.")
                simp_polys = None
            _build_simplified_sets(from_cache=simp_polys)
            return

    print(f"Parsing buildings from {pbf_path} (first run, will cache) ...")
    handler = BuildingHandler()
    handler.apply_file(pbf_path, locations=True)
    amenity_pts = _parse_amenities(pbf_path)

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

    poi_data = {
        'open_spaces': handler.open_spaces,
        'penalized':   handler.penalized,
        'amenity_pts': amenity_pts,
    }

    _buildings_tree = STRtree(_buildings_polys)
    print(f"Loaded {len(_buildings_polys):,} buildings — spatial index ready.")
    _build_poi_trees(poi_data)
    _build_simplified_sets()   # parallel simplification — populates _simplified_polys

    print(f"Saving cache to {CACHE_PATH} ...")
    with open(CACHE_PATH, "wb") as f:
        pickle.dump((_buildings_polys, _buildings_heights, poi_data, dict(_simplified_polys)), f)
    print("Cache saved.")


def _simplify_zoom(args):
    """Simplify all building polygons for one zoom level (runs in a worker process)."""
    zoom, tol, polys = args
    simplified = []
    for p in polys:
        s = p.simplify(tol, preserve_topology=True)
        simplified.append(s if (s and not s.is_empty and s.is_valid) else p)
    return zoom, simplified


def _build_simplified_sets(from_cache=None):
    """Build pre-simplified polygon sets for low zoom levels.
    If from_cache is provided (dict zoom→list), skip simplification and
    just rebuild the STRtrees (fast). Otherwise simplify all 4 zoom levels
    in parallel.
    """
    global _simplified_polys, _simplified_trees
    if from_cache is not None:
        # Restore polygons from cache, only rebuild STRtrees
        print("Rebuilding simplified STRtrees from cache ...")
        for zoom, simplified in from_cache.items():
            _simplified_polys[zoom] = simplified
            _simplified_trees[zoom] = STRtree(simplified)
            print(f"  zoom {zoom}: {len(simplified):,} polygons indexed.")
        return

    print(f"Pre-simplifying {len(_buildings_polys):,} buildings for "
          f"{len(PRE_SIMPLIFY)} zoom levels in parallel ...")
    args = [(zoom, tol, _buildings_polys) for zoom, tol in PRE_SIMPLIFY.items()]
    with ThreadPoolExecutor(max_workers=len(PRE_SIMPLIFY)) as ex:
        for zoom, simplified in ex.map(_simplify_zoom, args):
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

        if polygon.geom_type == 'MultiPolygon':
            parts = [project_shadow(p, height, elevation_deg, azimuth_deg) for p in polygon.geoms]
            parts = [p for p in parts if p is not None]
            return unary_union(parts) if parts else None

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
    """Minimum sunlit patch area (deg²) — smooth LOD: 3× per zoom step.
    Reduced multiplier (was 5×) to keep more small sunspots visible at lower zoom.
      zoom 19  → ~0.8 m²      — individual sunlit slivers
      zoom 18  → ~2 m²
      zoom 17  → ~7 m²
      zoom 16  → ~200 m²      — small courtyards visible
      zoom 15  → ~600 m²
      zoom 14  → ~1,800 m²
      zoom 13  → ~5,400 m²
      zoom 12  → ~16,000 m²
      zoom 11  → ~49,000 m²
      zoom 10  → ~145,000 m²
    """
    base = 2e-8   # ~200 m² at z16
    return max(1e-10, base * (3 ** (16 - zoom)))


def _simplify_tolerance(zoom):
    """Geometry simplification tolerance (deg).
    Scaled so fine shadow edges are preserved at high zoom.
      zoom 18+ → ~0.5 m
      zoom 17  → ~1 m
      zoom 16  → ~2 m
      zoom 15  → ~4 m
      zoom 14  → ~4 m
      zoom 13  → ~8 m
      zoom 12  → ~15 m
      zoom ≤11 → ~22 m
    """
    if zoom >= 18: return 0.000005   # ~0.5 m
    if zoom == 17: return 0.000010   # ~1 m
    if zoom >= 16: return 0.000020   # ~2 m
    if zoom == 15: return 0.000040   # ~4 m
    if zoom == 14: return 0.000045   # ~4 m
    if zoom == 13: return 0.000080   # ~8 m
    if zoom == 12: return 0.00015    # ~15 m
    return               0.00022    # zoom ≤ 11 — ~22 m


def _get_sunrise_sunset(lat, lon, now, tz):
    """Return (sunrise_hour, sunset_hour) as floats (local time, hour precision)."""
    sr, ss, prev_el = None, None, None
    for h in range(24):
        t = tz.localize(datetime(now.year, now.month, now.day, h, 0, 0))
        el, _ = get_sun_angles(lat, lon, t)
        if prev_el is not None:
            if prev_el <= 0 < el and sr is None:
                sr = float(h)
            elif prev_el > 0 >= el and ss is None:
                ss = float(h)
        prev_el = el
    return sr, ss


def _gap_fill(zoom):
    """Morphological close distance (deg) — lookup table for controlled ramp.
      zoom ≥17 → ~1.5 m
      zoom 16  → ~3.6 m  — individual building shadows
      zoom 15  → ~8 m    — fine street detail
      zoom 14  → ~11 m   — main streets visible
      zoom 13  → ~17 m   — neighbourhood scale
      zoom 12  → ~30 m   — district scale
      zoom ≤11 → ~55 m   — city scale
    """
    if zoom >= 17: return 0.000014
    if zoom == 16: return 0.000033
    if zoom == 15: return 0.000072
    if zoom == 14: return 0.000100
    if zoom == 13: return 0.000160
    if zoom == 12: return 0.000280
    return                0.000500


def _shadow_erosion_steps(zoom):
    """Two erosion distances (deg) for the 3-ring depth effect.
    Sized to produce ~2-3 screen pixels of ring width at every zoom level,
    so depth is always subtle and never looks like a topo-map contour.
      zoom 17+  : ~1.2 m / ~3 m   — essentially invisible rings
      zoom 16   : ~2.5 m / ~6 m   — very subtle
      zoom 15   : ~5 m  / ~12 m   — slight depth hint
      zoom 14   : ~10 m / ~24 m   — noticeable depth
      zoom 13   : ~19 m / ~48 m   — block-level depth
      zoom ≤ 12 : ~38 m / ~95 m   — neighbourhood-scale gradient
    """
    if zoom >= 17: return (0.000012, 0.000030)
    if zoom >= 16: return (0.000022, 0.000055)
    if zoom == 15: return (0.000045, 0.000110)
    if zoom == 14: return (0.000090, 0.000220)
    if zoom == 13: return (0.00017,  0.00043)
    return               (0.00034,  0.00085)


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
        minute  = request.args.get("minute", default=0,       type=int)
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
            now = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(lat, lon, now)

        # Large outer boundary — shadow extends well beyond visible screen so
        # the rectangular edge is never visible regardless of zoom level.
        SHADOW_BBOX_PAD = 1.5  # degrees (~150 km) — always beyond any viewport
        if None not in (min_lat, min_lon, max_lat, max_lon):
            viewport_bbox = shapely_box(
                min_lon - SHADOW_BBOX_PAD, min_lat - SHADOW_BBOX_PAD,
                max_lon + SHADOW_BBOX_PAD, max_lat + SHADOW_BBOX_PAD,
            )
        else:
            viewport_bbox = shapely_box(lon - 1.5, lat - 1.5, lon + 1.5, lat + 1.5)

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
    minute  = request.args.get("minute", default=0,       type=int)
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
                now = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

            elevation, azimuth = get_sun_angles(lat, lon, now)

            VIEWPORT_PAD  = 0.15   # building query area — 15% beyond viewport
            SHADOW_BBOX_PAD = 1.5  # shadow outer boundary — always off-screen
            if None not in (min_lat, min_lon, max_lat, max_lon):
                _vw = max_lon - min_lon
                _vh = max_lat - min_lat
                # Shadow bbox is huge so its edge is never visible on any zoom
                viewport_bbox = shapely_box(
                    min_lon - SHADOW_BBOX_PAD, min_lat - SHADOW_BBOX_PAD,
                    max_lon + SHADOW_BBOX_PAD, max_lat + SHADOW_BBOX_PAD,
                )
                # Building query uses the smaller 15% pad (performance)
                q_min_lat = min_lat - _vh * VIEWPORT_PAD
                q_min_lon = min_lon - _vw * VIEWPORT_PAD
                q_max_lat = max_lat + _vh * VIEWPORT_PAD
                q_max_lon = max_lon + _vw * VIEWPORT_PAD
            else:
                viewport_bbox = shapely_box(lon - 1.5, lat - 1.5, lon + 1.5, lat + 1.5)
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

            sr, ss = _get_sunrise_sunset(lat, lon, now, tz)

            yield _evt(100, "Done", result={
                "time":      now.strftime("%H:%M"),
                "elevation": elevation,
                "azimuth":   azimuth,
                "sunrise":   sr,
                "sunset":    ss,
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
# Point info — is this lat/lon in sun or shadow? How many hours of sun today?
# ---------------------------------------------------------------------------

def _point_in_shadow(lon, lat, elevation_deg, azimuth_deg, search_radius_deg=0.003):
    """Return True if the given point is inside a building shadow at this sun angle."""
    from shapely.geometry import Point as SPoint
    if elevation_deg <= 0:
        return True
    pt = SPoint(lon, lat)
    bbox = shapely_box(lon - search_radius_deg, lat - search_radius_deg,
                       lon + search_radius_deg, lat + search_radius_deg)
    # Use STRtree for fast spatial lookup instead of linear scan
    indices = _buildings_tree.query(bbox) if _buildings_tree is not None else range(len(_buildings_polys))
    for i in indices:
        poly, height = _buildings_polys[i], _buildings_heights[i]
        if not poly.intersects(bbox):
            continue
        shadow = project_shadow(poly, height, elevation_deg, azimuth_deg)
        if shadow and not shadow.is_empty and shadow.contains(pt):
            return True
    return False


@app.route("/point_info")
def point_info():
    try:
        lat      = float(request.args['lat'])
        lon      = float(request.args['lon'])
        date_str = request.args['date']   # YYYY-MM-DD
        hour     = int(request.args.get('hour', 12))
        minute   = int(request.args.get('minute', 0))

        date = datetime.strptime(date_str, '%Y-%m-%d').date()
        tz   = pytz.timezone('Europe/Vienna')

        # Check shadow at requested hour+minute
        now = tz.localize(datetime(date.year, date.month, date.day, hour, minute, 0))
        elevation, azimuth = get_sun_angles(lat, lon, now)
        in_shadow = _point_in_shadow(lon, lat, elevation, azimuth)

        # Sweep all hours to find sun periods (parallel for speed)
        def _check_hour(h):
            t = tz.localize(datetime(date.year, date.month, date.day, h, 0, 0))
            el, az = get_sun_angles(lat, lon, t)
            if el > 0 and not _point_in_shadow(lon, lat, el, az):
                return h
            return None

        with ThreadPoolExecutor(max_workers=8) as ex:
            sun_hours = sorted(h for h in ex.map(_check_hour, range(24)) if h is not None)

        # Build contiguous periods [{from, to}, ...]
        periods = []
        if sun_hours:
            start = sun_hours[0]
            prev  = sun_hours[0]
            for h in sun_hours[1:]:
                if h == prev + 1:
                    prev = h
                else:
                    periods.append({'from': start, 'to': prev + 1})
                    start = prev = h
            periods.append({'from': start, 'to': prev + 1})

        return jsonify({
            'in_shadow':       in_shadow,
            'sun_hours_count': len(sun_hours),
            'sun_periods':     periods,
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------------------------------------
# Find sunny spots — returns top N sunlit centroids in the current viewport
# ---------------------------------------------------------------------------

@app.route("/find_sunny_spots")
def find_sunny_spots():
    try:
        from shapely.geometry import Point as SPoint

        lat     = request.args.get("lat",    default=48.2082, type=float)
        lon     = request.args.get("lon",    default=16.3738, type=float)
        hour    = request.args.get("hour",   default=None,    type=int)
        minute  = request.args.get("minute", default=0,       type=int)
        month   = request.args.get("month",  default=None,    type=int)
        day     = request.args.get("day",    default=None,    type=int)
        zoom    = request.args.get("zoom",   default=15.0,    type=float)
        min_lat = request.args.get("minLat", default=None,    type=float)
        min_lon = request.args.get("minLon", default=None,    type=float)
        max_lat = request.args.get("maxLat", default=None,    type=float)
        max_lon = request.args.get("maxLon", default=None,    type=float)
        n       = min(request.args.get("n", default=5, type=int), 10)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)
        if month is not None and day is not None:
            now = now.replace(month=month, day=day)
        if hour is not None:
            now = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(lat, lon, now)

        if elevation <= 0:
            return jsonify({"spots": [], "reason": "night"})

        ck = _cache_key(now.hour, now.month, now.day, lat, lon, zoom)

        if ck in _shadow_cache:
            sunlit_filtered = _shadow_cache[ck]
        else:
            # Compute shadow inline (same logic as /shadow endpoint)
            VIEWPORT_PAD = 0.15
            if None not in (min_lat, min_lon, max_lat, max_lon):
                _vw = max_lon - min_lon
                _vh = max_lat - min_lat
                q_min_lat = min_lat - _vh * VIEWPORT_PAD
                q_min_lon = min_lon - _vw * VIEWPORT_PAD
                q_max_lat = max_lat + _vh * VIEWPORT_PAD
                q_max_lon = max_lon + _vw * VIEWPORT_PAD
            else:
                q_min_lat, q_min_lon = lat - 0.012, lon - 0.012
                q_max_lat, q_max_lon = lat + 0.012, lon + 0.012

            compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
            min_bld_area = _min_building_area(zoom)
            buildings    = [(p, h) for p, h in
                            get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon, zoom=zoom)
                            if p.area >= min_bld_area]

            def _proj(args): return project_shadow(args[0], args[1], elevation, azimuth)
            with ThreadPoolExecutor(max_workers=8) as ex:
                all_shadows = list(ex.map(_proj, buildings))

            if zoom >= 14:
                tall = [sh for (_, h), sh in zip(buildings, all_shadows)
                        if h >= OCCLUDER_HEIGHT and sh and not sh.is_empty]
                occluder_union = parallel_union(tall) if tall else None
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

        # Clip sunlit geometry to the actual visible viewport
        if None not in (min_lat, min_lon, max_lat, max_lon):
            actual_vp = shapely_box(min_lon, min_lat, max_lon, max_lat)
        else:
            actual_vp = shapely_box(lon - 0.01, lat - 0.01, lon + 0.01, lat + 0.01)

        try:
            sunlit_vp = sunlit_filtered.intersection(actual_vp)
        except Exception:
            sunlit_vp = sunlit_filtered

        # Extract distinct sunlit patches
        if sunlit_vp is None or sunlit_vp.is_empty:
            patches = []
        elif sunlit_vp.geom_type == 'Polygon':
            patches = [sunlit_vp]
        elif sunlit_vp.geom_type == 'MultiPolygon':
            patches = list(sunlit_vp.geoms)
        else:
            patches = []

        # Consider top-50 patches by area — avoids scoring thousands of tiny slivers
        patches.sort(key=lambda p: p.area, reverse=True)
        patches = patches[:50]

        # Extract one representative point per patch, skip points inside buildings
        raw_candidates = []   # list of (pt, patch_area)
        for patch in patches:
            if patch.is_empty:
                continue
            pt = patch.representative_point()
            bbox_q = shapely_box(pt.x - 0.0002, pt.y - 0.0002, pt.x + 0.0002, pt.y + 0.0002)
            in_building = False
            if _buildings_tree is not None:
                for i in _buildings_tree.query(bbox_q):
                    if _buildings_polys[i].contains(pt):
                        in_building = True
                        break
            if not in_building:
                raw_candidates.append((pt, patch.area))

        # Score each candidate: base = patch area, boosted/penalised by land-use
        def _score(pt, patch_area):
            from shapely.geometry import Point as SPoint
            score = patch_area

            query_box = shapely_box(pt.x - 0.001, pt.y - 0.001, pt.x + 0.001, pt.y + 0.001)

            # Open space boost (park, plaza, grass, …)
            if _open_space_tree is not None:
                for i in _open_space_tree.query(query_box):
                    poly, boost = _open_spaces[i]
                    if poly.contains(pt):
                        score *= boost
                        break   # apply highest-priority boost only

            # Penalised area (parking, industrial, …)
            if _penalized_tree is not None:
                for i in _penalized_tree.query(query_box):
                    poly, penalty = _penalized_areas[i]
                    if poly.contains(pt):
                        score *= penalty
                        break

            # Amenity proximity bonus: café / bench / fountain within ~50 m
            if _amenity_tree is not None:
                amb = shapely_box(pt.x - 0.0005, pt.y - 0.0005,
                                  pt.x + 0.0005, pt.y + 0.0005)
                if len(_amenity_tree.query(amb)) > 0:
                    score *= 1.5

            return score

        scored = sorted(
            ((pt, area, _score(pt, area)) for pt, area in raw_candidates),
            key=lambda x: x[2], reverse=True,
        )

        # Greedy minimum-distance filter — keep top-scored spots ≥ MIN_SPOT_SEPARATION apart
        candidate_pts = []
        for pt, area, score in scored:
            too_close = any(pt.distance(s) < MIN_SPOT_SEPARATION for s in candidate_pts)
            if not too_close:
                candidate_pts.append(pt)
            if len(candidate_pts) >= n:
                break

        # Compute remaining sun hours for each candidate (cache-first, then projection fallback)
        def _sun_remaining(pt):
            from shapely.geometry import Point as SPoint
            spot_lat, spot_lon = pt.y, pt.x
            current_hour = now.hour
            sun_hours = []

            for h in range(current_hour, 24):
                ck_h = _cache_key(h, now.month, now.day, lat, lon, zoom)
                if ck_h in _shadow_cache:
                    # Fast path: point-in-polygon against cached sunlit geometry
                    try:
                        in_sun = _shadow_cache[ck_h].contains(SPoint(spot_lon, spot_lat))
                    except Exception:
                        in_sun = False
                else:
                    # Slow path: full shadow projection
                    t  = tz.localize(datetime(now.year, now.month, now.day, h, 0, 0))
                    el, az = get_sun_angles(spot_lat, spot_lon, t)
                    in_sun = el > 0 and not _point_in_shadow(spot_lon, spot_lat, el, az)

                if in_sun:
                    sun_hours.append(h)

            sun_hours_left = len(sun_hours)

            # sun_until = end of the current/next consecutive sunny block
            sun_until = None
            if sun_hours and current_hour in sun_hours:
                last_h = current_hour
                for h in sun_hours:
                    if h <= last_h + 1:
                        last_h = h
                    else:
                        break
                sun_until = last_h + 1  # exclusive end hour

            return sun_hours_left, sun_until

        with ThreadPoolExecutor(max_workers=min(len(candidate_pts), 5)) as ex:
            sun_infos = list(ex.map(_sun_remaining, candidate_pts))

        spots = []
        for pt, (sun_hours_left, sun_until) in zip(candidate_pts, sun_infos):
            entry = {
                'lat': round(pt.y, 6),
                'lon': round(pt.x, 6),
                'sun_hours_left': sun_hours_left,
            }
            if sun_until is not None:
                entry['sun_until'] = sun_until
            spots.append(entry)

        return jsonify({"spots": spots})

    except Exception as e:
        import traceback; traceback.print_exc()
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

def _is_lfs_pointer(path):
    """Return True if the file is a Git LFS pointer (not actual content)."""
    try:
        with open(path, 'rb') as f:
            return f.read(8) == b'version '
    except OSError:
        return False

def _resolve_lfs_pointer(path):
    """If path is a Git LFS pointer, download the real content in-place."""
    if not _is_lfs_pointer(path):
        return
    import re, requests as req
    with open(path, 'r') as f:
        txt = f.read()
    oid_m  = re.search(r'oid sha256:([a-f0-9]+)', txt)
    size_m = re.search(r'size (\d+)', txt)
    if not oid_m:
        print("LFS pointer found but OID missing — deleting stale cache.")
        os.remove(path)
        return
    oid  = oid_m.group(1)
    size = int(size_m.group(1)) if size_m else 0
    print(f"Cache is LFS pointer — downloading real file ({size//1024//1024} MB)...")
    repo  = os.environ.get("GITHUB_REPO", "xaverhochwallner-bot/sunspot.me")
    token = os.environ.get("GITHUB_TOKEN", "")
    api   = f"https://github.com/{repo}.git/info/lfs/objects/batch"
    hdrs  = {"Accept": "application/vnd.git-lfs+json",
             "Content-Type": "application/vnd.git-lfs+json"}
    if token:
        hdrs["Authorization"] = f"token {token}"
    resp = req.post(api, json={"operation": "download", "transfers": ["basic"],
                               "objects": [{"oid": oid, "size": size}]},
                    headers=hdrs, timeout=30)
    resp.raise_for_status()
    dl_url = resp.json()['objects'][0]['actions']['download']['href']
    r = req.get(dl_url, stream=True, timeout=600)
    r.raise_for_status()
    with open(path, 'wb') as f:
        done = 0
        for chunk in r.iter_content(65536):
            f.write(chunk)
            done += len(chunk)
            if done % (20 * 1024 * 1024) < 65536:
                print(f"  {done//1024//1024}/{size//1024//1024} MB")
    print("LFS download complete.")

def _download_pbf(path):
    import urllib.request
    url = "https://download.geofabrik.de/europe/austria-latest.osm.pbf"
    print(f"Downloading {url} (~760 MB) ...")
    urllib.request.urlretrieve(url, path)
    print("Download complete.")

# Startup — runs on both direct execution and Gunicorn import
if os.path.exists(CACHE_PATH):
    _resolve_lfs_pointer(CACHE_PATH)
_pbf = PBF_PATH if os.path.exists(PBF_PATH) else None
if not os.path.exists(CACHE_PATH) and _pbf is None:
    _download_pbf(PBF_PATH)
    _pbf = PBF_PATH
load_buildings(_pbf)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"Starting Flask server on http://0.0.0.0:{port} ...")
    app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False, threaded=True)
