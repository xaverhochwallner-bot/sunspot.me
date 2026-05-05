# Sunspot.me — Audit & Roadmap

_Last updated: 2026-05-05 via Claude Code codebase audit_

---

## Vision

Sunspot wird eine global skalierbare PWA:
- **Freemium:** Echtzeit gratis, Forecasts/Planung kostenpflichtig
- **Premium Listings:** Gastgärten, Cafés zahlen für Sichtbarkeit
- **V1.0 target:** Wien-only MVP — blitzschnell, mobil-optimiert, fehlerfrei

---

## 🟢 Was bereits stark ist

**Performance-Pipeline (8/10)**
- Macro/Micro-Split bei Zoom 13: Z12-13 nutzt Super-Blocks (~150-300ms), Z14+ per-Building (200-1500ms)
- Mehrstufiges Caching: Shadow-Geometry-LRU (500), Tile-PBF-LRU (5000), Disk-Pickle, Browser-Cache 1h
- Cross-Zoom-Reuse (Z16→Z15), Grid-Snapping: 2-5 Cache-Hits pro Pan
- ThreadPoolExecutor CPU-aware, Pre-Warming-Pool, In-Flight-Deduplication
- 24h-Animation: 3×3 Grid Parallel-Preload, Retry-Logic, Ghost-Layer-Cleanup

**Mobile-First UX**
- Sauberer Breakpoint @650px, Column/Row-Layout ohne z-Stacking
- GPS-State-Machine, animierte Bottom-Sheet, kompakter Top-Search

**Server-Architektur**
- `/shadow/tile/{z}/{x}/{y}.pbf` als MVT — CDN-ready für globale Distribution
- POI-Filter mit OSM-Opening-Hours-Parser inline

---

## 🔴 Kritische Schwächen

### 1. main.dart = 4.963-Zeilen God-Widget
- ~170 State-Variablen, alle via `setState{}` mutiert
- `fetchShadows()` ist 150 Zeilen async-Spaghetti
- `_buildMobileBottom()` / `_buildDesktopSidebar()` jeweils >300 Zeilen inline
- **Fix:** Riverpod/Provider + Extraktion in `services/`, `widgets/`, `state/` (~4-5 Tage)

### 2. Null Tests, Null CI/CD
- Kein `test/`-Ordner, keine `.github/workflows/`
- Deployment 100% manuell
- **Fix:** GitHub Actions (lint → build → deploy) + 10 Tests Flutter+Python (~3 Tage)

### 3. Server ohne Schutz
- `CORS(app)` ohne Origin-Whitelist
- Lat/Lon/Zoom nicht bounds-checked (`?z=99` möglich)
- 144 parallele Requests der Animation replizierbar durch Angreifer
- **Fix:** Flask-Limiter + Pydantic-Validation (~1.5 Tage)

### 4. Wien überall hardcodiert

| Stelle | Wert |
|---|---|
| `LOAD_BBOX` | `(48.05, 16.10, 48.40, 16.65)` |
| `_CITY_BBOX` | `(48.08, 16.10, 48.35, 16.62)` |
| Default Map Center | `LatLng(48.2082, 16.3738)` (Stephansdom) |
| Nominatim viewbox | `16.18,48.33,16.58,48.12` |
| OSM-Datei | `austria-latest.osm.pbf` |
| Super-Block-Pickle | Single file, kein City-Identifier |
| Erosion/Gap-Fill-Konstanten | Auf Wiener Bebauungsdichte getuned |

→ Für V1.0 OK. `config/cities.json` jetzt anlegen spart später 10-20 Tage Refactoring.

### 5. Null Monetarisierungs-Infrastruktur
- Kein Auth, keine Accounts, kein Stripe-Hook, keine Feature-Flags
- Saved Spots nur im localStorage (geht bei Cache-Clear verloren)
- **Gap:** Firebase Auth (~1 Tag) + Subscription-Check auf `/shadow/tile?date=future` (~0.5 Tag) + Premium-POI-DB (~5 Tage)

### 6. Null Observability
- Nur `print()` zu stdout, `catch (_) {}` schluckt alles stumm
- **Fix:** Sentry + structured Logging (~1 Tag)

---

## 🟡 Kleinere Baustellen

- `pysolar 0.13` unmaintained seit ~2023 → Migration zu `skyfield` planen
- `geopandas` geladen, nur Shapely nötig → ~30% schnellerer Startup ohne
- `flutter_compass` in PLAN.md, fehlt in `pubspec.yaml`
- Service Worker fehlt → keine echte Offline-PWA
- OSM-PBF-Parsing 2-5 Min beim Startup → GCP Cold-Start blockiert
- Overpass-API als POI-Source: Cold-Path 2-8s, nicht skalierbar

---

## 🎯 Must-Do Priority-Stack für V1.0 Launch

| # | Aufgabe | Aufwand | Status |
|---|---------|---------|--------|
| 1 | Rate-Limiting + Input-Validation (Flask-Limiter, Pydantic) | 1 Tag | ⬜ TODO |
| 2 | Sentry + structured Logging | 1 Tag | ⬜ TODO |
| 3 | GitHub Actions CI (lint + build) | 0.5 Tag | ⬜ TODO |
| 4 | 5 kritische Flutter Widget-Tests + 5 Python Endpoint-Tests | 1.5 Tage | ⬜ TODO |
| 5 | Service Worker (echte Offline-PWA) | 1 Tag | ⬜ TODO |
| 6 | `config/cities.json` Vorbereitung (Grundstruktur) | 1 Tag | ⬜ TODO |
| 7 | main.dart in 5-8 Files splitten (Riverpod) | 3 Tage | ⬜ TODO |

**Total: ~9 Tage zu launch-stabilem V1.0**

---

## 🚀 Versionsstrategie

### V1.0 — Wien MVP (jetzt + ~2 Wochen)
- Must-Do-Stack oben abarbeiten
- Beta-Test mit 50-100 Wiener Usern

### V1.1 — Monetarisierungs-Layer (~2 Wochen nach V1.0)
- Firebase Auth + Stripe Subscription
- Forecast-Endpoint (kostenpflichtig) — `/shadow/tile` akzeptiert beliebige Zeit, Schutz nur aufschalten
- Premium-POI-DB + Admin-Upload-CSV

### V2.0 — Multi-City (~4-6 Wochen)
- City-Registry (Berlin, München, Paris, Barcelona als erste Targets)
- Per-City PBF on-demand (nicht alles im RAM)
- Edge-Caching via Cloudflare R2
- City-Auto-Detection per Geolocation

### V3.0 — Globale Skalierung
- Migration Overpass-API → eigener POI-Index (PostGIS)
- Tile-Pre-Computation als nightly Batch-Job
- CDN-Distribution der Shadow-Tiles weltweit

---

## 💡 Nicht-offensichtlicher Skalierungshebel

Das MVT-Tile-Format macht den Server quasi CDN-ready. `/shadow/tile/{z}/{x}/{y}.pbf?h=14&date=2026-05-04` als pure Static-Asset-URL behandeln → Cloudflare R2 oder Bunny.net als Layer 2 → eliminiert 90% der Server-Last ohne Code-Changes.
