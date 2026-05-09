from math import radians, tan, sin, cos
from shapely.geometry import Polygon
from pysolar.solar import get_altitude, get_azimuth

def building_shadow_polygon(footprint, height_m, when_utc, lat, lon):
    """
    Berechnet den Schatten eines Gebäudes als Polygon.

    footprint: Liste von (lon, lat)-Tupeln (Gebäudegrundfläche)
    height_m: Gebäudehöhe in Metern
    when_utc: Zeitpunkt als datetime mit timezone.utc
    lat, lon: geografische Koordinaten
    """

    # Sonnenposition berechnen
    alt_deg = get_altitude(lat, lon, when_utc)
    azi_deg = get_azimuth(lat, lon, when_utc)

    if alt_deg <= 0:
        # Sonne unter Horizont → kein Schatten
        return Polygon(footprint)

    # Schattenlänge
    shadow_len = height_m / tan(radians(alt_deg))

    # Richtung berechnen (Azimut ist Winkel von Norden, im Uhrzeigersinn)
    dx = shadow_len * sin(radians(azi_deg))
    dy = shadow_len * cos(radians(azi_deg))

    # Polygonpunkte verschieben
    shifted = [(x + dx * 0.00001, y + dy * 0.00001) for x, y in footprint]

    # Schatten = Fläche zwischen Original und Verschiebung
    shadow_poly = Polygon(footprint + shifted[::-1])

    return shadow_poly
