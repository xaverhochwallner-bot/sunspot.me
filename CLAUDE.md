# Sunspot.me — Claude Guidelines

## Git: commit and push after every change

After completing any code change (no matter how small), always:

1. `git add` the changed files
2. `git commit -m "<short description>"`
3. `git push origin dev`

Do this automatically without asking for confirmation. Every change must be saved to the remote.

---

## Project Vision

Sunspot shows real-time sun shadow maps on a city map so users can find sunny spots (cafés, parks, Gastgärten).

**Business model:** Freemium — real-time is free, forecasts/planning is paid, premium listings for local hospitality.

**Current focus: V1.0 Wien MVP** — perfect locally before scaling globally. See `ROADMAP.md` for the full task list and version roadmap.

---

## Tech Stack

- `sunspot/` — Flutter Web (compiled as PWA, Mobile-First), MapLibre GL via `maplibre_gl ^0.25.0`
- `sunspot_server/` — Python Flask, shadow computation via Shapely/pyproj, buildings from OSM PBF

---

## How to Run Locally

**Python server** (run from PowerShell, NOT git bash):
```powershell
cd C:\Users\xaver\OneDrive\Desktop\SunspotProjects\Sunspot.me\sunspot_server
python main.py
```
To restart: close the PowerShell terminal and open a new one. `taskkill` is unreliable for Python on Windows.

**Flutter:**
```powershell
cd C:\Users\xaver\OneDrive\Desktop\SunspotProjects\Sunspot.me\sunspot
flutter run -d chrome
```
Never browser-refresh the Flutter tab — kill dart.exe and navigate to the URL fresh.

**Full app URL (local):** `http://localhost:PORT/?server=http://localhost:5000`

---

## Deploy

**Cloudflare Pages (Flutter web):**
```powershell
cd C:\Users\xaver\OneDrive\Desktop\SunspotProjects\Sunspot.me\sunspot
flutter build web --release
$env:CLOUDFLARE_API_TOKEN="<token>"  # stored in your local env or password manager
wrangler pages deploy build/web --project-name=sunspot --commit-dirty=true
```
Live URL: `https://sunspot.pages.dev/?server=https://sunspotme.duckdns.org`

**GCP Server (Python):**
```bash
cd ~/sunspot.me && git pull origin dev && sudo systemctl restart sunspot
```
Instance: `sunspot-server`, e2-standard-2, europe-west3, IP: 34.185.193.147, DuckDNS: `sunspotme.duckdns.org`

---

## Architecture Rules

### Shadow rendering — LOCKED, do not change without explicit user request
These were confirmed optimal by the user across zoom levels 12–18:
- Layer colors: l0=`#4a6d8a`, l1=`#3d5f7d`, l2=`#2d4862`
- Opacity formula: l0=`0.20+t*0.10`, l1=`0.22+t*0.13`, l2=`0.24+t*0.16` (t = elevation.clamp(0,60)/60)
- Night (elevation ≤ 0): l0=0.82, l1=0.0, l2=0.0
- Never add client-side viewport padding in `fetchShadows()` — server adds 15% VIEWPORT_PAD already
- Never add a zoom-based sharpness multiplier — server handles zoom-dependent ring sizes
- Always include `fillColor` in `setLayerProperties` calls (omitting it resets to black/brownish tint)

### Pointer events / map interaction
- **Solved** via Column/Row non-overlapping layout — map and UI are in separate screen regions, no z-stacking
- Mobile: `Column([mapArea, mobileBottom])`, Desktop: `Row([mapArea, sidebar])`
- GPS/zoom buttons use `_ignoreNextMapClick = true` to prevent tap-through
- Do NOT attempt JS-interop approaches to fix pointer events — all have been tried and failed (see memory)

### Tile format
- Shadow tiles are served as MVT (MapBox Vector Tiles) via `/shadow/tile/{z}/{x}/{y}.pbf`
- This makes them CDN-cacheable — treat the URL as a static asset key

---

## Key Constraints

- Wien is hardcoded everywhere for V1.0 (LOAD_BBOX, _CITY_BBOX, Nominatim viewbox, OSM PBF path). This is intentional for now.
- `config/cities.json` skeleton is on the roadmap before V2.0 (multi-city).
- Shadow erosion params, gap_fill, simplify_tolerance are tuned for Vienna's urban density — do not change for other cities without re-tuning.

---

## What NOT to Do

- Do not change shadow rendering parameters (colors, opacity formulas) without user confirmation
- Do not add client-side bbox padding in shadow fetch calls
- Do not restart the Flask server via `taskkill` or bash background processes — always PowerShell terminal
- Do not browser-refresh the Flutter dev tab — kill dart and navigate fresh
- Do not add `geopandas` usage — only `shapely` is needed (geopandas import costs ~30% startup time)
