# PLAN: Responsive GPS Compass Feature (3-State Logic)

## 1. Current State Analysis

### What exists in `main.dart` today

| Item | Current Status |
|------|---------------|
| GPS Button | Custom `FloatingActionButton.small` with `Icons.my_location` — **NOT** the native MapLibre button |
| Button position | Already responsive: bottom-left on mobile, bottom-right on desktop |
| Location tracking | One-shot `Geolocator.getCurrentPosition()` — no continuous stream |
| Blue dot | Custom GeoJSON `CircleLayer` (pulse ring + solid dot) via `_showMyLocationDot()` |
| Compass / heading | `compassEnabled: false` on MapLibreMap. No heading tracking anywhere. |
| `myLocationEnabled` | NOT set on `MapLibreMap` widget |
| `myLocationTrackingMode` | NOT set on `MapLibreMap` widget |
| Packages available | `geolocator: ^13.0.1`, `maplibre_gl: ^0.25.0` — **no** `flutter_compass` |

**Key insight:** We already own the GPS button UI (it's a plain Flutter FAB), and the blue dot is a fully custom layer. This gives us clean control over everything — we do not need to fight the native MapLibre location system at all.

---

## 2. Architecture Concept

### 2a. MapLibre Control: Native API vs. Manual Camera

**Decision: Use manual camera control + `Geolocator` stream. Do NOT enable `myLocationTrackingMode`.**

Reasons:
- `myLocationTrackingMode` (values: `none`, `tracking`, `trackingCompass`) is a MapLibre-internal flag that conflicts with our custom GeoJSON blue dot. Enabling it would show two location indicators.
- It doesn't expose a "State 2 only on mobile" split without hacks.
- We already call `_mapController.animateCamera()` manually — continuing this pattern is consistent and gives full control over zoom, bearing, and tilt independently.
- `Geolocator.getPositionStream()` gives us a continuous `Stream<Position>` for State 1 and 2. We stop the stream subscription when returning to State 0.

**For compass heading (State 2):**  
Add `flutter_compass` to `pubspec.yaml`. It provides `FlutterCompass.events` — a `Stream<CompassEvent>` with `heading` (degrees from North). On each heading update in State 2, call:
```dart
_mapController?.animateCamera(
  CameraUpdate.newCameraPosition(
    CameraPosition(target: _gpsPosition!, zoom: currentZoom, bearing: heading),
  ),
);
```

---

### 2b. UI Control: Custom FAB (keep) vs. Native Button (discard)

**Decision: Keep the existing custom `FloatingActionButton`. Extend it with state-driven icon and color.**

The native MapLibre location button is hidden by default (we never enabled it). Our FAB is already the button. We only need to:

1. Add an `int _gpsState = 0;` state variable (0 / 1 / 2).
2. Drive the FAB `child` icon from `_gpsState`:

| State | Icon | Color |
|-------|------|-------|
| 0 — Inactive | `Icons.my_location` (outlined / grey) | `Colors.black54` |
| 1 — Location Tracking | `Icons.my_location` (filled / blue) | `Colors.blue` |
| 2 — Compass Tracking | `Icons.explore` or `Icons.navigation` (filled / blue) | `Colors.blue` |

3. On tap, cycle: 0 → 1 → 2 → 0 (on mobile), or 0 → 1 → 0 (on desktop).

**No separate widget file needed** — the FAB definition is in the existing `Positioned` block (lines 2576–2590).

---

### 2c. Mobile / Desktop Split

**Decision: Use the existing `isMobile` flag + `kIsWeb` for the heading capability check.**

The codebase already computes `isMobile` (visible in the button positioning logic at line 2576). No new platform-detection logic is needed.

```dart
// Pseudo-code — tap handler cycle
void _onGpsButtonTap() {
  if (_gpsState == 0) {
    _enterState1();
  } else if (_gpsState == 1) {
    if (isMobile) {
      _enterState2();   // Compass only on mobile
    } else {
      _enterState0();   // Desktop: wrap back to 0
    }
  } else {
    _enterState0();
  }
}
```

**What changes by platform:**

| Platform | State 0 | State 1 | State 2 |
|----------|---------|---------|---------|
| Mobile | ✓ | ✓ Center + follow | ✓ Center + rotate |
| Desktop / Web | ✓ | ✓ Center (one-shot or stream) | — (skipped) |

The button is always visible on both platforms (no hide/show needed).

---

## 3. State Machine Details

### State Transitions

```
         tap              tap
  [0] ──────→ [1] ──────────→ [2]   (mobile only)
   ↑           |               |
   └───────────┴───────────────┘
      manual pan OR tap from State 2
```

### What each state does

**State 0 — Inactive**
- Stop `_positionStream` subscription (if active).
- Stop `_compassStream` subscription (if active).
- Reset map bearing to 0 (North-up) optionally, or leave as-is.
- Button: grey outlined icon.

**State 1 — Location Tracking**
- Start `Geolocator.getPositionStream(locationSettings: LocationSettings(accuracy: LocationAccuracy.high))`.
- On each position event: update `_gpsPosition`, update GeoJSON blue dot, call `animateCamera` to center (no bearing change).
- Button: filled blue `my_location` icon.

**State 2 — Compass Tracking (mobile only)**
- Keep position stream from State 1 running.
- Start `FlutterCompass.events` subscription.
- On each compass event: call `animateCamera` with current `_gpsPosition` as target AND `bearing: heading`.
- The blue dot should also rotate to show heading — update the custom dot layer with a directional cone (or use a rotated symbol layer instead of a circle).
- Button: filled blue `explore`/`navigation` icon.

### Manual Pan Detection → Return to State 0

MapLibre fires `onCameraMove`. We need to distinguish user-initiated moves from our own `animateCamera` calls.

**Pattern:** Set a `bool _programmaticMove = false` flag before every `animateCamera` call. In `onCameraMove`, if `!_programmaticMove`, the user is panning → call `_enterState0()`. Reset the flag in `onCameraIdle`.

```dart
// Before animateCamera:
_programmaticMove = true;
await _mapController?.animateCamera(...);

// onCameraMove callback:
void _onCameraMove(CameraPosition pos) {
  if (!_programmaticMove && _gpsState != 0) {
    _enterState0();
  }
}

// onCameraIdle callback (already exists):
void _onCameraIdle() {
  _programmaticMove = false;
  // ... existing logic
}
```

---

## 4. New Package Required

**`flutter_compass`** — provides `CompassEvent` with `heading` (double, degrees 0–360).

Add to `pubspec.yaml`:
```yaml
flutter_compass: ^0.8.0   # or latest
```

**Platform notes:**
- Android: uses `TYPE_ROTATION_VECTOR` sensor — works without extra permissions.
- iOS: requires `NSMotionUsageDescription` in `Info.plist` (already needed for most apps).
- Web/Desktop: `FlutterCompass.events` emits `null` or an empty stream — safe to guard with `if (isMobile)`.

---

## 5. Files to Change

| File | Change |
|------|--------|
| `sunspot/pubspec.yaml` | Add `flutter_compass` |
| `sunspot/lib/main.dart` | Add `_gpsState`, `_positionStreamSub`, `_compassStreamSub`, `_programmaticMove`; refactor `_goToMyLocation` → state machine; update FAB icon/color logic; wire `onCameraMove` |
| `sunspot/ios/Runner/Info.plist` | Add `NSMotionUsageDescription` (if not already present) |

No new files are needed. No existing widget extractions required.

---

## 6. Open Questions / Risks

1. **`flutter_compass` on web:** The package may throw or silently return null on Chrome. Must wrap all compass subscriptions in `if (isMobile)` guards before starting any stream.

2. **Blue dot heading cone (State 2):** Current dot is a plain `CircleLayer`. For State 2 it would be more informative to show a directional cone (field-of-view arc). This requires replacing the circle with a `SymbolLayer` using a custom heading arrow image, or drawing a `FillLayer` arc — a non-trivial addition. **Recommendation:** Ship State 2 with the plain blue dot first, add the cone in a follow-up.

3. **Camera jitter in State 2:** Compass events fire at ~20 Hz on some devices. Calling `animateCamera` at that rate can cause jitter. Throttle to max ~5 Hz (every 200 ms) and apply a heading delta threshold (e.g., only update if `|newHeading - lastHeading| > 2°`).

4. **`_programmaticMove` race condition:** `animateCamera` is async. If the user pans before `onCameraIdle` fires, the flag stays `true`. Add a fallback timeout reset (e.g., 1 500 ms after the camera call) to be safe.

5. **Existing `_goToMyLocation` zoom-step logic:** States 1 and 2 continuously re-center. The current "zoom in one step per tap" behavior should only apply on the first transition to State 1 (not on every position update). Preserve this UX on state entry, not on stream updates.
