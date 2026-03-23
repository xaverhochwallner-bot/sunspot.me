from flask import Flask, jsonify, request
from flask_cors import CORS
from shapely.geometry import Polygon, mapping
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

# Cache: key = (lat_rounded, lon_rounded, radius) -> list of (Polygon, height)
_buildings_cache = {}


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
# Load buildings from OSM
# ---------------------------------------------------------------------------

def get_buildings_from_osm(lat, lon, radius):
    cache_key = (round(lat, 3), round(lon, 3), radius)
    if cache_key in _buildings_cache:
        print(f"Cache hit for {cache_key}")
        return _buildings_cache[cache_key]

    query = f"""
    [out:json][timeout:60];
    (
      way["building"](around:{radius},{lat},{lon});
    );
    out body;
    >;
    out skel qt;
    """

    for url in OVERPASS_URLS:
        try:
            print(f"Fetching buildings from {url} (lat={lat}, lon={lon}, r={radius}m)...")
            response = requests.post(url, data=query, timeout=60)
            if response.status_code != 200 or not response.text.strip().startswith("{"):
                continue

            data = response.json()
            nodes = {el["id"]: (el["lon"], el["lat"]) for el in data["elements"] if el["type"] == "node"}
            polygons = []

            for el in data["elements"]:
                if el["type"] == "way" and "nodes" in el:
                    coords = [nodes[nid] for nid in el["nodes"] if nid in nodes]
                    if len(coords) >= 3:
                        height = 10.0
                        if "tags" in el:
                            try:
                                if "height" in el["tags"]:
                                    height = float(el["tags"]["height"].replace("m", "").strip())
                                elif "building:levels" in el["tags"]:
                                    height = float(el["tags"]["building:levels"]) * 3.0
                            except ValueError:
                                pass
                        polygons.append((Polygon(coords), height))

            print(f"{len(polygons)} buildings loaded.")
            _buildings_cache[cache_key] = polygons
            return polygons

        except Exception as e:
            print(f"Error fetching from {url}: {e}")

    return []


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

        lat_center        = polygon.centroid.y
        meters_per_deg_lat = 111320.0
        meters_per_deg_lon = 111320.0 * math.cos(math.radians(lat_center))

        dx = (-shadow_length * math.sin(azimuth)) / meters_per_deg_lon
        dy = (-shadow_length * math.cos(azimuth)) / meters_per_deg_lat

        if not polygon.is_valid:
            polygon = polygon.buffer(0)

        coords = list(polygon.exterior.coords[:-1])  # drop closing duplicate
        n = len(coords)
        shadow_coords = [(x + dx, y + dy) for x, y in coords]

        # Build a quad for each edge of the footprint connecting it to its shadow
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
# API
# ---------------------------------------------------------------------------

@app.route("/shadow")
def shadow():
    try:
        lat    = request.args.get("lat",    default=48.2082, type=float)
        lon    = request.args.get("lon",    default=16.3738, type=float)
        radius = request.args.get("radius", default=400,     type=int)
        hour   = request.args.get("hour",   default=None,    type=int)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)
        if hour is not None:
            now = now.replace(hour=hour, minute=0, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(lat, lon, now)
        buildings = get_buildings_from_osm(lat, lon, radius)

        shadows = []
        for poly, height in buildings:
            sh = project_shadow(poly, height, elevation, azimuth)
            if sh:
                shadows.append(mapping(sh))

        print(f"{now.strftime('%H:%M')} | elev={elevation:.1f} azim={azimuth:.1f} | buildings={len(buildings)} shadows={len(shadows)}")

        return jsonify({
            "time":      now.strftime("%H:%M"),
            "elevation": elevation,
            "azimuth":   azimuth,
            "shadows":   shadows,
        })

    except Exception as e:
        print(f"Error in /shadow: {e}")
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("Starting Flask server on http://127.0.0.1:5000 ...")
    app.run(host="0.0.0.0", port=5000, debug=True, use_reloader=False)
