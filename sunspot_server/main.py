from flask import Flask, jsonify, request
from flask_cors import CORS
from shapely.geometry import Polygon, box as shapely_box, mapping
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely.strtree import STRtree
from datetime import datetime
import osmium
import pytz
import math
import os
import pysolar.solar as ps

app = Flask(__name__)
CORS(app)

# Path to the local OSM PBF file — place it next to main.py
PBF_PATH = os.path.join(os.path.dirname(__file__), "austria-latest.osm.pbf")

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


def _parse_height(tags):
    try:
        if "height" in tags:
            return float(str(tags["height"]).replace("m", "").strip())
        if "building:levels" in tags:
            return float(tags["building:levels"]) * 3.0
        if "levels" in tags:
            return float(tags["levels"]) * 3.0
    except (ValueError, KeyError):
        pass
    return 10.0


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

            self.polys.append(poly)
            self.heights.append(_parse_height(w.tags))
        except Exception:
            pass


def load_buildings(pbf_path):
    global _buildings_polys, _buildings_heights, _buildings_tree
    print(f"Loading buildings from {pbf_path} ...")
    handler = BuildingHandler()
    handler.apply_file(pbf_path, locations=True)
    _buildings_polys   = handler.polys
    _buildings_heights = handler.heights
    _buildings_tree    = STRtree(_buildings_polys)
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
        min_lat = request.args.get("minLat", default=None,    type=float)
        min_lon = request.args.get("minLon", default=None,    type=float)
        max_lat = request.args.get("maxLat", default=None,    type=float)
        max_lon = request.args.get("maxLon", default=None,    type=float)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)
        if hour is not None:
            now = now.replace(hour=hour, minute=0, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(lat, lon, now)

        # Full viewport bbox — dark overlay covers this
        if None not in (min_lat, min_lon, max_lat, max_lon):
            viewport_bbox = shapely_box(min_lon, min_lat, max_lon, max_lat)
        else:
            viewport_bbox = shapely_box(lon - 0.01, lat - 0.01, lon + 0.01, lat + 0.01)

        # Compute bbox — capped to avoid slow shadow merging on huge areas
        MAX_DEG = 0.020  # ~2.2 km at 48°N
        if None not in (min_lat, min_lon, max_lat, max_lon):
            half_lat = min((max_lat - min_lat) / 2, MAX_DEG)
            half_lon = min((max_lon - min_lon) / 2, MAX_DEG)
            q_min_lat, q_min_lon = lat - half_lat, lon - half_lon
            q_max_lat, q_max_lon = lat + half_lat, lon + half_lon
        else:
            q_min_lat, q_min_lon = lat - 0.01, lon - 0.01
            q_max_lat, q_max_lon = lat + 0.01, lon + 0.01

        compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
        buildings    = get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon)

        # Compute shadow polygons
        shadow_parts = []
        for poly, height in buildings:
            sh = project_shadow(poly, height, elevation, azimuth)
            if sh and not sh.is_empty:
                shadow_parts.append(sh)

        # Merge buildings + shadows
        building_polys = [p.buffer(0) for p, _ in buildings]
        all_parts      = building_polys + shadow_parts

        if all_parts:
            merged   = unary_union(all_parts)
            gap_fill = 0.00003
            merged   = merged.buffer(gap_fill).buffer(-gap_fill * 0.5)
            merged   = merged.simplify(0.00005, preserve_topology=True)
            sunlit   = compute_bbox.difference(merged)
        else:
            sunlit = compute_bbox

        sunlit_simple = sunlit.simplify(0.00005, preserve_topology=True)

        # Filter tiny fragments before computing any layers
        MIN_AREA       = 1e-6
        sunlit_filtered = filter_small_polygons(sunlit_simple, MIN_AREA)

        # Dark overlay covers full viewport; sunlit punches holes in it
        dark_area = orient(viewport_bbox.difference(sunlit_filtered), sign=1.0)

        # Sunlit ground = filtered sunlit minus building footprints
        building_union = unary_union(building_polys) if building_polys else None
        if building_union and not building_union.is_empty:
            sunlit_ground = orient(filter_small_polygons(
                sunlit_filtered.difference(building_union), MIN_AREA), sign=1.0)
        else:
            sunlit_ground = orient(sunlit_filtered, sign=1.0)

        print(f"{now.strftime('%H:%M')} | elev={elevation:.1f} azim={azimuth:.1f} | buildings={len(buildings)}")

        features = [
            {"type": "Feature", "geometry": mapping(dark_area),    "properties": {"layer": "shadow"}},
            {"type": "Feature", "geometry": mapping(sunlit_ground), "properties": {"layer": "sunlit_ground"}},
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
