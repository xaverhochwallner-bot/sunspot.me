from flask import Flask, jsonify, request, Response
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
import re
import gzip as _gzip
import atexit
import tempfile
from collections import OrderedDict
from datetime import time as dtime, timedelta
from concurrent.futures import ThreadPoolExecutor
import threading
import pysolar.solar as ps
import mercantile
import mapbox_vector_tile

# ---------------------------------------------------------------------------
# OSM opening_hours parser (covers ~90% of real-world tags)
# Returns True=open, False=closed, None=unknown/unparseable (treat as open)
# ---------------------------------------------------------------------------
_OH_DAY   = {'Mo': 0, 'Tu': 1, 'We': 2, 'Th': 3, 'Fr': 4, 'Sa': 5, 'Su': 6}
_OH_TIME  = re.compile(r'(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})')
_OH_DAYS  = re.compile(r'(Mo|Tu|We|Th|Fr|Sa|Su)')
_OH_RANGE = re.compile(r'(Mo|Tu|We|Th|Fr|Sa|Su)\s*-\s*(Mo|Tu|We|Th|Fr|Sa|Su)')

def _is_open_at(oh_str: str, dt) -> bool | None:
    s = oh_str.strip()
    if not s:
        return None
    if s.lower() == '24/7':
        return True
    weekday     = dt.weekday()       # Mon=0 … Sun=6
    current     = dt.time()
    matched_day = False
    for rule in s.split(';'):
        rule = rule.strip()
        tm = _OH_TIME.search(rule)
        if not tm:
            continue
        oh, om, ch, cm = (int(x) for x in tm.groups())
        day_part = rule[:tm.start()].strip()
        if not day_part:
            today = True
        else:
            day_set = set()
            for sd, ed in _OH_RANGE.findall(day_part):
                si, ei = _OH_DAY[sd], _OH_DAY[ed]
                if si <= ei:
                    day_set.update(range(si, ei + 1))
                else:
                    day_set.update(range(si, 7))
                    day_set.update(range(0, ei + 1))
            range_ends = {d for pair in _OH_RANGE.findall(day_part) for d in pair}
            for d in _OH_DAYS.findall(day_part):
                if d not in range_ends:
                    day_set.add(_OH_DAY[d])
            today = weekday in day_set
        if not today:
            continue
        matched_day = True
        o_t = dtime(oh % 24, om)
        c_t = dtime(ch % 24, cm)
        if o_t <= c_t:
            if o_t <= current <= c_t:
                return True
        else:                        # crosses midnight
            if current >= o_t or current <= c_t:
                return True
        return False                 # rule matched today but outside window
    return None if not matched_day else False

app = Flask(__name__)
CORS(app)

# Path to the local OSM PBF file — place it next to main.py
PBF_PATH = os.path.join(os.path.dirname(__file__), "austria-latest.osm.pbf")

# ---------------------------------------------------------------------------
# Shadow cache — keyed by (hour, month, day, zoom, lat_grid, lon_grid)
# Stores (sunlit_filtered, buf_e1, buf_e2) for zoom≥14 or just sunlit_filtered
# for macro zoom — so cache hits never re-run the expensive buffer operations.
# ---------------------------------------------------------------------------
_shadow_cache = {}
MAX_CACHE     = 10000
SHADOW_DISK_CACHE_PATH = os.path.join(os.path.dirname(__file__), "shadow_disk_cache.pkl")
_cache_lock   = threading.RLock()  # guards _shadow_cache and _tile_cache

# Tile PBF cache — stores encoded .pbf bytes keyed by (z, x, y, hour, month, day).
# Avoids re-running shadow geometry + encoding for repeated tile requests.
# ~300 bytes/tile × 20 000 tiles ≈ 6 MB max.
_tile_cache          = {}
MAX_TILE_CACHE       = 20000
_tile_in_flight      = {}    # {tck: threading.Event} — deduplicates concurrent tile requests
_tile_in_flight_lock = threading.Lock()

def _trim_tile_cache():
    # Caller must hold _cache_lock.
    while len(_tile_cache) > MAX_TILE_CACHE:
        _tile_cache.pop(next(iter(_tile_cache)))

# Cache grid snaps lat/lon so nearby viewports share a cached result.
# Coarser grid at low zoom → many more cache hits when panning at z12-13.
def _cache_grid(zoom):
    if zoom <= 12: return 0.05   # ~5 km  — whole-city tile
    if zoom == 13: return 0.02   # ~2 km
    if zoom == 14: return 0.02   # ~2 km — coarser for more pan cache hits
    if zoom == 15: return 0.01   # ~1 km
    return 0.01                  # zoom ≥ 16 — same as z15, coarser for more cache hits

def _cache_key(hour, month, day, lat, lon, zoom, elevation=None, azimuth=None):
    g = _cache_grid(zoom)
    lat_s = round(round(lat / g) * g, 6)
    lon_s = round(round(lon / g) * g, 6)
    if elevation is not None and elevation > 0:
        # Bucket by sun angle (3° elev, 6° azim ≈ 30-min granularity) so adjacent
        # hours with nearly identical sun positions share the same cached geometry.
        elev_b = round(elevation / 3.0) * 3
        azim_b = round((azimuth or 0) / 6.0) * 6
        return (elev_b, azim_b, month, zoom, lat_s, lon_s)
    return (hour, month, day, zoom, lat_s, lon_s)


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

# Static Block Database (Macro Pipeline data source) — built once at startup.
_super_blocks         = []    # list[Polygon] — merged city-block super-polygons
_super_block_heights  = []    # area-weighted avg height per block
_super_block_tree     = None  # STRtree spatial index over _super_blocks

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

MIN_BUILDING_AREA = 5e-9  # ~25 m²

# ---------------------------------------------------------------------------
# SHADOW APPEARANCE — frozen visual config
# All shadow rendering knobs live here. To change how shadows look, edit
# only this block. Do not scatter magic numbers elsewhere in the file.
# ---------------------------------------------------------------------------

# Macro / Micro split:
#   z ≤ MACRO_ZOOM_THRESHOLD → super-block fast path (single l0 layer, ~150-500 ms cold)
#   z >  MACRO_ZOOM_THRESHOLD → per-building pipeline with l0/l1/l2 erosion rings
MACRO_ZOOM_THRESHOLD = 14  # z14 moved back to macro: per-tile micro was 28-33s (too slow)

# Static Block Database — built once at startup, persisted in pickle cache.
# All Vienna buildings are buffered+unioned into ~500-2000 city-block super-polygons,
# each carrying an area-weighted average member height. Macro zooms project
# shadows of these blocks instead of individual buildings.
SUPER_BLOCK_BUFFER   = 0.000010   # ~1 m close radius — only fuses overlapping footprints, streets stay open
SUPER_BLOCK_SIMPLIFY = 0.000025   # ~3 m — preserves individual building outline shapes
# Macro pipeline post-processing
MACRO_SIMPLIFY        = 0.000025   # ~3 m — fine output, close to micro quality at z14
MACRO_MIN_SUNLIT_AREA = 2e-8       # ~160 m² — keeps very narrow sunlit gaps between buildings

# Macro erosion rings — cheap sunlit buffer-insets produce l1/l2 depth at block scale.
# Values are ~10× larger than micro because super-blocks are city-block-sized (~50–200 m).
_CFG_MACRO_EROSION = {
    12: (0.0003, 0.0007),   # ~33 m / ~78 m — district scale
    13: (0.0002, 0.0005),   # ~22 m / ~56 m — neighbourhood scale
    14: (0.000060, 0.000140),  # ~6.5 m / ~15 m — close to z15 micro (5.5 m / 13 m) to minimise seam
}

# Morphological close distance (deg) per zoom — z ≥ 14 (micro pipeline).
# Applied as buffer(+d).buffer(-d×0.85), so net shadow expansion ≈ d×0.15.
# Kept minimal so per-building shadows stay distinct.
_CFG_GAP_FILL = {
    17: 0.000003,  # ~0.3 m net
    16: 0.000003,  # ~0.3 m net
    15: 0.000003,  # ~0.3 m net
    14: 0.000003,  # ~0.3 m net
}

# Geometry simplification tolerance (deg) per zoom — z ≥ 14 (micro pipeline).
# Detail increases with zoom; z14 is coarser to bridge to z13 macro.
_CFG_SIMPLIFY = {
    18: 0.000003,  # ~0.3 m
    17: 0.000005,  # ~0.5 m
    16: 0.000007,  # ~0.8 m
    15: 0.000015,  # ~1.7 m
    14: 0.000025,  # ~3 m   — bridge between z13 macro and z15 micro
}

# Two erosion distances (deg) for the 3-ring shadow depth effect — z ≥ 14 (micro pipeline).
_CFG_EROSION = {
    17: (0.000012, 0.000030),
    16: (0.000022, 0.000055),
    15: (0.000050, 0.000120),
    14: (0.000075, 0.000180),  # ~8 m / ~20 m — bridge between z13 macro and z15 micro
}

# Pre-simplification of raw OSM building polygons at startup (deg).
# z15+ are micro pipeline zooms — pre-simplified for faster union at request time.
PRE_SIMPLIFY = {
    15: 0.000010,  # ~1 m
    14: 0.000025,  # ~3 m — kept for pre-warm compat; z14 now uses macro pipeline
}

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
            #   2-tuple: (polys, heights)                                       — legacy
            #   3-tuple: (polys, heights, poi_data)                             — v2
            #   4-tuple: (polys, heights, poi_data, simp_polys)                 — v3
            #   5-tuple: (polys, heights, poi_data, simp_polys, super_blocks)   — v4 (current)
            poi_data          = None
            simp_polys        = None
            super_blocks_data = None
            if isinstance(cached, tuple) and len(cached) >= 3:
                _buildings_polys, _buildings_heights, poi_data = cached[:3]
                simp_polys        = cached[3] if len(cached) >= 4 else None
                super_blocks_data = cached[4] if len(cached) >= 5 else None
                _buildings_tree = STRtree(_buildings_polys)
                print(f"Loaded {len(_buildings_polys):,} buildings from cache — ready.")
                _build_poi_trees(poi_data)
            else:
                # Legacy format — force full rebuild on next run by returning early
                _buildings_polys, _buildings_heights = cached
                _buildings_tree = STRtree(_buildings_polys)
                print("Old cache format — delete buildings_cache.pkl to rebuild with POI data.")
            _build_simplified_sets(from_cache=simp_polys)
            _build_super_blocks(from_cache=super_blocks_data)
            # Migrate old caches by re-saving with the super-block data appended.
            if super_blocks_data is None and poi_data is not None:
                print("Re-saving cache with super-block data ...")
                with open(CACHE_PATH, "wb") as f:
                    pickle.dump((_buildings_polys, _buildings_heights, poi_data,
                                 dict(_simplified_polys),
                                 (_super_blocks, _super_block_heights)), f)
                print("Cache updated.")
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
    _build_super_blocks()      # builds the Static Block Database

    print(f"Saving cache to {CACHE_PATH} ...")
    with open(CACHE_PATH, "wb") as f:
        pickle.dump((_buildings_polys, _buildings_heights, poi_data,
                     dict(_simplified_polys),
                     (_super_blocks, _super_block_heights)), f)
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

        shadow_length = min(height / math.tan(elevation), 500.0)

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

def parallel_union(geoms, chunk_size=150, max_workers=3):
    """Union a large list of geometries in parallel chunks, then merge results."""
    if not geoms:
        return None
    valid = []
    for g in geoms:
        if g is None or g.is_empty:
            continue
        if not g.is_valid:
            g = g.buffer(0)
        if g is not None and not g.is_empty:
            valid.append(g)
    if not valid:
        return None
    if len(valid) <= chunk_size:
        return unary_union(valid)
    chunks = [valid[i:i + chunk_size] for i in range(0, len(valid), chunk_size)]
    with ThreadPoolExecutor(max_workers=min(len(chunks), max_workers)) as ex:
        partial = list(ex.map(_union_chunk, chunks))
    return unary_union([p for p in partial if p is not None and not p.is_empty])


def round_coords(obj, precision=5):
    """Recursively round all floats in a GeoJSON geometry dict."""
    if isinstance(obj, list):
        return [round_coords(v, precision) for v in obj]
    if isinstance(obj, float):
        return round(obj, precision)
    return obj

def _geojson_precision(zoom):
    """GeoJSON coordinate decimal places — fewer digits at low zoom = smaller payload."""
    if zoom <= 12: return 3   # ~100 m resolution, saves ~40% on mobile
    if zoom <= 14: return 4   # ~10 m resolution
    return 5                  # ~1 m resolution


def _min_building_area(zoom):
    """Minimum building footprint (deg²) — used by the per-building (z ≥ 15) pipeline only."""
    return 5e-9   # ~40 m² — keep everything; visible at street level


def _build_super_blocks(from_cache=None):
    """Build the Static Block Database — data source for the Macro Pipeline.

    All Vienna buildings are buffered (~20 m), unioned into city-block-sized
    polygons, then partially un-buffered to pull boundaries back near building
    footprints. Each block stores an area-weighted average member height.
    Used by zoom ≤ MACRO_ZOOM_THRESHOLD requests instead of per-building merge.

    If from_cache is provided ((blocks, heights) tuple), skip the heavy
    buffer/union and just rebuild the STRtree (fast). Otherwise build from
    scratch — costs ~30-90 s once on first run, then persisted in the cache.
    """
    global _super_blocks, _super_block_heights, _super_block_tree

    if from_cache is not None:
        blocks, heights = from_cache
        _super_blocks         = blocks
        _super_block_heights  = heights
        _super_block_tree     = STRtree(blocks) if blocks else None
        print(f"Super-Block DB: {len(_super_blocks):,} blocks loaded from cache.")
        return

    # Use the z15 simplified set (~1 m) as input — same Macro-level visual
    # result as raw, but ~3× faster buffer+union due to lower vertex count.
    src_polys = _simplified_polys.get(15) or _buildings_polys
    if not src_polys:
        print("Super-Block DB: no buildings to process, skipping.")
        return

    print(f"Super-Block DB: building from {len(src_polys):,} buildings ...", flush=True)
    t0 = time.time()

    # Spatial grid chunking: divide the bounding box into GRID×GRID cells and
    # union each cell independently. Avoids one O(n²) unary_union over all
    # Vienna buildings (which takes 10-20 min) by keeping each union local.
    GRID = 20
    all_bounds = [p.bounds for p in src_polys]
    min_lon = min(b[0] for b in all_bounds)
    min_lat = min(b[1] for b in all_bounds)
    max_lon = max(b[2] for b in all_bounds)
    max_lat = max(b[3] for b in all_bounds)
    lon_step = (max_lon - min_lon) / GRID
    lat_step = (max_lat - min_lat) / GRID
    src_tree = STRtree(src_polys)

    cell_results = []
    for ci in range(GRID):
        for cj in range(GRID):
            cell_box = shapely_box(
                min_lon + ci * lon_step, min_lat + cj * lat_step,
                min_lon + (ci + 1) * lon_step, min_lat + (cj + 1) * lat_step,
            )
            idxs = src_tree.query(cell_box)
            cell_polys = [src_polys[k] for k in idxs if not src_polys[k].disjoint(cell_box)]
            if not cell_polys:
                continue
            # Use bbox expansion instead of buffer(): 5-vertex rectangles vs 30+
            # vertex arc-polygons. At z12-z14 scale building bbox ≈ building shape.
            # ~50x faster buffer step + ~16x faster unary_union (fewer vertices).
            d = SUPER_BLOCK_BUFFER
            buffered = [
                shapely_box(p.bounds[0] - d, p.bounds[1] - d,
                            p.bounds[2] + d, p.bounds[3] + d)
                for p in cell_polys
            ]
            cell_union = unary_union(buffered)
            if not cell_union.is_empty:
                cell_results.append(cell_union)
        if (ci + 1) % 5 == 0:
            print(f"  grid {ci+1}/{GRID} rows done, {time.time()-t0:.1f}s elapsed ...", flush=True)

    print(f"  grid done in {time.time()-t0:.1f}s — final merge ...", flush=True)
    merged = unary_union(cell_results)
    print(f"  final merge done in {time.time()-t0:.1f}s — finalizing ...", flush=True)

    # No back-buffer: with a 5m SUPER_BLOCK_BUFFER the footprints are already
    # close to buildings and streets are not fused — shrinking would be O(200K)
    # polygons and serves no purpose at this scale.
    if merged.is_empty:
        print("Super-Block DB: merge produced empty geometry — skipping.")
        return
    # No simplify: bbox-unioned rectangles are already Manhattan geometry with
    # minimal vertices. Shapely's simplify on a MultiPolygon with hundreds of
    # thousands of components is unboundedly slow and yields no real reduction.

    block_geoms = list(merged.geoms) if merged.geom_type != 'Polygon' else [merged]
    print(f"  {len(block_geoms):,} blocks at {time.time()-t0:.1f}s, computing heights ...", flush=True)

    orig_tree = STRtree(_buildings_polys)
    blocks  = []
    heights = []
    bld_heights = _buildings_heights  # local ref avoids repeated global lookup
    for bi, block in enumerate(block_geoms):
        if block.is_empty:
            continue
        idxs = orig_tree.query(block, predicate='intersects')
        total_area  = 0.0
        weighted_h  = 0.0
        for i in idxs:
            a = _buildings_polys[i].area
            total_area += a
            weighted_h += a * bld_heights[i]
        avg_h = min((weighted_h / total_area) if total_area > 0 else DEFAULT_HEIGHT, 25.0)
        blocks.append(block)
        heights.append(avg_h)
        if bi and bi % 50000 == 0:
            print(f"    heights {bi:,}/{len(block_geoms):,} at {time.time()-t0:.1f}s ...", flush=True)

    print(f"  heights done at {time.time()-t0:.1f}s, building STRtree ...", flush=True)
    _super_blocks         = blocks
    _super_block_heights  = heights
    _super_block_tree     = STRtree(blocks) if blocks else None
    print(f"Super-Block DB: {len(blocks):,} blocks ready in {time.time()-t0:.1f}s total.", flush=True)


def _min_sunlit_area(zoom):
    """Minimum sunlit patch area (deg²) — micro pipeline (z ≥ 14).
    Macro zooms use the constant MACRO_MIN_SUNLIT_AREA instead.
    Uses base-2 progression so z14 (~980 m²) stays permissive enough to keep street gaps.
    """
    base = 2e-8   # ~200 m² at z16
    return max(1e-10, base * (2 ** (16 - zoom)))


def _cfg_zoom(cfg, zoom):
    """Return cfg value for zoom, clamped to [min_key, max_key] — no z11 blowup at z18+."""
    keys = sorted(cfg)
    return cfg[max(keys[0], min(keys[-1], zoom))]


def _simplify_tolerance(zoom):
    return _cfg_zoom(_CFG_SIMPLIFY, zoom)


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
    return _cfg_zoom(_CFG_GAP_FILL, zoom)


def _shadow_erosion_steps(zoom):
    return _cfg_zoom(_CFG_EROSION, zoom)

def _macro_erosion_steps(zoom):
    return _cfg_zoom(_CFG_MACRO_EROSION, zoom)


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
# Macro pipeline — z ≤ MACRO_ZOOM_THRESHOLD fast path
# Uses the Static Block Database directly. No per-request merging, no
# parallel chunking, no l1/l2 erosion. ~150-500 ms cold on full Vienna.
# ---------------------------------------------------------------------------

def _macro_compute(elevation, azimuth, q_bounds, zoom):
    """Compute shadow geometry for a Macro-zoom request.

    Returns (sunlit_filtered, buf_e1, buf_e2, n_blocks) — the sunlit area,
    two erosion-inset variants for l1/l2 depth rings, and a block count.
    """
    q_min_lat, q_min_lon, q_max_lat, q_max_lon = q_bounds
    compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)

    if _super_block_tree is None or not _super_blocks:
        return compute_bbox, compute_bbox, compute_bbox, 0

    idxs = _super_block_tree.query(compute_bbox)
    blocks = [(_super_blocks[i], _super_block_heights[i])
              for i in idxs if _super_blocks[i].intersects(compute_bbox)]
    if not blocks:
        return compute_bbox, compute_bbox, compute_bbox, 0

    shadow_parts = []
    for poly, h in blocks:
        sh = project_shadow(poly, h, elevation, azimuth)
        if sh is not None and not sh.is_empty:
            shadow_parts.append(sh)

    block_polys = [p for p, _ in blocks]
    merged = unary_union(block_polys + shadow_parts)
    if not merged.is_valid:
        merged = merged.buffer(0)
    merged = merged.simplify(MACRO_SIMPLIFY, preserve_topology=True)

    sunlit          = compute_bbox.difference(merged)
    sunlit_simple   = sunlit.simplify(MACRO_SIMPLIFY, preserve_topology=True)
    sunlit_filtered = filter_small_polygons(sunlit_simple, MACRO_MIN_SUNLIT_AREA)

    e1, e2 = _macro_erosion_steps(zoom)
    return sunlit_filtered, sunlit_filtered.buffer(e1), sunlit_filtered.buffer(e2), len(blocks)


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Shared shadow helpers — used by all compute paths
# ---------------------------------------------------------------------------

def _unpack_shadow_cache(entry):
    """Unpack cache entry into (sunlit, buf_e1, buf_e2). Extra fields (e.g. stored q_bounds) ignored."""
    if isinstance(entry, tuple) and len(entry) >= 3:
        return entry[0], entry[1], entry[2]
    if isinstance(entry, tuple):
        return entry
    return (entry, None, None)


def _trim_cache():
    # Caller must hold _cache_lock.
    while len(_shadow_cache) > MAX_CACHE:
        _shadow_cache.pop(next(iter(_shadow_cache)))


def _build_shadow_features(viewport_bbox, sunlit, buf_e1, buf_e2, prec):
    """Build GeoJSON feature list for shadow-l0/l1/l2 layers."""
    shadow_l0 = orient(viewport_bbox.difference(sunlit), sign=1.0)
    features  = [{"type": "Feature", "geometry": round_coords(mapping(shadow_l0), prec),
                  "properties": {"layer": "shadow-l0"}}]
    if buf_e1 is not None:
        try:    shadow_l1 = orient(viewport_bbox.difference(buf_e1), sign=1.0)
        except Exception: shadow_l1 = shadow_l0
        try:    shadow_l2 = orient(viewport_bbox.difference(buf_e2), sign=1.0)
        except Exception: shadow_l2 = shadow_l1
        features += [
            {"type": "Feature", "geometry": round_coords(mapping(shadow_l1), prec),
             "properties": {"layer": "shadow-l1"}},
            {"type": "Feature", "geometry": round_coords(mapping(shadow_l2), prec),
             "properties": {"layer": "shadow-l2"}},
        ]
    return features


def _compute_micro_shadow(zoom, elevation, azimuth, q_bounds):
    """Per-building pipeline. Returns (sunlit_filtered, buf_e1, buf_e2)."""
    q_min_lat, q_min_lon, q_max_lat, q_max_lon = q_bounds
    compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
    min_bld_area = _min_building_area(zoom)
    buildings    = [
        (p, h) for p, h in
        get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon, zoom=zoom)
        if p.area >= min_bld_area
    ]

    def _proj(args):
        return project_shadow(args[0], args[1], elevation, azimuth)

    _shadow_workers = min(max(1, (os.cpu_count() or 4) // 2), 8)
    with ThreadPoolExecutor(max_workers=_shadow_workers) as ex:
        all_shadows = list(ex.map(_proj, buildings))

    tall_geoms = [
        sh for (_, h), sh in zip(buildings, all_shadows)
        if h >= OCCLUDER_HEIGHT and sh and not sh.is_empty
    ]
    occluder_union = parallel_union(tall_geoms) if tall_geoms else None

    shadow_parts = []
    for (poly, h), sh in zip(buildings, all_shadows):
        if sh is None or sh.is_empty:
            continue
        if h < OCCLUDER_HEIGHT and occluder_union and occluder_union.covers(poly.centroid):
            continue
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

    e1, e2 = _shadow_erosion_steps(zoom)
    return sunlit_filtered, sunlit_filtered.buffer(e1), sunlit_filtered.buffer(e2)


def _compute_shadow_data(zoom, elevation, azimuth, q_bounds, ck, hour, month, day, lat, lon):
    """Central shadow router: cache lookup → macro or micro compute → cache store.

    Returns (sunlit_filtered, buf_e1, buf_e2).
    Callers supply pre-padded q_bounds; this function only routes and caches.
    Lock is held only around dict operations — never during expensive compute.
    """
    with _cache_lock:
        if ck in _shadow_cache:
            return _unpack_shadow_cache(_shadow_cache[ck])

    if zoom <= MACRO_ZOOM_THRESHOLD:
        t0 = time.time()
        sunlit, buf_e1, buf_e2, n_blocks = _macro_compute(elevation, azimuth, q_bounds, zoom)
        entry = (sunlit, buf_e1, buf_e2, q_bounds)
        with _cache_lock:
            _shadow_cache[ck] = entry
            _trim_cache()
        print(f"macro | z={zoom} blocks={n_blocks} {time.time()-t0:.2f}s")
        return sunlit, buf_e1, buf_e2

    # Cross-zoom reuse: a cached z15 result is a geometry superset of z16/17/18.
    # NEVER reuse upward (larger bbox → smaller bbox) — postage-stamp artifact.
    if zoom >= 16:
        z15_ck = _cache_key(hour, month, day, lat, lon, 15, elevation=elevation, azimuth=azimuth)
        with _cache_lock:
            z15_cached = _shadow_cache.get(z15_ck)
        if z15_cached is not None:
            z15_sunlit, _, _ = _unpack_shadow_cache(z15_cached)
            sunlit = filter_small_polygons(z15_sunlit, _min_sunlit_area(zoom))
            e1, e2 = _shadow_erosion_steps(zoom)
            entry  = (sunlit, sunlit.buffer(e1), sunlit.buffer(e2))
            with _cache_lock:
                _shadow_cache[ck] = entry
                _trim_cache()
            print(f"micro | z={zoom} CACHE HIT (z15→z{zoom} reuse)")
            return entry

    # Cold per-building compute
    t0 = time.time()
    sunlit, buf_e1, buf_e2 = _compute_micro_shadow(zoom, elevation, azimuth, q_bounds)
    entry = (sunlit, buf_e1, buf_e2)
    with _cache_lock:
        _shadow_cache[ck] = entry
        _trim_cache()
    print(f"micro | z={zoom} {time.time()-t0:.2f}s")
    return entry


# Background pre-warming — compute lower-zoom shadows while user browses
# ---------------------------------------------------------------------------

_prewarm_executor   = ThreadPoolExecutor(max_workers=2, thread_name_prefix="prewarm")
_prewarm_in_flight  = set()
_prewarm_lock       = threading.Lock()
_prewarm_queue_size = 0
_MAX_PREWARM_QUEUE  = 20

def _compute_shadow_cached(hour, month, day, lat, lon, zoom, vp_w, vp_h):
    """Pre-warm: compute and cache shadow for a given center/zoom if not already cached."""
    global _prewarm_queue_size
    # hour-based key used only for prewarm dedup — actual geometry stored under angle key
    hour_ck = _cache_key(hour, month, day, lat, lon, zoom)
    try:
        tz  = pytz.timezone("Europe/Vienna")
        now = datetime(2000, month, day, hour, 0, 0, tzinfo=tz)
        elevation, azimuth = get_sun_angles(lat, lon, now)
        if elevation <= 0:
            return
        # Use angle-bucketed key so cross-hour geometry reuse works here too
        ck = _cache_key(hour, month, day, lat, lon, zoom, elevation=elevation, azimuth=azimuth)
        with _cache_lock:
            if ck in _shadow_cache:
                return

        pad = 0.15
        q_bounds = (
            lat - vp_h / 2 - vp_h * pad, lon - vp_w / 2 - vp_w * pad,
            lat + vp_h / 2 + vp_h * pad, lon + vp_w / 2 + vp_w * pad,
        )
        t0 = time.time()
        _compute_shadow_data(zoom, elevation, azimuth, q_bounds, ck, hour, month, day, lat, lon)
        print(f"[prewarm] z={zoom} h={hour} cached in {time.time()-t0:.2f}s")
    except Exception as e:
        print(f"[prewarm] error z={zoom}: {e}")
    finally:
        with _prewarm_lock:
            _prewarm_in_flight.discard(hour_ck)
            _prewarm_queue_size = max(0, _prewarm_queue_size - 1)


def _trigger_prewarm(hour, month, day, lat, lon, zoom, vp_w, vp_h):
    """Pre-warm lower zoom levels in the background while the user browses."""
    global _prewarm_queue_size
    if zoom < 15:
        return
    targets = [z for z in [14, 13, 12] if z < zoom]
    for z in targets:
        # Drop task if queue is overloaded — prevents unbounded memory growth
        with _prewarm_lock:
            if _prewarm_queue_size >= _MAX_PREWARM_QUEUE:
                continue
        # Scale viewport — cap at 4× to prevent z12 from querying enormous areas
        scale = min(2 ** (zoom - z), 4)
        w, h  = vp_w * scale, vp_h * scale
        ck = _cache_key(hour, month, day, lat, lon, z)
        with _prewarm_lock:
            if ck in _prewarm_in_flight:
                continue
            with _cache_lock:
                if ck in _shadow_cache:
                    continue
            _prewarm_in_flight.add(ck)
            _prewarm_queue_size += 1
        _prewarm_executor.submit(_compute_shadow_cached, hour, month, day, lat, lon, z, w, h)




# ---------------------------------------------------------------------------
# Shadow — lightweight metadata endpoint (sun angles only, no geometry)
# ---------------------------------------------------------------------------

@app.route("/shadow/meta")
def shadow_meta():
    try:
        lat    = request.args.get("lat",    default=48.2082, type=float)
        lon    = request.args.get("lon",    default=16.3738, type=float)
        hour   = request.args.get("hour",   default=None, type=int)
        minute = request.args.get("minute", default=0,    type=int)
        month  = request.args.get("month",  default=None, type=int)
        day    = request.args.get("day",    default=None, type=int)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)
        if month is not None and day is not None:
            now = now.replace(month=month, day=day)
        if hour is not None:
            now = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

        elevation, azimuth = get_sun_angles(lat, lon, now)

        sunrise = sunset = None
        for h in range(4, 22):
            dt0 = now.replace(hour=h,   minute=0, second=0, microsecond=0)
            dt1 = now.replace(hour=h+1, minute=0, second=0, microsecond=0)
            e0, _ = get_sun_angles(lat, lon, dt0)
            e1, _ = get_sun_angles(lat, lon, dt1)
            if e0 <= 0 < e1 and sunrise is None:
                sunrise = h + e0 / (e0 - e1) if (e0 - e1) != 0 else float(h)
            if e0 > 0 >= e1 and sunset is None:
                sunset  = h + e0 / (e0 - e1) if (e0 - e1) != 0 else float(h)

        resp = jsonify({
            "time":      now.strftime("%H:%M"),
            "elevation": elevation,
            "azimuth":   azimuth,
            "sunrise":   sunrise,
            "sunset":    sunset,
        })
        resp.headers['Cache-Control'] = 'public, max-age=3600'
        return resp
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Shadow — MVT tile helpers
# ---------------------------------------------------------------------------

def _compute_shadow_tile_pbf(z, x, y, hour, month, day):
    """Compute and return PBF bytes for one shadow tile. Returns None on error."""
    try:
        bounds = mercantile.bounds(x, y, z)
        tile_west, tile_south, tile_east, tile_north = bounds
        tile_cx = (tile_west  + tile_east)  / 2
        tile_cy = (tile_south + tile_north) / 2
        tile_bbox        = shapely_box(tile_west, tile_south, tile_east, tile_north)
        tile_bounds_tuple = (tile_west, tile_south, tile_east, tile_north)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime(2000, month, day, hour, 0, 0, tzinfo=tz)
        elevation, azimuth = get_sun_angles(tile_cy, tile_cx, now)

        def _enc(g0, g1, g2):
            return bytes(mapbox_vector_tile.encode(
                [{"name": "shadows", "features": [
                    {"geometry": g0.wkt, "properties": {"layer": "shadow-l0"}},
                    {"geometry": g1.wkt, "properties": {"layer": "shadow-l1"}},
                    {"geometry": g2.wkt, "properties": {"layer": "shadow-l2"}},
                ]}],
                default_options={"quantize_bounds": tile_bounds_tuple, "extents": 4096},
            ))

        if elevation <= 0:
            dark = orient(tile_bbox, sign=1.0)
            return _enc(dark, dark, dark)

        MAX_BLDG_H = 150
        shadow_m   = MAX_BLDG_H / math.tan(math.radians(max(elevation, 6.0)))
        buf_deg    = min(shadow_m / 111320.0, 0.02)

        q_bounds = (
            tile_south - buf_deg, tile_west - buf_deg,
            tile_north + buf_deg, tile_east + buf_deg,
        )

        ck = ('tile', z, x, y, hour, month, day)  # tile-unique — no lat/lon snapping collision
        sunlit, buf_e1, buf_e2 = _compute_shadow_data(
            z, elevation, azimuth, q_bounds, ck, hour, month, day, tile_cy, tile_cx,
        )

        def _shadow_in_tile(eroded):
            if eroded is None:
                return tile_bbox
            try:
                return orient(tile_bbox.difference(eroded), sign=1.0)
            except Exception:
                return tile_bbox

        return _enc(
            _shadow_in_tile(sunlit),
            _shadow_in_tile(buf_e1),
            _shadow_in_tile(buf_e2),
        )
    except Exception as e:
        print(f"[tile] error {z}/{x}/{y} h={hour}: {e}")
        return None


# ---------------------------------------------------------------------------
# Shadow — MVT tile endpoint
# /shadow/tile/<z>/<x>/<y>.pbf?hour=14&minute=30&month=4&day=30
# ---------------------------------------------------------------------------

@app.route("/shadow/tile/<int:z>/<int:x>/<int:y>.pbf")
def shadow_tile(z, x, y):
    if not (0 <= z <= 22):
        return Response(b'', status=400)
    max_tile = 2 ** z
    if not (0 <= x < max_tile and 0 <= y < max_tile):
        return Response(b'', status=400)
    try:
        hour   = request.args.get("hour",   default=None, type=int)
        minute = request.args.get("minute", default=0,    type=int)
        month  = request.args.get("month",  default=None, type=int)
        day    = request.args.get("day",    default=None, type=int)

        tz  = pytz.timezone("Europe/Vienna")
        now = datetime.now(tz)
        if month is not None and day is not None:
            now = now.replace(month=month, day=day)
        if hour is not None:
            now = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

        h, mo, d = now.hour, now.month, now.day

        # Angle-bucketed tile cache key: tiles with the same sun angle produce
        # identical PBF bytes regardless of the exact date/time.  Cheap trig here
        # lets us share cache entries across different hours AND different dates
        # that happen to share the same sun position (e.g. May 3 14:00 ≈ Aug 10 14:30).
        _n2z = 2.0 ** z
        _tcx = (x + 0.5) / _n2z * 360.0 - 180.0
        _tcy = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * (y + 0.5) / _n2z))))
        _ts  = datetime(2000, mo, d, h, 0, 0, tzinfo=pytz.timezone("Europe/Vienna"))
        _telev, _tazim = get_sun_angles(_tcy, _tcx, _ts)
        if _telev <= 0:
            tck = (z, x, y, 'night', mo)
        else:
            tck = (z, x, y, round(_telev / 3.0) * 3, round(_tazim / 6.0) * 6, mo)

        def _pbf_resp(data):
            resp = Response(data, status=200, mimetype="application/x-protobuf")
            resp.headers['Cache-Control'] = 'public, max-age=3600'
            resp.headers['Access-Control-Allow-Origin'] = '*'
            return resp

        with _cache_lock:
            if tck in _tile_cache:
                return _pbf_resp(_tile_cache[tck])

        # Deduplicate: if another thread is already computing this exact tile, wait for it
        # instead of running the expensive shadow computation a second time.
        with _tile_in_flight_lock:
            if tck in _tile_in_flight:
                evt = _tile_in_flight[tck]
                is_computing = False
            else:
                evt = threading.Event()
                _tile_in_flight[tck] = evt
                is_computing = True

        if not is_computing:
            evt.wait(timeout=60)
            with _cache_lock:
                if tck in _tile_cache:
                    return _pbf_resp(_tile_cache[tck])
            return Response(b'', status=500)

        try:
            pbf = _compute_shadow_tile_pbf(z, x, y, h, mo, d)
            if pbf is None:
                return Response(b'', status=500)
            with _cache_lock:
                _tile_cache[tck] = pbf
                _trim_tile_cache()
            print(f"🟦 [tile] z={z}/{x}/{y} h={h} cached={len(_tile_cache)}", flush=True)
            return _pbf_resp(pbf)
        finally:
            with _tile_in_flight_lock:
                _tile_in_flight.pop(tck, None)
            evt.set()

    except Exception as e:
        import traceback
        traceback.print_exc()
        return Response(b'', status=500)

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


# ---------------------------------------------------------------------------
# City-wide POI database (loaded once at startup, covers all of Vienna)
# ---------------------------------------------------------------------------
_CITY_BBOX       = (48.08, 16.10, 48.35, 16.62)  # Vienna bounds
_CITY_POI_AMENITY_TO_TYPE = {
    'cafe': 'cafe', 'bar': 'bar', 'pub': 'bar', 'beer_garden': 'bar',
    'restaurant': 'restaurant', 'fast_food': 'restaurant',
    'terrace': 'terrace',
    'park': 'park', 'garden': 'park', 'nature_reserve': 'park',
    'playground': 'playground', 'pitch': 'playground',
    'square': 'square', 'pedestrian': 'square',
}
_city_pois: list[dict] = []   # [{lat, lon, name, amenity, poi_type}]
_city_pois_ready = False

def _overpass_fetch(query, timeout=25):
    import urllib.request, urllib.parse, time as _time
    data = urllib.parse.urlencode({'data': query}).encode()
    endpoints = [
        'https://overpass-api.de/api/interpreter',
        'https://overpass.kumi.systems/api/interpreter',
        'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    ]
    for attempt, url in enumerate(endpoints):
        try:
            req = urllib.request.Request(url, data=data,
                  headers={'User-Agent': 'Sunspot.me/1.0'})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read())
        except Exception:
            if attempt < len(endpoints) - 1:
                _time.sleep(3)  # brief pause before trying next endpoint
            continue
    raise RuntimeError('All Overpass endpoints failed')

_CITY_POI_CACHE_FILE = os.path.join(os.path.dirname(__file__), 'city_pois_cache.json')

def _parse_overpass_pois(results):
    pois = []
    for result in results:
        for el in result.get('elements', []):
            plat = el.get('lat') or (el.get('center') or {}).get('lat')
            plon = el.get('lon') or (el.get('center') or {}).get('lon')
            if plat is None or plon is None:
                continue
            tags    = el.get('tags', {})
            amenity = tags.get('amenity') or tags.get('leisure') or tags.get('place') or ''
            if tags.get('outdoor_seating') == 'yes' and amenity in (
                    'cafe', 'bar', 'pub', 'restaurant', 'fast_food', 'beer_garden'):
                poi_type = 'terrace'
            else:
                poi_type = _CITY_POI_AMENITY_TO_TYPE.get(amenity)
            if poi_type is None:
                continue
            pois.append({
                'lat': plat, 'lon': plon,
                'name': tags.get('name', ''),
                'amenity': amenity, 'poi_type': poi_type,
                'opening_hours': tags.get('opening_hours', ''),
                'outdoor_seating': tags.get('outdoor_seating', ''),
            })
    return pois

def _load_city_pois():
    global _city_pois, _city_pois_ready

    # Fast path: load from disk cache
    if os.path.exists(_CITY_POI_CACHE_FILE):
        try:
            with open(_CITY_POI_CACHE_FILE, 'r', encoding='utf-8') as f:
                cached = json.load(f)
            _city_pois = cached
            _city_pois_ready = True
            print(f'[poi] City POI database loaded from cache: {len(_city_pois)} entries')
            return
        except Exception as e:
            print(f'[poi] Cache load failed ({e}), fetching from Overpass...')

    min_lat, min_lon, max_lat, max_lon = _CITY_BBOX
    bbox = f'{min_lat},{min_lon},{max_lat},{max_lon}'

    q_amenity = (
        '[out:json][timeout:60];\n(\n'
        f'  node["amenity"~"^(cafe|bar|pub|restaurant|fast_food)$"]({bbox});\n'
        f'  node["leisure"="beer_garden"]({bbox});\n'
        ');\nout;'
    )
    q_parks = (
        '[out:json][timeout:60];\n(\n'
        f'  node["leisure"~"^(park|garden|nature_reserve|playground|pitch)$"]({bbox});\n'
        f'  way["leisure"~"^(park|garden|nature_reserve|playground|pitch)$"]({bbox});\n'
        ');\nout center;'
    )
    q_squares = (
        '[out:json][timeout:60];\n(\n'
        f'  node["place"="square"]({bbox});\n'
        f'  way["place"="square"]({bbox});\n'
        ');\nout center;'
    )
    q_terraces = (
        '[out:json][timeout:60];\n(\n'
        f'  node["amenity"~"^(cafe|bar|pub|restaurant|fast_food|beer_garden)$"]["outdoor_seating"="yes"]({bbox});\n'
        ');\nout;'
    )

    print('[poi] Loading city-wide POI database from Overpass...')
    import time
    results = []
    for i, (label, q) in enumerate([
        ('amenity', q_amenity),
        ('parks',   q_parks),
        ('squares', q_squares),
        ('terraces', q_terraces),
    ]):
        if i > 0:
            time.sleep(2)
        try:
            results.append(_overpass_fetch(q, 70))
            print(f'[poi]   {label}: ok')
        except Exception as e:
            print(f'[poi]   {label}: failed ({e}), skipping')
            results.append({'elements': []})

    pois = _parse_overpass_pois(results)

    # Save to disk cache for next startup
    try:
        with open(_CITY_POI_CACHE_FILE, 'w', encoding='utf-8') as f:
            json.dump(pois, f)
        print(f'[poi] Cache saved ({len(pois)} entries → {_CITY_POI_CACHE_FILE})')
    except Exception as e:
        print(f'[poi] Cache save failed: {e}')

    _city_pois = pois
    _city_pois_ready = True
    print(f'[poi] City POI database ready: {len(pois)} entries')

threading.Thread(target=_load_city_pois, daemon=True).start()

# Fallback: small-radius Overpass fetch for locations outside the city DB
def _fetch_pois_overpass(center_lat, center_lon, types, radius=600):
    ar = f'around:{radius},{center_lat},{center_lon}'
    type_queries = []
    for t in types:
        if t == 'cafe':
            type_queries += [f'node["amenity"="cafe"]({ar});']
        elif t == 'bar':
            type_queries += [
                f'node["amenity"="bar"]({ar});',
                f'node["amenity"="pub"]({ar});',
                f'node["leisure"="beer_garden"]({ar});',
            ]
        elif t == 'restaurant':
            type_queries += [
                f'node["amenity"="restaurant"]({ar});',
                f'node["amenity"="fast_food"]({ar});',
            ]
        elif t == 'playground':
            type_queries += [
                f'node["leisure"="playground"]({ar});',
                f'way["leisure"="playground"]({ar});',
            ]
        elif t == 'square':
            type_queries += [
                f'node["place"="square"]({ar});',
                f'way["place"="square"]({ar});',
            ]
        elif t == 'terrace':
            type_queries += [
                f'node["amenity"~"^(cafe|bar|pub|restaurant|fast_food|beer_garden)$"]["outdoor_seating"="yes"]({ar});',
            ]
    query = '[out:json][timeout:15];\n(\n' + '\n'.join(type_queries) + '\n);\nout center 100;'
    result = _overpass_fetch(query, timeout=20)
    pois = []
    for el in result.get('elements', []):
        plat = el.get('lat') or (el.get('center') or {}).get('lat')
        plon = el.get('lon') or (el.get('center') or {}).get('lon')
        if plat is None or plon is None:
            continue
        tags    = el.get('tags', {})
        amenity = tags.get('amenity') or tags.get('leisure') or tags.get('place') or ''
        poi_type = _CITY_POI_AMENITY_TO_TYPE.get(amenity, amenity)
        pois.append({'lat': plat, 'lon': plon, 'name': tags.get('name', ''),
                     'amenity': amenity, 'poi_type': poi_type,
                     'opening_hours': tags.get('opening_hours', ''),
                     'outdoor_seating': tags.get('outdoor_seating', '')})
    return pois

_poi_cache      = OrderedDict()  # fallback cache for non-city locations (LRU, max 50 entries)
_MAX_POI_CACHE  = 50
_poi_cache_lock = threading.Lock()


MIN_POI_SEPARATION = 0.0009  # ~100 m in degrees

@app.route("/sunny_pois")
def sunny_pois():
    try:
        center_lat = float(request.args['lat'])
        center_lon = float(request.args['lon'])
        hour       = int(request.args.get('hour', 12))
        minute     = int(request.args.get('minute', 0))
        date_str   = request.args.get('date', datetime.now().strftime('%Y-%m-%d'))
        _ALLOWED_POI_TYPES = {'cafe', 'bar', 'restaurant', 'park', 'playground', 'square', 'terrace'}
        raw_types  = request.args.get('types', 'cafe,bar,restaurant').split(',')
        types      = [t.strip() for t in raw_types if t.strip() in _ALLOWED_POI_TYPES] or ['cafe', 'bar', 'restaurant']
        zoom       = float(request.args.get('zoom', 15))
        vp_min_lat = request.args.get('minLat', type=float)
        vp_min_lon = request.args.get('minLon', type=float)
        vp_max_lat = request.args.get('maxLat', type=float)
        vp_max_lon = request.args.get('maxLon', type=float)

        if zoom < 13:
            return jsonify({'spots': [], 'reason': 'zoom_in'})

        tz        = pytz.timezone('Europe/Vienna')
        date      = datetime.strptime(date_str, '%Y-%m-%d').date()
        _today    = datetime.now(tz).date()
        if not (_today - timedelta(days=365) <= date <= _today + timedelta(days=365)):
            return jsonify({'error': 'date out of range'}), 400
        t         = tz.localize(datetime(date.year, date.month, date.day, hour, minute, 0))
        elevation, azimuth = get_sun_angles(center_lat, center_lon, t)

        if elevation <= 0:
            return jsonify({'spots': [], 'reason': 'night'})

        # Use full viewport bbox; fall back to a 1.5 km radius if no viewport provided
        if vp_min_lat is not None:
            s_min_lat, s_max_lat = vp_min_lat, vp_max_lat
            s_min_lon, s_max_lon = vp_min_lon, vp_max_lon
        else:
            R    = 1500 / 111320
            Rlon = R / max(0.3, math.cos(math.radians(center_lat)))
            s_min_lat, s_max_lat = center_lat - R, center_lat + R
            s_min_lon, s_max_lon = center_lon - Rlon, center_lon + Rlon

        _CITY_DB_TYPES = {'cafe', 'bar', 'restaurant', 'park', 'playground', 'square', 'terrace'}
        cb_min_lat, cb_min_lon, cb_max_lat, cb_max_lon = _CITY_BBOX
        in_city = (cb_min_lat <= center_lat <= cb_max_lat and cb_min_lon <= center_lon <= cb_max_lon)

        type_set       = set(types)
        city_types     = type_set & _CITY_DB_TYPES
        overpass_types = type_set - _CITY_DB_TYPES

        candidates = []

        if _city_pois_ready and in_city and city_types:
            from_db = [
                p for p in _city_pois
                if p['poi_type'] in city_types
                and s_min_lat <= p['lat'] <= s_max_lat
                and s_min_lon <= p['lon'] <= s_max_lon
            ]
            candidates += from_db
            # If city DB has 0 for this type (e.g. query failed at startup), fall through to Overpass
            if not from_db:
                try:
                    candidates += [p for p in _fetch_pois_overpass(center_lat, center_lon, list(city_types))
                                   if s_min_lat <= p['lat'] <= s_max_lat and s_min_lon <= p['lon'] <= s_max_lon]
                except Exception:
                    pass
        elif city_types:
            cache_key = (round(center_lat, 3), round(center_lon, 3), tuple(sorted(city_types)))
            with _poi_cache_lock:
                if cache_key in _poi_cache:
                    _poi_cache.move_to_end(cache_key)
                    _city_result = list(_poi_cache[cache_key])
                else:
                    _city_result = None
            if _city_result is None:
                _city_result = _fetch_pois_overpass(center_lat, center_lon, list(city_types))
                with _poi_cache_lock:
                    if cache_key not in _poi_cache:
                        _poi_cache[cache_key] = _city_result
                        if len(_poi_cache) > _MAX_POI_CACHE:
                            _poi_cache.popitem(last=False)
            candidates += [p for p in _city_result
                           if s_min_lat <= p['lat'] <= s_max_lat and s_min_lon <= p['lon'] <= s_max_lon]

        if overpass_types:
            cache_key = (round(center_lat, 3), round(center_lon, 3), tuple(sorted(overpass_types)))
            with _poi_cache_lock:
                if cache_key in _poi_cache:
                    _poi_cache.move_to_end(cache_key)
                    _ovp_result = list(_poi_cache[cache_key])
                else:
                    _ovp_result = None
            if _ovp_result is None:
                _ovp_result = _fetch_pois_overpass(center_lat, center_lon, list(overpass_types))
                with _poi_cache_lock:
                    if cache_key not in _poi_cache:
                        _poi_cache[cache_key] = _ovp_result
                        if len(_poi_cache) > _MAX_POI_CACHE:
                            _poi_cache.popitem(last=False)
            candidates += [p for p in _ovp_result
                           if s_min_lat <= p['lat'] <= s_max_lat and s_min_lon <= p['lon'] <= s_max_lon]

        # Build index of cached shadow geometries for this hour/date (fast path)
        from shapely.geometry import Point as SPoint
        cached_geoms = [
            geom for ck, geom in list(_shadow_cache.items())
            if ck[0] == t.hour and ck[1] == date.month and ck[2] == date.day
        ]

        def _is_sunny_now(plat, plon):
            """Single shadow check at current hour — 10× faster than full sun-hours scan."""
            pt = SPoint(plon, plat)
            # Fast path: use already-rendered shadow polygon if available
            for geom in cached_geoms:
                try:
                    return not geom.contains(pt)
                except Exception:
                    pass
            # Slow path: compute directly
            return elevation > 0 and not _point_in_shadow(plon, plat, elevation, azimuth)

        # Filter by opening hours — drop only places definitively closed; unknown = keep
        candidates = [
            p for p in candidates
            if _is_open_at(p.get('opening_hours', ''), t) is not False
        ]

        # Cap candidates, sort nearest first
        candidates.sort(key=lambda p: (p['lat'] - center_lat)**2 + (p['lon'] - center_lon)**2)
        candidates = candidates[:40]

        sunny = []
        for p in candidates:
            dist = int(((p['lat'] - center_lat)**2 + (p['lon'] - center_lon)**2)**0.5 * 111320)
            currently_sunny = _is_sunny_now(p['lat'], p['lon'])
            sun_hours_left = 1 if currently_sunny else 0
            sun_until = t.hour + 1 if currently_sunny else None
            sunny.append({
                'lat': p['lat'], 'lon': p['lon'],
                'name': p['name'], 'amenity': p['amenity'],
                'dist': dist,
                'sun_hours': sun_hours_left,
                'sun_until': sun_until,
                'opening_hours': p.get('opening_hours', ''),
                'outdoor_seating': p.get('outdoor_seating', ''),
            })

        # Shuffle within same sun-tier so repeated searches vary
        import random as _rnd
        _rnd.shuffle(sunny)
        sunny.sort(key=lambda x: -x['sun_hours'])

        # Greedy min-separation filter (~100 m) — spread results across the map
        kept = []
        kept_pts = []
        for p in sunny:
            pt = SPoint(p['lon'], p['lat'])
            if any(pt.distance(q) < MIN_POI_SEPARATION for q in kept_pts):
                continue
            kept.append(p)
            kept_pts.append(pt)
            if len(kept) == 12:
                break

        spots = []
        for p in kept:
            entry = {k: p[k] for k in ('lat', 'lon', 'name', 'amenity', 'dist', 'sun_hours')}
            if p['sun_until'] is not None:
                entry['sun_until'] = p['sun_until']
            if p.get('opening_hours'):
                entry['opening_hours'] = p['opening_hours']
            if p.get('outdoor_seating'):
                entry['outdoor_seating'] = p['outdoor_seating']
            spots.append(entry)

        return jsonify({'spots': spots})
    except RuntimeError as e:
        print(f'[sunny_pois] {e}')
        return jsonify({'spots': [], 'reason': 'error'})
    except Exception as e:
        return jsonify({'error': str(e)}), 400


@app.route("/is_sunny")
def is_sunny():
    try:
        lat      = float(request.args['lat'])
        lon      = float(request.args['lon'])
        date_str = request.args.get('date', datetime.now().strftime('%Y-%m-%d'))
        hour     = int(request.args.get('hour', datetime.now().hour))
        minute   = int(request.args.get('minute', datetime.now().minute))
        tz       = pytz.timezone('Europe/Vienna')
        date     = datetime.strptime(date_str, '%Y-%m-%d').date()
        t        = tz.localize(datetime(date.year, date.month, date.day, hour, minute, 0))
        elevation, azimuth = get_sun_angles(lat, lon, t)
        in_shadow = _point_in_shadow(lon, lat, elevation, azimuth)
        return jsonify({'sunny': bool(elevation > 0 and not in_shadow)})
    except Exception as e:
        return jsonify({'error': str(e)}), 400


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

        with ThreadPoolExecutor(max_workers=3) as ex:
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

@app.route("/clear_cache")
def clear_cache():
    max_zoom = request.args.get("max_zoom", default=13, type=int)
    keys = [k for k in list(_shadow_cache.keys()) if k[3] <= max_zoom]
    for k in keys:
        _shadow_cache.pop(k, None)
    return jsonify({"cleared": len(keys), "max_zoom": max_zoom})


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
        n       = min(request.args.get("n", default=5, type=int), 15)

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
            # Try nearest cached entry for same hour/date (avoids recompute on tiny center offset)
            best_ck, best_dist = None, float('inf')
            for k in list(_shadow_cache.keys()):
                if k[0] == now.hour and k[1] == now.month and k[2] == now.day and k[3] == zoom:
                    d = (k[4] - lat) ** 2 + (k[5] - lon) ** 2
                    if d < best_dist:
                        best_dist, best_ck = d, k
            if best_ck is not None and best_dist < 0.01:  # ~1 km tolerance
                sunlit_filtered = _shadow_cache[best_ck]
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

                z_int = int(zoom)
                if z_int <= MACRO_ZOOM_THRESHOLD:
                    macro_q = (q_min_lat, q_min_lon, q_max_lat, q_max_lon)
                    sunlit_filtered, *_ = _macro_compute(
                        elevation, azimuth, macro_q, z_int,
                    )
                else:
                    compute_bbox = shapely_box(q_min_lon, q_min_lat, q_max_lon, q_max_lat)
                    min_bld_area = _min_building_area(z_int)
                    buildings    = [(p, h) for p, h in
                                    get_buildings_for_viewport(q_min_lat, q_min_lon, q_max_lat, q_max_lon, zoom=z_int)
                                    if p.area >= min_bld_area]

                    def _proj(args): return project_shadow(args[0], args[1], elevation, azimuth)
                    with ThreadPoolExecutor(max_workers=3) as ex:
                        all_shadows = list(ex.map(_proj, buildings))

                    tall = [sh for (_, h), sh in zip(buildings, all_shadows)
                            if h >= OCCLUDER_HEIGHT and sh and not sh.is_empty]
                    occluder_union = parallel_union(tall) if tall else None

                    shadow_parts = []
                    for (poly, h), sh in zip(buildings, all_shadows):
                        if sh is None or sh.is_empty: continue
                        if h < OCCLUDER_HEIGHT and occluder_union and occluder_union.covers(poly.centroid): continue
                        shadow_parts.append(sh)

                    all_parts = [p for p, _ in buildings] + shadow_parts
                    if all_parts:
                        merged = parallel_union(all_parts)
                        gfill  = _gap_fill(z_int)
                        stol   = _simplify_tolerance(z_int)
                        merged = merged.buffer(gfill).buffer(-gfill * 0.85)
                        merged = merged.simplify(stol, preserve_topology=True)
                        sunlit = compute_bbox.difference(merged)
                    else:
                        sunlit = compute_bbox

                    stol            = _simplify_tolerance(z_int)
                    sunlit_simple   = sunlit.simplify(stol, preserve_topology=True)
                    sunlit_filtered = filter_small_polygons(sunlit_simple, _min_sunlit_area(z_int))
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

        import random
        scored = sorted(
            ((pt, area, _score(pt, area) * random.uniform(0.82, 1.18)) for pt, area in raw_candidates),
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

        # Compute remaining sun hours — cache-first, stop at first uncached hour
        def _sun_remaining(pt):
            from shapely.geometry import Point as SPoint
            spot_lat, spot_lon = pt.y, pt.x
            current_hour = now.hour
            # Grid candidates are from sunlit patches → current hour always sunny
            sun_hours = [current_hour]

            for h in range(current_hour + 1, 24):
                ck_h = _cache_key(h, now.month, now.day, lat, lon, zoom)
                if ck_h in _shadow_cache:
                    try:
                        in_sun = _shadow_cache[ck_h].contains(SPoint(spot_lon, spot_lat))
                    except Exception:
                        in_sun = False
                    if in_sun:
                        sun_hours.append(h)
                    else:
                        break  # shadow reached — stop counting
                else:
                    # No cache for this hour — do ONE projection then stop
                    t_h = tz.localize(datetime(now.year, now.month, now.day, h, 0, 0))
                    el, az = get_sun_angles(spot_lat, spot_lon, t_h)
                    if el > 0 and not _point_in_shadow(spot_lon, spot_lat, el, az):
                        sun_hours.append(h)
                    break  # don't scan further uncached hours

            sun_hours_left = len(sun_hours)
            last_h = sun_hours[-1] if sun_hours else current_hour
            sun_until = last_h + 1 if sun_hours else None
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
# Heatmap — sun hours per area for a full day
# ---------------------------------------------------------------------------

@app.route("/heatmap")
def heatmap():
    try:
        min_lat = float(request.args['minLat'])
        min_lon = float(request.args['minLon'])
        max_lat = float(request.args['maxLat'])
        max_lon = float(request.args['maxLon'])
        month   = int(request.args['month'])
        day     = int(request.args['day'])
        hour    = int(request.args['hour'])
        minute  = int(request.args.get('minute', 0))
        zoom    = min(int(request.args.get('zoom', 12)), 12)
    except (KeyError, ValueError) as e:
        return jsonify({'error': str(e)}), 400

    center_lat = (min_lat + max_lat) / 2
    center_lon = (min_lon + max_lon) / 2
    tz  = pytz.timezone("Europe/Vienna")

    t = tz.localize(datetime(2000, month, day, hour, minute, 0))
    elevation, azimuth = get_sun_angles(center_lat, center_lon, t)

    if elevation <= 0:
        return jsonify({'type': 'FeatureCollection', 'features': []})

    # Heatmap is always Macro (zoom clamped to 12 above) — single fast path.
    sunlit, _ = _macro_compute(
        elevation, azimuth,
        (min_lat, min_lon, max_lat, max_lon),
    )

    if not sunlit or sunlit.is_empty:
        return jsonify({'type': 'FeatureCollection', 'features': []})

    sunlit = sunlit.simplify(MACRO_SIMPLIFY * 2, preserve_topology=True)
    polys  = sunlit.geoms if hasattr(sunlit, 'geoms') else [sunlit]
    features = [
        {'type': 'Feature', 'geometry': mapping(g), 'properties': {}}
        for g in polys if not g.is_empty
    ]
    return jsonify({'type': 'FeatureCollection', 'features': features})


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

# ---------------------------------------------------------------------------
# Disk shadow cache — persist in-memory cache across server restarts
# ---------------------------------------------------------------------------
if os.path.exists(SHADOW_DISK_CACHE_PATH):
    try:
        with open(SHADOW_DISK_CACHE_PATH, "rb") as _f:
            _loaded = pickle.load(_f)
        _shadow_cache.update(_loaded)
        print(f"[disk cache] Loaded {len(_loaded):,} shadow entries from disk.")
    except Exception as _e:
        print(f"[disk cache] Load failed ({_e}), starting with empty cache.")

def _disk_cache_saver():
    """Background thread: flush shadow cache to disk every 120 s."""
    while True:
        time.sleep(120)
        try:
            with _cache_lock:
                snapshot = dict(_shadow_cache)
            _dir = os.path.dirname(SHADOW_DISK_CACHE_PATH) or '.'
            with tempfile.NamedTemporaryFile(dir=_dir, delete=False, suffix='.pkl') as _tmp:
                pickle.dump(snapshot, _tmp)
                _tmp_path = _tmp.name
            os.replace(_tmp_path, SHADOW_DISK_CACHE_PATH)
            print(f"[disk cache] Saved {len(snapshot):,} entries.")
        except Exception as _e:
            print(f"[disk cache] Save failed: {_e}")

threading.Thread(target=_disk_cache_saver, daemon=True).start()
atexit.register(lambda: _prewarm_executor.shutdown(wait=False))


def _startup_prewarm():
    time.sleep(30)  # let the server finish booting before consuming CPU
    tz  = pytz.timezone("Europe/Vienna")
    now = datetime.now(tz)
    if now.hour < 6 or now.hour > 20:
        print("[startup] Nighttime — skipping pre-warm.")
        return
    lat, lon = 48.2082, 16.3738  # Vienna Stephansdom
    hours = [h for h in (now.hour - 1, now.hour, now.hour + 1) if 6 <= h <= 20]
    zooms = [(12, 0.20, 0.15), (13, 0.10, 0.08), (14, 0.05, 0.04), (15, 0.025, 0.02)]
    tasks = [(h, now.month, now.day, lat, lon, z, w, v)
             for h in hours for z, w, v in zooms]
    print(f"[startup] Pre-warming Vienna center z12-15 for hours {hours} "
          f"({len(tasks)} tasks in parallel) ...")
    with ThreadPoolExecutor(max_workers=1) as ex:
        futs = [ex.submit(_compute_shadow_cached, h, mo, d, la, lo, z, w, v)
                for h, mo, d, la, lo, z, w, v in tasks]
        for f in futs:
            try:    f.result()
            except Exception as e: print(f"[startup] prewarm error: {e}")
    print("[startup] Shadow pre-warm complete.")

    # Tile pre-warm: encode PBF for 3×3 tiles around Vienna center at z13-15.
    # Runs after shadow cache is warm so tile encoding is instant.
    lat, lon = 48.2082, 16.3738
    tile_tasks = []
    for zoom in (13, 14, 15):
        ct = mercantile.tile(lon, lat, zoom)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                t = mercantile.Tile(ct.x + dx, ct.y + dy, zoom)
                for h in hours:
                    tile_tasks.append((zoom, t.x, t.y, h, now.month, now.day))
    print(f"[startup] Pre-warming {len(tile_tasks)} PBF tiles ...")
    for z, x, y, h, mo, d in tile_tasks:
        tck = (z, x, y, h, mo, d)
        with _cache_lock:
            already = tck in _tile_cache
        if not already:
            pbf = _compute_shadow_tile_pbf(z, x, y, h, mo, d)
            if pbf:
                with _cache_lock:
                    _tile_cache[tck] = pbf
                    _trim_tile_cache()
    print(f"[startup] Tile pre-warm complete. {len(_tile_cache)} tiles cached.")

threading.Thread(target=_startup_prewarm, daemon=True).start()

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"Starting Flask server on http://0.0.0.0:{port} ...")
    app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False, threaded=True)
