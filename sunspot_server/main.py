from flask import Flask, jsonify, request
from flask_cors import CORS
from shapely.geometry import Polygon, MultiPolygon, LineString, mapping
from shapely.affinity import translate, scale
from datetime import datetime
import requests
import pytz
import math
import pysolar.solar as ps

app = Flask(__name__)
CORS(app)

# 🌍 Standort Wien
LAT = 48.2082
LON = 16.3738

# Overpass API (alternativ-Server für Stabilität)
OVERPASS_URLS = [
    "https://lz4.overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter"
]


# ---------------------------------------------------------------------------
# 🪐 Sonnenposition berechnen
# ---------------------------------------------------------------------------

def get_sun_angles(at_time=None):
    """Berechnet Sonnen-Elevation & Azimuth (lokale Zeit -> UTC)."""
    tz = pytz.timezone("Europe/Vienna")
    if at_time is None:
        at_time = datetime.now(tz)
    elif at_time.tzinfo is None:
        at_time = tz.localize(at_time)
    at_time_utc = at_time.astimezone(pytz.utc)

    elevation = ps.get_altitude(LAT, LON, at_time_utc)
    azimuth = ps.get_azimuth(LAT, LON, at_time_utc)

    if elevation < 0:
        elevation = 0

    return elevation, azimuth
    print(f"🌞 Sonne: Elev={elevation:.2f}°, Azim={azimuth:.2f}° ({at_time_utc})")


# ---------------------------------------------------------------------------
# 🏢 Gebäude aus Overpass laden
# ---------------------------------------------------------------------------

def get_buildings_from_osm():
    """Lädt Gebäudeumrisse (~100) um Wien Zentrum."""
    query = f"""
    [out:json][timeout:60];
    (
      way["building"](around:500,{LAT},{LON});
    );
    out body;
    >;
    out skel qt;
    """

    for url in OVERPASS_URLS:
        try:
            print(f"📡 Lade Gebäude aus OpenStreetMap ({url})...")
            response = requests.post(url, data=query, timeout=60)  # ✅ POST stabiler als GET
            print("📝 Status:", response.status_code)

            if response.status_code != 200 or not response.text.strip().startswith("{"):
                print("⚠️ Ungültige Antwort, versuche nächsten Server …")
                continue

            data = response.json()

            nodes = {el["id"]: (el["lon"], el["lat"]) for el in data["elements"] if el["type"] == "node"}
            polygons = []

            for el in data["elements"]:
                if el["type"] == "way" and "nodes" in el:
                    coords = [nodes[nid] for nid in el["nodes"] if nid in nodes]
                    if len(coords) >= 3:
                        height = 10.0
                        if "tags" in el and "height" in el["tags"]:
                            try:
                                height = float(el["tags"]["height"].replace("m", ""))
                            except ValueError:
                                pass
                        polygons.append((Polygon(coords), height))

            print(f"✅ {len(polygons)} Gebäude geladen.")
            return polygons

        except Exception as e:
            print(f"❌ Fehler bei {url}: {e}")

    print("⚠️ Keine Gebäude erhalten.")
    return []



# ---------------------------------------------------------------------------
# 🌤️ Schattenprojektion
# ---------------------------------------------------------------------------


def project_shadow(polygon: Polygon, height: float, elevation_deg: float, azimuth_deg: float):
    """
    Erzeugt eine Bodenprojektion eines Gebäudes basierend auf Sonnenhöhe und Azimut.
    - Kein convex_hull oder union (die erzeugen nur Umrisse)
    - Stattdessen: geometrische Projektion der oberen Kante auf den Boden
    """
    try:
        if elevation_deg <= 0 or height <= 0:
            return None

        # Radiant-Umrechnung
        azimuth = math.radians(azimuth_deg)
        elevation = math.radians(elevation_deg)

        # Schattenlänge = Höhe / tan(Elevation)
        shadow_length = height / math.tan(elevation)

        # Schattenrichtung (Sonne → gegenüberliegende Seite)
        dx = -shadow_length * math.sin(azimuth)
        dy = -shadow_length * math.cos(azimuth)

        if not polygon.is_valid:
            polygon = polygon.buffer(0)

        # Das ursprüngliche Polygon repräsentiert das Gebäude-Fundament
        # Wir verschieben es entlang der Schattenrichtung, um den projizierten Schattenpunkt auf dem Boden zu erhalten
        shadow_poly = translate(polygon, xoff=dx, yoff=dy)

        # Verbinde Fundament + Schattenkante (kein ConvexHull, sondern nur Fläche dazwischen)
        shadow_area = Polygon(list(polygon.exterior.coords) + list(shadow_poly.exterior.coords[::-1]))

        return shadow_area.buffer(0)

    except Exception as e:
        print(f"⚠️ Fehler in project_shadow: {e}")
        return None




# ---------------------------------------------------------------------------
# 🌐 API Endpoint
# ---------------------------------------------------------------------------

@app.route("/shadow")
def shadow():
    """Berechnet Schatten für angegebene Uhrzeit (oder aktuelle)."""
    try:
        hour_param = request.args.get("hour", type=int)
        tz = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)

        if hour_param is not None:
            now = now.replace(hour=hour_param, minute=0, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(now)
        buildings = get_buildings_from_osm()

        shadows = []
        for poly, height in buildings:
            sh = project_shadow(poly, height, elevation, azimuth)
            if sh:
                shadows.append(mapping(sh))

        print(f"☀️ {now.strftime('%H:%M')} | Elev={elevation:.1f}°, Azim={azimuth:.1f}°, Gebäude={len(buildings)}, Schatten={len(shadows)}")

        return jsonify({
            "time": now.strftime("%H:%M"),
            "elevation": elevation,
            "azimuth": azimuth,
            "shadows": shadows
        })

    except Exception as e:
        print(f"❌ Fehler im /shadow Endpoint: {e}")
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# 🚀 Start
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("🌞 Starte Flask-Server auf http://127.0.0.1:5000 ...")
    app.run(host="0.0.0.0", port=5000, debug=True)
