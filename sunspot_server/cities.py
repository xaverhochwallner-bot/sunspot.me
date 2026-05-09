"""City registry loader.

Reads ../config/cities.json once at import time and exposes the active city's
parameters. For V1.0 this is just Vienna; the indirection costs nothing now and
removes the multi-city refactor blocker for V2.0.
"""

import json
import os

_CONFIG_PATH = os.path.join(
    os.path.dirname(__file__), "..", "config", "cities.json"
)


def _load():
    with open(_CONFIG_PATH, "r", encoding="utf-8") as f:
        registry = json.load(f)
    active_key = os.getenv("SUNSPOT_CITY") or registry.get("active_city", "vienna")
    cities = registry.get("cities", {})
    if active_key not in cities:
        raise RuntimeError(
            f"Active city '{active_key}' not found in {_CONFIG_PATH}. "
            f"Available: {sorted(cities.keys())}"
        )
    return registry, active_key, cities[active_key]


REGISTRY, ACTIVE_KEY, ACTIVE = _load()


def bbox_tuple(key):
    """Return the named bbox of the active city as (min_lat, min_lon, max_lat, max_lon)."""
    return tuple(ACTIVE[key])


def default_center():
    c = ACTIVE["default_center"]
    return c["lat"], c["lon"]


def public_registry():
    """Subset of the registry safe to expose via /cities (no internal paths)."""
    out = {"active_city": ACTIVE_KEY, "cities": {}}
    for key, city in REGISTRY.get("cities", {}).items():
        out["cities"][key] = {
            "name":           city["name"],
            "country":        city["country"],
            "timezone":       city["timezone"],
            "city_bbox":      city["city_bbox"],
            "default_center": city["default_center"],
        }
    return out
