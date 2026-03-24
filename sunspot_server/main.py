from flask import Flask, jsonify, request
from flask_cors import CORS
from shapely.geometry import Polygon, box as shapely_box, mapping
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from datetime import datetime
import requests
import pytz
import math
import pysolar.solar as ps

app = Flask(__name__)
CORS(app)

# Overpass API servers
OVERPASS_URLS = [
    "https://lz4.overpass-api.de/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

# Tile-based building cache
# Grid cells of ~0.008° (~900m) — each cell cached independently
GRID_DEG = 0.008
_tile_cache = {}  # (tile_lat, tile_lon) -> list of (Polygon, height)


# ---------------------------------------------------------------------------
# Sun position
# ---------------------------------------------------------------------------

def get_sun_angles(lat, lon, at_time):
    at_time_utc = at_time.astimezone(pytz.utc)
    elevation = ps.get_altitude(lat, lon, at_time_utc)
    azimuth = ps.get_azimuth(lat, lon, at_time_utc)
    if elevation < 0:
        elevation = 0
    return elevation, azimuth


# ---------------------------------------------------------------------------
# Tile-based building loading
# ---------------------------------------------------------------------------

def _tile_key(lat, lon):
    return (round(math.floor(lat / GRID_DEG) * GRID_DEG, 6),
            round(math.floor(lon / GRID_DEG) * GRID_DEG, 6))

def _tiles_for_bbox(min_lat, min_lon, max_lat, max_lon):
    tiles = set()
    lat = math.floor(min_lat / GRID_DEG) * GRID_DEG
    while lat <= max_lat:
        lon = math.floor(min_lon / GRID_DEG) * GRID_DEG
        while lon <= max_lon:
            tiles.add((round(lat, 6), round(lon, 6)))
            lon = round(lon + GRID_DEG, 6)
        lat = round(lat + GRID_DEG, 6)
    return tiles

def _parse_buildings(data):
    nodes = {el["id"]: (el["lon"], el["lat"]) for el in data["elements"] if el["type"] == "node"}
    ways  = {el["id"]: el for el in data["elements"] if el["type"] == "way"}
    polygons = []

    def parse_height(tags):
        try:
            if "height" in tags:
                return float(tags["height"].replace("m", "").strip())
            if "building:levels" in tags:
                return float(tags["building:levels"]) * 3.0
            if "levels" in tags:
                return float(tags["levels"]) * 3.0
        except (ValueError, KeyError):
            pass
        return 10.0

    for el in data["elements"]:
        if el["type"] == "way" and "nodes" in el:
            coords = [nodes[nid] for nid in el["nodes"] if nid in nodes]
            if len(coords) >= 3:
                height = parse_height(el.get("tags", {}))
                polygons.append((Polygon(coords), height))

        elif el["type"] == "relation" and "members" in el:
            height = parse_height(el.get("tags", {}))
            outer_coords = []
            for member in el["members"]:
                if member.get("role") == "outer" and member["type"] == "way":
                    way = ways.get(member["ref"])
                    if way and "nodes" in way:
                        coords = [nodes[nid] for nid in way["nodes"] if nid in nodes]
                        outer_coords.extend(coords)
            if len(outer_coords) >= 3:
                try:
                    poly = Polygon(outer_coords).buffer(0)
                    if poly.is_valid and not poly.is_empty:
                        polygons.append((poly, height))
                except Exception:
                    pass

    # Filter tiny objects (< ~25m²)
    MIN_BUILDING_AREA = 5e-9
    return [(p, h) for p, h in polygons if p.area >= MIN_BUILDING_AREA]

def get_buildings_for_viewport(min_lat, min_lon, max_lat, max_lon):
    needed = _tiles_for_bbox(min_lat, min_lon, max_lat, max_lon)
    missing = needed - set(_tile_cache.keys())

    if missing:
        # Fetch one bbox covering all missing tiles at once
        fetch_min_lat = min(t[0] for t in missing)
        fetch_min_lon = min(t[1] for t in missing)
        fetch_max_lat = max(t[0] for t in missing) + GRID_DEG
        fetch_max_lon = max(t[1] for t in missing) + GRID_DEG

        query = f"""
        [out:json][timeout:60];
        (
          way["building"]({fetch_min_lat},{fetch_min_lon},{fetch_max_lat},{fetch_max_lon});
          way["building:part"]({fetch_min_lat},{fetch_min_lon},{fetch_max_lat},{fetch_max_lon});
          relation["building"]({fetch_min_lat},{fetch_min_lon},{fetch_max_lat},{fetch_max_lon});
        );
        out body;
        >;
        out skel qt;
        """

        fetched = []
        for url in OVERPASS_URLS:
            try:
                print(f"Fetching buildings bbox ({fetch_min_lat:.4f},{fetch_min_lon:.4f} → {fetch_max_lat:.4f},{fetch_max_lon:.4f}) from {url}...")
                resp = requests.post(url, data=query, timeout=60)
                if resp.status_code == 200 and resp.text.strip().startswith("{"):
                    fetched = _parse_buildings(resp.json())
                    print(f"{len(fetched)} buildings fetched.")
                    break
            except Exception as e:
                print(f"Error fetching from {url}: {e}")

        # Assign fetched buildings to their tiles
        for tile in missing:
            tlat, tlon = tile
            cell_box = shapely_box(tlon, tlat, tlon + GRID_DEG, tlat + GRID_DEG)
            _tile_cache[tile] = [(p, h) for p, h in fetched if p.intersects(cell_box)]

    # Collect unique buildings across all needed tiles (deduplicate by object id)
    seen = set()
    result = []
    for tile in needed:
        for p, h in _tile_cache.get(tile, []):
            pid = id(p)
            if pid not in seen:
                seen.add(pid)
                result.append((p, h))
    return result


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

        coords = list(polygon.exterior.coords[:-1])
        n = len(coords)
        shadow_coords = [(x + dx, y + dy) for x, y in coords]

        parts = [polygon, Polygon(shadow_coords)]
        for i in range(n):
            j = (i + 1) % n
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
    if geom.geom_type == 'Polygon':
        return geom if geom.area >= min_area else geom.__class__()
    elif geom.geom_type == 'MultiPolygon':
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

        # Use viewport bounds, capped to max ~800m x 800m to prevent Overpass timeout
        MAX_DEG = 0.007  # ~800m at 48°N
        if None not in (min_lat, min_lon, max_lat, max_lon):
            half_lat = min((max_lat - min_lat) / 2, MAX_DEG)
            half_lon = min((max_lon - min_lon) / 2, MAX_DEG)
            q_min_lat, q_min_lon = lat - half_lat, lon - half_lon
            q_max_lat, q_max_lon = lat + half_lat, lon + half_lon
        else:
            d = 0.005
            q_min_lat, q_min_lon = lat - d, lon - d
            q_max_lat, q_max_lon = lat + d, lon + d

        viewport_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
        buildings = get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon)

        # Compute shadow polygons
        shadow_parts = []
        for poly, height in buildings:
            sh = project_shadow(poly, height, elevation, azimuth)
            if sh and not sh.is_empty:
                shadow_parts.append(sh)

        # Merge buildings + shadows
        building_polys = [p.buffer(0) for p, _ in buildings]
        all_parts = building_polys + shadow_parts

        if all_parts:
            merged = unary_union(all_parts)
            gap_fill = 0.00003
            merged = merged.buffer(gap_fill).buffer(-gap_fill * 0.5)
            merged = merged.simplify(0.00005, preserve_topology=True)
            sunlit = viewport_bbox.difference(merged)
        else:
            sunlit = viewport_bbox

        sunlit_simple = sunlit.simplify(0.00005, preserve_topology=True)

        # Unified dark overlay: full viewport minus sunlit ground
        dark_area = orient(viewport_bbox.difference(sunlit_simple), sign=1.0)

        # Sunlit ground (filter tiny fragments)
        MIN_AREA = 2e-7
        building_union = unary_union(building_polys) if building_polys else None
        if building_union and not building_union.is_empty:
            sunlit_ground = orient(filter_small_polygons(
                sunlit_simple.difference(building_union), MIN_AREA), sign=1.0)
            buildings_geom = orient(
                building_union.intersection(viewport_bbox).simplify(0.00005, preserve_topology=True), sign=1.0)
        else:
            sunlit_ground = orient(filter_small_polygons(sunlit_simple, MIN_AREA), sign=1.0)
            buildings_geom = None

        print(f"{now.strftime('%H:%M')} | elev={elevation:.1f} azim={azimuth:.1f} | buildings={len(buildings)}")

        features = [
            {"type": "Feature", "geometry": mapping(dark_area),    "properties": {"layer": "shadow"}},
            {"type": "Feature", "geometry": mapping(sunlit_ground), "properties": {"layer": "sunlit_ground"}},
        ]
        if buildings_geom and not buildings_geom.is_empty:
            features.append({"type": "Feature", "geometry": mapping(buildings_geom), "properties": {"layer": "building"}})

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
    print("Starting Flask server on http://127.0.0.1:5000 ...")
    app.run(host="0.0.0.0", port=5000, debug=True, use_reloader=False)
