from flask import Flask, jsonify, request
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
import time
from concurrent.futures import ThreadPoolExecutor
import pysolar.solar as ps

app = Flask(__name__)
CORS(app)

# Path to the local OSM PBF file — place it next to main.py
PBF_PATH = os.path.join(os.path.dirname(__file__), "austria-latest.osm.pbf")

# ---------------------------------------------------------------------------
# Shadow cache — keyed by (hour, month, day, lat_grid, lon_grid)
# Stores sunlit_filtered geometry; viewport overlay is recomputed cheaply on hit
# ---------------------------------------------------------------------------
_shadow_cache = {}
MAX_CACHE     = 500
CACHE_GRID    = 0.005  # ~500m grid

def _cache_key(hour, month, day, lat, lon, zoom):
    return (hour, month, day, zoom,
            round(round(lat / CACHE_GRID) * CACHE_GRID, 6),
            round(round(lon / CACHE_GRID) * CACHE_GRID, 6))


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

_buildings_polys   = []   # list of Shapely Polygon
_buildings_heights = []   # list of float
_buildings_tree    = None # STRtree spatial index

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
        self.polys   = []
        self.heights = []
        self._bbox   = LOAD_BBOX  # (min_lat, min_lon, max_lat, max_lon)

    def way(self, w):
        if "building" not in w.tags and "building:part" not in w.tags:
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
            # Pre-simplify once at load — reduces vertices, speeds up per-request work
            poly = poly.simplify(0.00002, preserve_topology=False)
            if poly.is_empty:
                return

            self.polys.append(poly)
            self.heights.append(_parse_height(w.tags))
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
            return

    print(f"Parsing buildings from {pbf_path} (first run, will cache) ...")
    handler = BuildingHandler()
    handler.apply_file(pbf_path, locations=True)
    _buildings_polys   = handler.polys
    _buildings_heights = handler.heights

    print(f"Saving cache to {CACHE_PATH} ...")
    with open(CACHE_PATH, "wb") as f:
        pickle.dump((_buildings_polys, _buildings_heights), f)

    _buildings_tree = STRtree(_buildings_polys)
    print(f"Loaded {len(_buildings_polys):,} buildings — spatial index ready.")


def get_buildings_for_viewport(min_lat, min_lon, max_lat, max_lon):
    bbox    = shapely_box(min_lon, min_lat, max_lon, max_lat)
    indices = _buildings_tree.query(bbox)
    return [(_buildings_polys[i], _buildings_heights[i]) for i in indices
            if _buildings_polys[i].intersects(bbox)]


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

def parallel_union(geoms, chunk_size=150, max_workers=4):
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
                     "properties": {"layer": "shadow"}},
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

            compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
            buildings    = get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon)

            def _project(args):
                poly, height = args
                return project_shadow(poly, height, elevation, azimuth)

            with ThreadPoolExecutor(max_workers=4) as ex:
                results = ex.map(_project, buildings)
            shadow_parts = [sh for sh in results if sh and not sh.is_empty]

            t0 = time.time()
            building_polys = [p for p, _ in buildings]
            all_parts      = building_polys + shadow_parts
            if all_parts:
                merged   = parallel_union(all_parts)
                gap_fill = 0.00003
                merged   = merged.buffer(gap_fill).buffer(-gap_fill * 0.5)
                merged   = merged.simplify(0.0001, preserve_topology=True)
                sunlit   = compute_bbox.difference(merged)
            else:
                sunlit = compute_bbox

            sunlit_simple   = sunlit.simplify(0.0001, preserve_topology=True)
            sunlit_filtered = filter_small_polygons(sunlit_simple, 1e-6)

            _shadow_cache[ck] = sunlit_filtered
            if len(_shadow_cache) > MAX_CACHE:
                _shadow_cache.pop(next(iter(_shadow_cache)))

            print(f"{now.strftime('%H:%M')} | elev={elevation:.1f} azim={azimuth:.1f} "
                  f"| z={zoom} | buildings={len(buildings)} | {time.time()-t0:.2f}s")

        # Shadow fill covers the full viewport minus sunlit holes.
        inner_shadow = orient(viewport_bbox.difference(sunlit_filtered), sign=1.0)
        features = [
            {"type": "Feature", "geometry": round_coords(mapping(inner_shadow)), "properties": {"layer": "shadow"}},
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
# Start
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    load_buildings(PBF_PATH)
    print("Starting Flask server on http://127.0.0.1:5000 ...")
    app.run(host="0.0.0.0", port=5000, debug=True, use_reloader=False)
