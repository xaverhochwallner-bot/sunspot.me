import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'services/api_client.dart';
import 'state/app_shell_state.dart';
import 'state/saved_spots_state.dart';
import 'state/search_state.dart';
import 'state/weather_state.dart';
import 'utils/time_utils.dart';
import 'widgets/desktop_sidebar.dart';
import 'widgets/mobile_bottom_sheet.dart';
import 'widgets/weather_widget.dart';

void main() async {
  const sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');
  await SentryFlutter.init(
    (options) {
      options.dsn = sentryDsn;
      options.tracesSampleRate = 0.1;
      options.environment = const String.fromEnvironment('FLUTTER_ENV', defaultValue: 'production');
    },
    appRunner: () => runApp(const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppShellState()),
        ChangeNotifierProvider(create: (_) => WeatherState()),
        ChangeNotifierProvider(create: (_) => SavedSpotsState()),
        ChangeNotifierProvider(create: (_) => SearchState()),
      ],
      child: const MaterialApp(
        title: 'Sunshadow Map',
        home: SunMapScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class SunMapScreen extends StatefulWidget {
  const SunMapScreen({super.key});

  @override
  State<SunMapScreen> createState() => _SunMapScreenState();
}

class _SunMapScreenState extends State<SunMapScreen> with SingleTickerProviderStateMixin {
  // Auto-detects the Flask server from the page's host (same machine, port 5000).
  // Override with ?server=https://your-tunnel-url for Cloudflare/ngrok tunnels.
  static String get flaskBaseUrl {
    final uri = Uri.base;
    final override = uri.queryParameters['server'];
    if (override != null && override.isNotEmpty) {
      return override.replaceAll(RegExp(r'/$'), '');
    }
    return '${uri.scheme}://${uri.host}:5000';
  }
  static const String mapStyle     = 'https://basemaps.cartocdn.com/gl/voyager-gl-style/style.json';

  late final ApiClient _api = ApiClient(flaskBaseUrl);

  AppShellState   get _shell   => context.read<AppShellState>();
  WeatherState    get _weather => context.read<WeatherState>();
  SavedSpotsState get _saved   => context.read<SavedSpotsState>();
  SearchState     get _search  => context.read<SearchState>();

  final GlobalKey _mapKey = GlobalKey();
  MapLibreMapController? _mapController;
  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  LatLng? _lastSearchCenter;
  double? _lastSearchZoom;
  bool    _suppressResultClear = false;
  Timer? _debounceTimer;

  double   _hour          = 12.0; // overridden in initState with correct Vienna time
  DateTime _selectedDate  = DateTime.now();
  bool     _loading       = false;
  bool     _mapReady      = false;
  bool     _animating      = false;
  bool     _preloading24h  = false;
  bool     _draggingSlider = false;

  double              _loadingProgress = 0.0;
  String              _loadingStage    = '';
  bool                _showPill        = false;  // only true after 150ms delay
  Timer?              _pillTimer;
  Timer?              _sliderDebounce;
  int                 _fetchGen        = 0;
  Completer<void>?    _fetchCompleter;
  bool                _shadowLayersReady = false;
  int                 _lastFetchZoom     = -1;
  double              _currentZoom       = 14.0;
  String?             _currentTileUrl;
  int                 _shadowSourceNonce = 0;  // bumped per time-change rebuild; used for both macro + micro source IDs
  int                 _prevNonce         = -1; // nonce of ghost layers kept dimmed while new tiles load; cleaned up after idle
  int                 _dimmedGhostNonce  = -1; // second ghost kept at 0-opacity during animation idle-timeout fallback
  int                 _preloadGen        = 0;  // incremented each preload run; stale .then() callbacks check this

  // Panel (state lives in AppShellState)

  // Live mode
  bool   _liveMode  = false;
  Timer? _liveTimer;
  // _animSpeed removed — animation runs at a single fixed pace (no speed cycling)

  // Sunrise / sunset (local hours, e.g. 6.0, 20.0)
  double? _sunriseHour;
  double? _sunsetHour;

  // Point info popup
  bool                   _pointInfoLoading = false;
  Map<String, dynamic>?  _pointInfo;
  bool                   _ignoreNextMapClick = false;
  VoidCallback?          _refreshPointSheet;
  bool                   _pinLayerReady = false;
  double                 _screenWidth = 1200;

  // GPS blue dot
  LatLng? _gpsPosition;
  bool    _myLocationLayerReady = false;

  // GPS tracking state machine: 0=inactive, 1=location, 2=compass
  int                       _gpsState        = 0;
  StreamSubscription<Position>? _positionStreamSub;
  Timer?                    _compassPollTimer;
  double                    _lastHeading     = 0;

  // Current map bearing (degrees CW from north) — drives compass button
  double                    _mapBearing      = 0;

  // Sunny spots
  List<Map<String, dynamic>> _sunnySpots          = [];
  bool                       _sunnySpotsLayerReady = false;
  bool                       _findingSunnySpots    = false;
  bool                       _spotsNoResults       = false;
  bool                       _poisNoResults        = false;
  List<Offset>               _sunnySpotScreenPos   = [];
  List<Offset>               _tourMarkerScreenPos  = [];
  List<Offset>               _poiScreenPos         = [];

  // Search result marker
  LatLng?                    _searchMarkerPos;
  String?                    _searchMarkerName;
  Offset?                    _searchMarkerScreenPos;
  bool                       _showSearchMarkerDetail = false;
  Map<String, dynamic>?      _searchMarkerInfo;

  // Places (POI) mode
  bool                       _placesMode        = false;
  List<Map<String, dynamic>> _sunnyPois         = [];
  bool                       _loadingPois       = false;
  bool                       _poiMarkersReady   = false;


  bool                       _spotsZoomHint     = false;

  // Weather overlay (state lives in WeatherState)



  // Saved spots + addresses live in SavedSpotsState

  // Sunny Tour
  int                        _tourDuration    = 30;   // minutes
  List<Map<String, dynamic>> _tourSpots       = [];
  bool                       _tourBuilding    = false;
  bool                       _tourLayerReady  = false;

  // Saved spots sunny status lives in SavedSpotsState

  // Spot detail navigation (spot+idx live in AppShellState)
  LatLng? _detailReturnCenter;
  double? _detailReturnZoom;

  // Panel scroll
  final ScrollController _panelScroll = ScrollController();

  // Mobile bottom UI (mobileTab lives in AppShellState)
  int _spotsSearchGen = 0; // incremented on tab-switch to cancel in-flight searches
  int _poisSearchGen  = 0;
  final ScrollController _mobileContentScroll = ScrollController();

  bool get _isMobile => _screenWidth < 650;

  // Search UI controls (lifecycle-bound — kept here; data lives in SearchState)
  final TextEditingController _searchController = TextEditingController();
  final FocusNode             _searchFocus      = FocusNode();

  late final AnimationController _sunSpinCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void initState() {
    super.initState();
    final now = viennaNow();
    _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
    _selectedDate = DateTime(now.year, now.month, now.day);
    _searchFocus.addListener(() { if (mounted) setState(() {}); });
  }

  String get _formattedDate {
    return '${_selectedDate.day.toString().padLeft(2, '0')}.'
           '${_selectedDate.month.toString().padLeft(2, '0')}.'
           '${_selectedDate.year}';
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  // -------------------------------------------------------------------------
  // Map callbacks
  // -------------------------------------------------------------------------

  void _onMapCreated(MapLibreMapController controller) {
    _mapController = controller;
    _injectTileLoadHelper();
  }

  // Monkey-patch maplibregl.Map.prototype.addSource so the first shadow-source
  // call captures the JS map instance and exposes areTilesLoaded() globally.
  // Also intercepts window.fetch to count shadow tile requests for real progress.
  void _injectTileLoadHelper() {
    try {
      js.context.callMethod('eval', [r'''
        (function() {
          if (window.__sunspot_patched) return;
          window.__sunspot_patched = true;

          // --- idle-event tracking ---
          window.__sp_idle    = false;
          window.__sp_waiting = false;
          // Called right before addSource so idle fires AFTER our tiles load.
          window.__sunspot_startWait = function() { window.__sp_idle = false; window.__sp_waiting = true; };
          window.__sunspot_isIdle    = function() { return window.__sp_idle === true; };
          window.__sunspot_stopWait  = function() { window.__sp_waiting = false; window.__sp_idle = false; };

          function patch() {
            if (typeof maplibregl === 'undefined') { setTimeout(patch, 50); return; }
            var orig = maplibregl.Map.prototype.addSource;
            maplibregl.Map.prototype.addSource = function(id, src) {
              if (!window.__sunspot_map) {
                window.__sunspot_map = this;
                // Hook the idle event once — fires when all tiles are rendered.
                this.on('idle', function() {
                  if (window.__sp_waiting) window.__sp_idle = true;
                });
                // Detect user-initiated pans (originalEvent is null for programmatic moves).
                window.__sunspot_userPanned = false;
                this.on('movestart', function(e) {
                  if (e.originalEvent) window.__sunspot_userPanned = true;
                });
              }
              return orig.call(this, id, src);
            };
          }
          patch();
          window.__sunspot_tilesLoaded = function() {
            if (!window.__sunspot_map) return true;
            try { return window.__sunspot_map.areTilesLoaded(); } catch(e) { return true; }
          };

          // Intercept fetch() for shadow tile URLs to track 0–100% progress.
          window.__sp_pending = 0; window.__sp_done = 0;
          window.__sunspot_resetProgress = function() { window.__sp_pending = 0; window.__sp_done = 0; };
          window.__sunspot_tileProgress = function() {
            var p = window.__sp_pending || 0, d = window.__sp_done || 0;
            // Return 0.0 (not 1.0) when no fetches observed — indeterminate, not "done".
            return p === 0 ? 0.0 : Math.min(d / p, 1.0);
          };
          (function() {
            var _origFetch = window.fetch;
            window.fetch = function(url, opts) {
              var u = typeof url === 'string' ? url : (url && url.url) || '';
              if (u.indexOf('/shadow/tile/') >= 0) {
                window.__sp_pending = (window.__sp_pending || 0) + 1;
                return _origFetch.apply(this, arguments).then(function(r) {
                  window.__sp_done = (window.__sp_done || 0) + 1; return r;
                }, function(e) {
                  window.__sp_done = (window.__sp_done || 0) + 1; throw e;
                });
              }
              return _origFetch.apply(this, arguments);
            };
          })();
        })();
      ''']);
    } catch (_) {}
  }

  void _resetTileProgress() {
    try {
      js.context.callMethod('eval',
          ['window.__sunspot_resetProgress&&window.__sunspot_resetProgress()']);
    } catch (_) {}
  }

  double _tileProgress() {
    try {
      return (js.context.callMethod('eval',
          ['(window.__sunspot_tileProgress||function(){return 0.0;})()']) as num?)
              ?.toDouble() ?? 0.0;
    } catch (_) { return 0.0; }
  }

  void _startIdleWait() {
    try {
      js.context.callMethod('eval', ['window.__sunspot_startWait&&window.__sunspot_startWait()']);
    } catch (_) {}
  }

  bool _isIdle() {
    try {
      return js.context.callMethod('eval',
          ['(window.__sunspot_isIdle||function(){return true;})()']) as bool? ?? true;
    } catch (_) { return true; }
  }

  void _stopIdleWait() {
    try {
      js.context.callMethod('eval', ['window.__sunspot_stopWait&&window.__sunspot_stopWait()']);
    } catch (_) {}
  }

  Future<void> _onStyleLoaded() async {
    _mapReady = true;
    _shadowLayersReady    = false;
    _currentTileUrl       = null;
    _shadowSourceNonce    = 0;
    _prevNonce            = -1;
    _dimmedGhostNonce     = -1;
    _preloading24h        = false;
    _animating            = false;
    _preloadGen++;
    _pinLayerReady        = false;
    _myLocationLayerReady = false;
    _sunnySpotsLayerReady = false;
    _tourLayerReady       = false;
    _poiMarkersReady      = false;
    _injectAttributionCss();
    _saved.load();
    _search.load();
    Future.delayed(const Duration(milliseconds: 500),
        () => _saved.refreshSunnyStatus(_api, _selectedDate, _hour));

    // Handle shared tour link: ?tour_lat=...&tour_lon=...&tour_duration=...
    final params = Uri.base.queryParameters;
    final tLat = double.tryParse(params['tour_lat'] ?? '');
    final tLon = double.tryParse(params['tour_lon'] ?? '');
    if (tLat != null && tLon != null) {
      final dur = int.tryParse(params['tour_duration'] ?? '') ?? _tourDuration;
      _currentCenter  = LatLng(tLat, tLon);
      _tourDuration   = dur;

      // Dismiss splash before animating to the shared location
      if (mounted) _shell.hideSplash();
      await _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(_currentCenter, 15.0));
      if (_isMobile) _shell.setMobileTab(2);
      await Future.delayed(const Duration(milliseconds: 800));
      fetchShadows();
      _buildTour();
      return; // skip GPS acquisition for tour links
    }

    // Normal startup: acquire GPS silently first, then reveal map + fetch shadows.
    // _initGpsOnStart() will reposition the camera, dismiss the splash, and call
    // fetchShadows() once the correct center is known — avoiding a wasted tile
    // fetch for the Vienna fallback that would otherwise get discarded by GPS.
    _fetchWeather(_currentCenter.latitude, _currentCenter.longitude);
    _initGpsOnStart();
  }

  void _injectAttributionCss() {
    final style = html.StyleElement();
    style.text =
        // Hide attribution and logo entirely
        '.maplibregl-ctrl-attrib { display: none !important; }'
        '.maplibregl-ctrl-logo { display: none !important; }'
        '.maplibregl-ctrl-bottom-right { display: none !important; }';
    html.document.head!.append(style);
  }

  bool _checkAndClearUserPanned() {
    try {
      final panned = js.context.callMethod('eval', ['!!window.__sunspot_userPanned']) as bool? ?? false;
      if (panned) js.context.callMethod('eval', ['window.__sunspot_userPanned = false']);
      return panned;
    } catch (_) { return false; }
  }

  void _onCameraIdle() {
    if (_mapController == null) return;
    // User panned the map while GPS tracking was active → drop back to inactive.
    if (_gpsState > 0 && _checkAndClearUserPanned()) _enterState0();
    final pos    = _mapController!.cameraPosition;
    final center = pos?.target;
    if (center == null) return;
    _currentCenter = center;

    final zoom = pos?.zoom ?? 0;
    if (zoom != _currentZoom) setState(() => _currentZoom = zoom);
    if (_suppressResultClear) {
      _lastSearchCenter = center;
      _lastSearchZoom   = zoom;
      _suppressResultClear = false;
    }

    if (_sunnySpots.isNotEmpty) _refreshSunnySpotPositions();
    if (_tourSpots.isNotEmpty) _refreshTourMarkerPositions();
    if (_sunnyPois.isNotEmpty) _refreshPoiPositions();
    if (_searchMarkerPos != null) _refreshSearchMarkerPosition();

    // Update compass needle when bearing changes.
    final bearing = pos?.bearing ?? 0.0;
    if ((bearing - _mapBearing).abs() > 0.5) setState(() => _mapBearing = bearing);

    _debounceTimer?.cancel();
    // When zoom changes significantly (> 0.5 levels), use a very short debounce so
    // stale shadow data from the previous zoom is not shown for a full 600 ms.
    final zoomDelta = _lastFetchZoom >= 0 ? (zoom - _lastFetchZoom).abs() : 0.0;
    final debounceMs = zoomDelta > 0.5 ? 100 : 600;
    // Skip shadow refetch when GPS tracking merely re-centres the map (no zoom change).
    if (_gpsState == 0 || zoomDelta > 0.1) {
      _debounceTimer = Timer(Duration(milliseconds: debounceMs), fetchShadows);
    }
  }

  void _onMapClick(Point<double> point, LatLng coordinates) {
    if (_ignoreNextMapClick) {
      _ignoreNextMapClick = false;
      return;
    }
    // Reject clicks in the sidebar zone (desktop only)
    if (!_isMobile && point.x > _screenWidth - 280) return;
    if (_search.results.isNotEmpty) {
      _search.clearResults(setPointerEvents: _setMapPointerEvents);
      return;
    }
    // Point inspection only active on Saved tab
    if (_shell.mobileTab != 3) return;
    setState(() {
      _pointInfo         = null;
      _pointInfoLoading  = true;
    });
    _showPin(coordinates);
    _fetchPointInfo(coordinates);
    _showPointSheet(coordinates);
  }

  Future<void> _fetchPointInfo(LatLng point) async {
    try {
      final d    = _selectedDate;
      final data = await _api.fetchPointInfo(
        point.latitude, point.longitude,
        formatDate(d), _hour.toInt(), ((_hour * 60).toInt() % 60),
      );
      if (mounted) {
        setState(() { _pointInfo = data; _pointInfoLoading = false; });
        _refreshPointSheet?.call();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _pointInfoLoading = false);
        _refreshPointSheet?.call();
      }
    }
  }

  Future<void> _showPin(LatLng point) async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final geoJson = {
      'type': 'FeatureCollection',
      'features': [{
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [point.longitude, point.latitude]},
        'properties': {},
      }],
    };
    if (_pinLayerReady) {
      await ctrl.setGeoJsonSource('clicked-point', geoJson);
    } else {
      await ctrl.addSource('clicked-point', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer(
        'clicked-point', 'clicked-point-outer',
        CircleLayerProperties(
          circleRadius: 12,
          circleColor: '#FF8C00',
          circleOpacity: 0.25,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'clicked-point', 'clicked-point-inner',
        CircleLayerProperties(
          circleRadius: 6,
          circleColor: '#FF8C00',
          circleOpacity: 1.0,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _pinLayerReady = true;
    }
  }

  Future<void> _hidePin() async {
    if (!_pinLayerReady) return;
    final ctrl = _mapController;
    if (ctrl == null) return;
    await ctrl.setGeoJsonSource('clicked-point',
        {'type': 'FeatureCollection', 'features': []});
  }

  // -------------------------------------------------------------------------
  // Sunny spots
  // -------------------------------------------------------------------------

  Future<void> _findSunnySpots() async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;

    final zoom = ctrl.cameraPosition?.zoom ?? 0;
    if (zoom < 13) {
      setState(() { _spotsZoomHint = true; _sunnySpots = []; });
      _clearSunnySpots();
      return;
    }

    final gen = ++_spotsSearchGen;
    setState(() { _findingSunnySpots = true; _spotsZoomHint = false; _spotsNoResults = false; });
    _lastSearchCenter = ctrl.cameraPosition?.target;
    _lastSearchZoom   = ctrl.cameraPosition?.zoom;
    await _clearTourLine();
    try {
      final bounds = await ctrl.getVisibleRegion();
      final zoom   = ctrl.cameraPosition?.zoom ?? 15.0;
      final h      = _hour.toInt();
      final min    = ((_hour * 60).toInt() % 60);
      final date   = _selectedDate;

      final dateStr = formatDate(date);
      final clat = _currentCenter.latitude;
      final clon = _currentCenter.longitude;
      final minLat = bounds.southwest.latitude;
      final minLon = bounds.southwest.longitude;
      final maxLat = bounds.northeast.latitude;
      final maxLon = bounds.northeast.longitude;
      final zoomInt = zoom.round();

      // Run grid spots + parks + squares in parallel
      final results = await Future.wait([
        _api.findSunnySpots(
          lat: clat, lon: clon, minLat: minLat, minLon: minLon,
          maxLat: maxLat, maxLon: maxLon,
          hour: h, minute: min, month: date.month, day: date.day,
          zoom: zoomInt, n: 8,
        ),
        _api.findSunnyPois(
          lat: clat, lon: clon, minLat: minLat, minLon: minLon,
          maxLat: maxLat, maxLon: maxLon,
          hour: h, minute: min, date: dateStr, types: 'park', zoom: zoomInt,
        ),
        _api.findSunnyPois(
          lat: clat, lon: clon, minLat: minLat, minLon: minLon,
          maxLat: maxLat, maxLon: maxLon,
          hour: h, minute: min, date: dateStr, types: 'square', zoom: zoomInt,
        ),
      ]);
      if (!mounted || gen != _spotsSearchGen) return;

      List<Map<String, dynamic>> parsePois(Map<String, dynamic>? data, String category) {
        if (data == null) return [];
        try {
          if (data['reason'] == 'zoom_in') return [];
          return (data['spots'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>().map((p) => <String, dynamic>{
            'lat': (p['lat'] as num).toDouble(),
            'lon': (p['lon'] as num).toDouble(),
            'sun_hours_left': p['sun_hours'] as int? ?? (p['sun_hours_left'] as int? ?? 0),
            'sun_until': p['sun_until'] as int?,
            '_poi_name': p['name'] as String? ?? '',
            '_poi_amenity': p['amenity'] as String? ?? '',
            '_category': category,
          }).take(3).toList();
        } catch (_) { return []; }
      }

      final gridData   = results[0];
      final gridReason = gridData?['reason'] as String? ?? '';

      if (gridReason == 'night') {
        setState(() { _sunnySpots = []; _spotsZoomHint = false; });
        _showError('No sun at this hour — move the time slider');
        return;
      }

      final gridSpots = ((gridData?['spots'] as List<dynamic>?) ?? []).map((s) => <String, dynamic>{
        'lat':            (s['lat']  as num).toDouble(),
        'lon':            (s['lon']  as num).toDouble(),
        'sun_hours_left': (s['sun_hours_left'] as num?)?.toInt() ?? 0,
        'sun_until':      s['sun_until'] as int?,
        '_category':      'spot',
      }).take(3).toList();

      final parks   = parsePois(results[1], 'park');
      final squares = parsePois(results[2], 'square');

      // Merge all, sort by sun hours desc, cap at 8
      final merged = [...gridSpots, ...parks, ...squares];
      final zoomIn = merged.isEmpty && gridReason == 'zoom_in';
      setState(() => _spotsZoomHint = zoomIn);
      merged.sort((a, b) => ((b['sun_hours_left'] as int?) ?? 0)
          .compareTo((a['sun_hours_left'] as int?) ?? 0));
      final allSpots = merged.take(8).toList();

      setState(() { _sunnySpots = allSpots; _spotsNoResults = allSpots.isEmpty && !zoomIn; });
      _geocodeSpots(allSpots);
      await _showSunnySpotMarkers(allSpots);
      await _refreshSunnySpotPositions();

      if (allSpots.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (_isMobile) {
          _shell.setMobileTab(1);
        } else if (_panelScroll.hasClients) {
          _panelScroll.animateTo(
            _panelScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          );
        }
      }
    } on TimeoutException {
      if (mounted) _showError('Search timed out — try zooming in closer');
    } catch (_) {
      if (mounted) _showError('Could not find sunny spots');
    } finally {
      if (mounted) setState(() => _findingSunnySpots = false);
    }
  }

  Future<void> _showSunnySpotMarkers(List<Map<String, dynamic>> spots) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final features = spots.asMap().entries.map((e) {
      final s = e.value;
      final currentlySunny = (s['sun_until'] != null) ? 1 : 0;
      return {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [s['lon'], s['lat']]},
        'properties': {'index': e.key + 1, 'currently_sunny': currentlySunny},
      };
    }).toList();

    final geoJson = {'type': 'FeatureCollection', 'features': features};

    if (_sunnySpotsLayerReady) {
      await ctrl.setGeoJsonSource('sunny-spots', geoJson);
    } else {
      await ctrl.addSource('sunny-spots', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer(
        'sunny-spots', 'sunny-spots-glow',
        CircleLayerProperties(
          circleRadius: 20,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FFD700', '#999999'],
          circleOpacity: 0.2,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'sunny-spots', 'sunny-spots-dot',
        CircleLayerProperties(
          circleRadius: 8,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FFD700', '#AAAAAA'],
          circleOpacity: 1.0,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _sunnySpotsLayerReady = true;
    }
  }

  Future<void> _clearSunnySpots() async {
    setState(() { _sunnySpots = []; _sunnySpotScreenPos = []; });
    if (!_sunnySpotsLayerReady) return;
    await _mapController?.setGeoJsonSource(
        'sunny-spots', {'type': 'FeatureCollection', 'features': []});
  }

  Future<void> _findSunnyPois() async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;

    final zoom = ctrl.cameraPosition?.zoom ?? 0;
    if (zoom < 13) {
      setState(() => _sunnyPois = []);
      _clearPoiMarkers();
      _showError('Zoom in to see places');
      return;
    }

    final gen = ++_poisSearchGen;
    _lastSearchCenter = ctrl.cameraPosition?.target;
    _lastSearchZoom   = ctrl.cameraPosition?.zoom;
    setState(() { _loadingPois = true; _sunnyPois = []; _poiScreenPos = []; _poisNoResults = false; });
    try {
      final bounds  = await ctrl.getVisibleRegion();
      final d       = _selectedDate;
      final dateStr = formatDate(d);
      final h       = _hour.toInt();
      final min     = ((_hour * 60).toInt() % 60);
      final zoom    = ctrl.cameraPosition?.zoom ?? 15.0;
      final data = await _api.findSunnyPois(
        lat: _currentCenter.latitude, lon: _currentCenter.longitude,
        minLat: bounds.southwest.latitude, minLon: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude, maxLon: bounds.northeast.longitude,
        hour: h, minute: min, date: dateStr, types: 'terrace', zoom: zoom.round(),
      );
      if (!mounted || gen != _poisSearchGen) return;
      if (data != null) {
        final reason = data['reason'] as String? ?? '';
        if (reason == 'night') {
          _showError('No sun at this hour — move the time slider');
          return;
        }
        final list = data['spots'] as List<dynamic>? ?? [];
        final pois = list.cast<Map<String, dynamic>>();
        setState(() { _sunnyPois = pois; _poisNoResults = pois.isEmpty; });
        await _showPoiMarkers(pois);
        await _refreshPoiPositions();
      }
    } on TimeoutException {
      if (mounted) _showError('Search timed out — try zooming in closer');
    } catch (e) {
      if (mounted) _showError('Could not load places');
    } finally {
      if (mounted) setState(() => _loadingPois = false);
    }
  }

  Future<void> _showPoiMarkers(List<Map<String, dynamic>> pois) async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final features = pois.asMap().entries.map((e) {
      final p = e.value;
      final currentlySunny = (p['sun_until'] != null) ? 1 : 0;
      return {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [p['lon'], p['lat']]},
        'properties': {'index': e.key + 1, 'currently_sunny': currentlySunny},
      };
    }).toList();
    final geoJson = {'type': 'FeatureCollection', 'features': features};
    if (_poiMarkersReady) {
      await ctrl.setGeoJsonSource('poi-markers', geoJson);
    } else {
      await ctrl.addSource('poi-markers', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer('poi-markers', 'poi-marker-glow',
        CircleLayerProperties(
          circleRadius: 20,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FF8C00', '#999999'],
          circleOpacity: 0.2, circleStrokeWidth: 0),
        enableInteraction: false,
      );
      await ctrl.addLayer('poi-markers', 'poi-marker-dot',
        CircleLayerProperties(
          circleRadius: 9,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FF8C00', '#AAAAAA'],
          circleOpacity: 1.0, circleStrokeWidth: 2, circleStrokeColor: '#FFFFFF'),
        enableInteraction: false,
      );
      _poiMarkersReady = true;
    }
  }

  Future<void> _clearPoiMarkers() async {
    if (mounted) setState(() => _poiScreenPos = []);
    if (!_poiMarkersReady) return;
    await _mapController?.setGeoJsonSource(
        'poi-markers', {'type': 'FeatureCollection', 'features': []});
  }

  Future<void> _refreshSunnySpotPositions() async {
    final ctrl = _mapController;
    if (ctrl == null || _sunnySpots.isEmpty) return;
    final pts = await Future.wait(
      _sunnySpots.map((s) => ctrl.toScreenLocation(LatLng(s['lat'] as double, s['lon'] as double))),
    );
    if (mounted) setState(() {
      _sunnySpotScreenPos = pts.map((p) => Offset(p.x.toDouble(), p.y.toDouble())).toList();
    });
  }

  Future<void> _refreshTourMarkerPositions() async {
    final ctrl = _mapController;
    if (ctrl == null || _tourSpots.isEmpty) return;
    final pts = await Future.wait(
      _tourSpots.map((s) => ctrl.toScreenLocation(LatLng(s['lat'] as double, s['lon'] as double))),
    );
    if (mounted) setState(() {
      _tourMarkerScreenPos = pts.map((p) => Offset(p.x.toDouble(), p.y.toDouble())).toList();
    });
  }

  Future<void> _refreshPoiPositions() async {
    final ctrl = _mapController;
    if (ctrl == null || _sunnyPois.isEmpty) return;
    final pts = await Future.wait(
      _sunnyPois.map((s) => ctrl.toScreenLocation(LatLng(s['lat'] as double, s['lon'] as double))),
    );
    if (mounted) setState(() {
      _poiScreenPos = pts.map((p) => Offset(p.x.toDouble(), p.y.toDouble())).toList();
    });
  }

  Future<void> _refreshSearchMarkerPosition() async {
    final ctrl = _mapController;
    if (ctrl == null || _searchMarkerPos == null) return;
    final pt = await ctrl.toScreenLocation(_searchMarkerPos!);
    if (mounted) setState(() {
      _searchMarkerScreenPos = Offset(pt.x.toDouble(), pt.y.toDouble());
    });
  }

  // -------------------------------------------------------------------------
  // Saved spots + home address — delegated to SavedSpotsState / SearchState
  // -------------------------------------------------------------------------

  void _setHomeAddress(Map<String, dynamic> result) => _search.setHome(result);

  void _navigateToHome() {
    final home = _search.homeAddress;
    if (home == null) return;
    _selectSearchResult(home);
  }

  // -------------------------------------------------------------------------
  // Weather (Open-Meteo, no API key)
  // -------------------------------------------------------------------------

  Future<void> _fetchWeather(double lat, double lon) =>
      _weather.fetch(_api, lat, lon);

  // -------------------------------------------------------------------------
  // Reverse geocoding (Nominatim)
  // -------------------------------------------------------------------------

  Future<void> _geocodeSpots(List<Map<String, dynamic>> spots) async {
    for (final spot in spots) {
      // Skip POI add-ons — they already have a name from OSM
      if ((spot['_poi_name'] as String? ?? '').isNotEmpty) continue;
      final lat = spot['lat'] as double;
      final lon = spot['lon'] as double;
      await _reverseGeocode(lat, lon);
      await Future.delayed(const Duration(milliseconds: 300)); // respect Nominatim rate limit
    }
  }

  Future<String> _reverseGeocode(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    if (_saved.addresses.containsKey(key)) return _saved.addresses[key]!;
    final label = await _api.reverseGeocode(lat, lon);
    if (mounted && label.isNotEmpty) _saved.cacheAddress(key, label);
    return label;
  }

  // -------------------------------------------------------------------------
  // Spot popup
  // -------------------------------------------------------------------------

  void _selectSpot(Map<String, dynamic> spot, int idx) {
    _detailReturnCenter = _lastSearchCenter ?? _currentCenter;
    _detailReturnZoom   = _lastSearchZoom ?? _mapController?.cameraPosition?.zoom ?? 14.0;
    final lat = spot['lat'] as double;
    final lon = spot['lon'] as double;
    _shell.collapsePanel();
    _suppressResultClear = true;
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lon), 15.5));
    _shell.selectSpot(spot, idx);
    _panelScroll.jumpTo(0);
  }

  void _closeSpotDetail() {
    _shell.clearSpot();
    if (_sunnySpots.isNotEmpty || _sunnyPois.isNotEmpty) {
      _suppressResultClear = true;
      final rc = _detailReturnCenter;
      final rz = _detailReturnZoom;
      if (rc != null && rz != null) {
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(rc, rz));
      }
    }
  }

  Widget _buildSpotDetail() {
    final saved  = context.watch<SavedSpotsState>();
    final spot   = _shell.selectedSpot!;
    final idx    = _shell.selectedSpotIdx;
    final lat    = spot['lat'] as double;
    final lon    = spot['lon'] as double;
    final key    = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    final poiName = spot['_poi_name'] as String? ?? '';
    final address = poiName.isNotEmpty ? poiName : (saved.addresses[key] ?? 'Sunny spot ${idx + 1}');
    final sunHoursLeft  = (spot['sun_hours_left'] as int?) ?? 0;
    final sunUntil      = spot['sun_until'] as int?;
    final openingHours  = spot['_opening_hours'] as String? ?? '';
    final outdoorSeating = spot['_outdoor_seating'] as String? ?? '';
    final gps      = _gpsPosition;
    final distLabel = gps != null ? _formatDistance(_distanceMeters(gps, LatLng(lat, lon))) : null;
    final category  = spot['_category'] as String? ?? '';
    final poiAmenity = spot['_poi_amenity'] as String? ?? '';
    final (catIcon, catLabel) = category == 'park'
        ? (Icons.park, 'Park')
        : category == 'square'
            ? (Icons.location_city, 'Square')
            : poiAmenity.isNotEmpty
                ? (_poiIcon(poiAmenity), _poiLabel(poiAmenity))
                : (Icons.wb_sunny, 'Spot');
    final circColor = sunUntil != null ? const Color(0xFFFFD700) : Colors.grey.shade400;
    final isSaved   = saved.isSaved(lat, lon);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title + close row
        Row(children: [
          Container(width: 26, height: 26,
            decoration: BoxDecoration(color: circColor, shape: BoxShape.circle),
            child: Center(child: Text('${idx + 1}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white))),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(address,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          GestureDetector(
            onTap: _closeSpotDetail,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.close, size: 22, color: Colors.grey.shade500),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        // Subtitle
        Wrap(spacing: 8, children: [
          if (distLabel != null) Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.directions_walk, size: 12, color: Colors.grey.shade500),
            const SizedBox(width: 3),
            Text(distLabel, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(sunUntil != null ? Icons.wb_sunny_outlined : Icons.nights_stay_outlined,
                size: 12, color: sunUntil != null ? Colors.orange.shade400 : Colors.grey.shade400),
            const SizedBox(width: 3),
            Text(
              sunUntil != null
                  ? (sunHoursLeft == 0
                      ? '< 1h · until ${sunUntil.toString().padLeft(2, '0')}:00'
                      : '$sunHoursLeft h · until ${sunUntil.toString().padLeft(2, '0')}:00')
                  : 'In shadow',
              style: TextStyle(fontSize: 12,
                  color: sunUntil != null ? Colors.orange.shade700 : Colors.grey.shade500),
            ),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(catIcon, size: 12, color: Colors.grey.shade400),
            const SizedBox(width: 3),
            Text(catLabel, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ]),
        ]),
        // Opening hours
        if (openingHours.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.schedule, size: 12, color: Colors.grey.shade400),
            const SizedBox(width: 5),
            Expanded(child: Text(openingHours,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (outdoorSeating == 'yes') ...[
              const SizedBox(width: 8),
              Icon(Icons.deck, size: 12, color: Colors.grey.shade400),
              const SizedBox(width: 3),
              Text('Terrace', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ]),
        ] else if (outdoorSeating == 'yes') ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.deck, size: 12, color: Colors.grey.shade400),
            const SizedBox(width: 5),
            Text('Outdoor seating', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ]),
        ],
        const SizedBox(height: 16),
        // Action buttons
        Row(children: [
          _sheetButton(
            icon: Icons.directions_walk, label: 'Navigate',
            color: Colors.orange.shade700,
            onTap: () {
              html.window.open(
                'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon&travelmode=walking',
                '_blank');
            },
          ),
          const SizedBox(width: 8),
          _sheetButton(
            icon: isSaved ? Icons.favorite : Icons.favorite_outline,
            label: isSaved ? 'Saved' : 'Save',
            color: isSaved ? Colors.orange.shade800 : Colors.orange.shade600,
            onTap: () {
              if (isSaved) {
                _saved.removeWhere((s) => s['lat'] == lat && s['lon'] == lon);
              } else {
                _saved.add({'lat': lat, 'lon': lon, 'address': address,
                    'sun_hours_left': sunHoursLeft, 'sun_until': sunUntil});
              }
            },
          ),
          const SizedBox(width: 8),
          _sheetButton(
            icon: Icons.share, label: 'Share',
            color: Colors.orange.shade500,
            onTap: () async {
              final server = Uri.base.queryParameters['server'] ?? 'https://sunspotme.duckdns.org';
              final link = 'https://coruscating-fenglisu-505ed3.netlify.app/'
                  '?server=${Uri.encodeComponent(server)}&lat=$lat&lon=$lon';
              await Clipboard.setData(ClipboardData(text: link));
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied to clipboard'),
                    duration: Duration(seconds: 2)));
            },
          ),
        ]),
      ]),
    );
  }

  void _showPointSheet(LatLng coords) {
    final lat = coords.latitude;
    final lon = coords.longitude;
    final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

    // Start reverse geocoding in parallel
    _reverseGeocode(lat, lon).then((_) => _refreshPointSheet?.call());

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          _refreshPointSheet = () { if (ctx.mounted) setSheet(() {}); };

          final sheetSaved = ctx.watch<SavedSpotsState>();
          final info      = _pointInfo;
          final loading   = _pointInfoLoading;
          final inShadow  = info == null ? null : (info['in_shadow'] as bool? ?? true);
          final sunCount  = info?['sun_hours_count'] as int? ?? 0;
          final periods   = (info?['sun_periods'] as List<dynamic>?) ?? [];
          final address   = sheetSaved.addresses[key] ?? '';
          final isSaved   = sheetSaved.isSaved(lat, lon);
          final statusColor = inShadow == false ? const Color(0xFFFF8C00) : const Color(0xFF2d4862);

          String fmt(int h) => '${h.toString().padLeft(2, '0')}:00';

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar + close button
                Row(
                  children: [
                    const Spacer(),
                    Container(
                      width: 36, height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: () => Navigator.of(ctx).pop(),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(Icons.close, size: 22, color: Colors.grey.shade500),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Address
                Text(
                  address.isNotEmpty ? address : '${lat.toStringAsFixed(4)}°, ${lon.toStringAsFixed(4)}°',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),

                // Sun status
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))),
                  )
                else ...[
                  Row(children: [
                    Icon(
                      inShadow == false ? Icons.wb_sunny : Icons.nights_stay_outlined,
                      color: statusColor, size: 15,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      inShadow == false ? 'In Sun' : 'In Shadow',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: statusColor),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.wb_sunny_outlined, size: 13, color: Colors.grey.shade400),
                    const SizedBox(width: 4),
                    Text(
                      sunCount == 0 ? 'No direct sun today' : '$sunCount h of sun today',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ]),
                  if (periods.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6, runSpacing: 4,
                      children: periods.map((p) {
                        final from = p['from'] as int;
                        final to   = p['to']   as int;
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${fmt(from)} – ${fmt(to)}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600,
                                  fontWeight: FontWeight.w500)),
                        );
                      }).toList(),
                    ),
                  ],
                ],

                const SizedBox(height: 20),
                // Action buttons
                Row(children: [
                  _sheetButton(
                    icon: Icons.directions_walk,
                    label: 'Navigate',
                    color: Colors.orange.shade700,
                    onTap: () {
                      html.window.open(
                        'https://www.google.com/maps/dir/?api=1'
                        '&destination=$lat,$lon&travelmode=walking',
                        '_blank',
                      );
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(width: 10),
                  _sheetButton(
                    icon: isSaved ? Icons.favorite : Icons.favorite_outline,
                    label: isSaved ? 'Saved' : 'Save',
                    color: isSaved ? Colors.orange.shade800 : Colors.orange.shade600,
                    onTap: () {
                      if (isSaved) {
                        _saved.removeWhere((s) => s['lat'] == lat && s['lon'] == lon);
                      } else {
                        _saved.add({
                          'lat': lat, 'lon': lon,
                          'address': address.isNotEmpty ? address : '${lat.toStringAsFixed(4)}°N',
                          'sun_hours_left': sunCount,
                          'sun_until': periods.isNotEmpty ? (periods.last['to'] as int?) : null,
                        });
                      }
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(width: 10),
                  _sheetButton(
                    icon: Icons.share,
                    label: 'Share',
                    color: Colors.orange.shade500,
                    onTap: () async {
                      final server = Uri.base.queryParameters['server']
                          ?? 'https://sunspotme.duckdns.org';
                      final link = 'https://coruscating-fenglisu-505ed3.netlify.app/'
                          '?server=${Uri.encodeComponent(server)}&lat=$lat&lon=$lon';
                      await Clipboard.setData(ClipboardData(text: link));
                      Navigator.pop(ctx);
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied to clipboard'),
                            duration: Duration(seconds: 2)));
                    },
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    ).whenComplete(() {
      _refreshPointSheet = null;
      _hidePin();
      setState(() { _pointInfo = null; });
    });
  }

  Widget _sheetButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Geolocation
  // -------------------------------------------------------------------------

  Future<void> _initGpsOnStart() async {
    // Silently attempt GPS with a 5 s timeout; fall back to Vienna with no toast.
    LatLng? newPos;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.lowest),
        ).timeout(const Duration(seconds: 5));
        newPos = LatLng(pos.latitude, pos.longitude);
      }
    } catch (_) {
      // Silently fall back to default center (Vienna).
    }

    if (!mounted) return;

    if (newPos != null) {
      final pos = newPos;
      setState(() {
        _gpsPosition   = pos;
        _currentCenter = pos;
      });
      _fetchWeather(newPos.latitude, newPos.longitude);
      // Move camera instantly while splash still covers the map, so there is no
      // visible jump when the splash fades out.
      await _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: newPos, zoom: 15.0)),
      );
      await _showMyLocationDot(newPos);
    }

    // Reveal the map, then start fetching shadows for the correct center.
    if (mounted) _shell.hideSplash();
    fetchShadows();
  }

  void _onGpsButtonTap() {
    if (_gpsState == 0) {
      _enterState1();
    } else if (_gpsState == 1) {
      if (_isMobile) {
        _enterState2();
      } else {
        _enterState0();
      }
    } else {
      _enterState0();
    }
  }

  void _enterState0() {
    _positionStreamSub?.cancel();
    _positionStreamSub = null;
    _compassPollTimer?.cancel();
    _compassPollTimer = null;
    try { js.context.callMethod('eval', ['window.__sunspot_heading = null']); } catch (_) {}
    if (mounted) setState(() => _gpsState = 0);
  }

  Future<void> _resetToNorth() async {
    _enterState0();
    // Use _currentCenter as fallback so this never silently bails out because
    // cameraPosition is null (happens when onCameraIdle never fired, e.g. during
    // continuous compass-mode animations).
    final zoom = _mapController?.cameraPosition?.zoom ?? 15.0;
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _currentCenter, zoom: zoom, bearing: 0),
      ),
    );
  }

  Future<void> _enterState1() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _showError('GPS: permission denied');
        return;
      }
    }
    if (!mounted) return;
    setState(() => _gpsState = 1);

    // Initial fix — zoom in one step (same UX as before)
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));
      if (!mounted || _gpsState != 1) return;
      final latlng = LatLng(pos.latitude, pos.longitude);
      setState(() { _gpsPosition = latlng; _currentCenter = latlng; });
      final currentZoom = _mapController?.cameraPosition?.zoom ?? 0;
      final targetZoom  = currentZoom < 15 ? 15.0 : currentZoom < 16 ? 16.0 : 17.0;
      await _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: latlng, zoom: targetZoom)),
      );
      await _showMyLocationDot(latlng);
      fetchShadows();
    } on TimeoutException {
      _showError('GPS: location timed out');
      _enterState0();
      return;
    } catch (e) {
      _showError('GPS: ${e.toString().split('\n').first}');
      _enterState0();
      return;
    }

    // Continuous stream — updates dot and re-centers in State 1 only
    _positionStreamSub?.cancel();
    _positionStreamSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) async {
      if (!mounted || _gpsState < 1) return;
      final latlng = LatLng(pos.latitude, pos.longitude);
      setState(() { _gpsPosition = latlng; _currentCenter = latlng; });
      await _showMyLocationDot(latlng);
      if (_gpsState == 1) {
        final zoom = _mapController?.cameraPosition?.zoom ?? 15.0;
        await _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(target: latlng, zoom: zoom)),
        );
      }
    });
  }

  Future<void> _enterState2() async {
    if (!_isMobile) return;
    setState(() => _gpsState = 2);

    // Start device orientation listener (requests iOS permission from within user gesture).
    try {
      js.context.callMethod('eval', [r'''
        (function() {
          window.__sunspot_heading = null;
          function startDO() {
            window.addEventListener('deviceorientationabsolute', function(e) {
              if (e.alpha !== null && e.alpha !== undefined)
                window.__sunspot_heading = (360 - e.alpha) % 360;
            }, true);
            window.addEventListener('deviceorientation', function(e) {
              if (e.webkitCompassHeading !== undefined && e.webkitCompassHeading !== null)
                window.__sunspot_heading = e.webkitCompassHeading;
              else if ((window.__sunspot_heading === null) && e.alpha !== null && e.alpha !== undefined)
                window.__sunspot_heading = (360 - e.alpha) % 360;
            }, true);
          }
          if (typeof DeviceOrientationEvent !== 'undefined' &&
              typeof DeviceOrientationEvent.requestPermission === 'function') {
            DeviceOrientationEvent.requestPermission()
              .then(function(p) { if (p === 'granted') startDO(); })
              .catch(function() { startDO(); });
          } else {
            startDO();
          }
        })();
      ''']);
    } catch (_) {}

    _compassPollTimer?.cancel();
    _compassPollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (!mounted || _gpsState != 2) return;
      final gps = _gpsPosition;
      if (gps == null) return;
      try {
        final raw = js.context.callMethod('eval', ['window.__sunspot_heading']);
        if (raw == null) return;
        final heading = (raw as num).toDouble();
        if ((heading - _lastHeading).abs() < 2.0) return;
        _lastHeading = heading;
        final zoom = _mapController?.cameraPosition?.zoom ?? 15.0;
        await _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: gps, zoom: zoom, bearing: heading),
          ),
        );
      } catch (_) {}
    });
  }

  Future<void> _showMyLocationDot(LatLng pos) async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final geoJson = {
      'type': 'FeatureCollection',
      'features': [{
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [pos.longitude, pos.latitude]},
        'properties': {},
      }],
    };
    if (_myLocationLayerReady) {
      await ctrl.setGeoJsonSource('my-location', geoJson);
    } else {
      await ctrl.addSource('my-location', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer(
        'my-location', 'my-location-pulse',
        CircleLayerProperties(
          circleRadius: 16,
          circleColor: '#2979FF',
          circleOpacity: 0.20,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'my-location', 'my-location-dot',
        CircleLayerProperties(
          circleRadius: 7,
          circleColor: '#2979FF',
          circleOpacity: 1.0,
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#FFFFFF',
          circleStrokeOpacity: 1.0,
        ),
        enableInteraction: false,
      );
      _myLocationLayerReady = true;
    }
  }

  // -------------------------------------------------------------------------
  // Error display
  // -------------------------------------------------------------------------

  // Disable/enable pointer events on the MapLibre canvas via DOM so slider
  // drags don't also pan the map (AbsorbPointer doesn't reach platform views).
  void _setMapPointerEvents(bool enabled) {
    final els = html.document.querySelectorAll('.maplibregl-canvas-container');
    for (final el in els) {
      el.style.pointerEvents = enabled ? 'auto' : 'none';
    }
  }

  void _showError(String msg) => _shell.showError(msg);

  // -------------------------------------------------------------------------
  // Shadow fetch
  // -------------------------------------------------------------------------

  Future<void> fetchShadows() async {
    if (!_mapReady || _mapController == null) return;

    _pillTimer?.cancel();
    // Complete previous completer so any awaiting caller (animation) unblocks
    if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
      _fetchCompleter!.complete();
    }
    final completer = Completer<void>();
    _fetchCompleter = completer;
    final gen = ++_fetchGen;

    setState(() {
      _loading         = true;
      _loadingProgress = 0.0;
      _loadingStage    = '';
      _showPill        = false;
    });
    // Block map pan/zoom while loading so the server isn't hammered by stacked requests.
    if (!_animating) _setMapPointerEvents(false);

    // Show pill after 50 ms if still loading (not during animation or 24h preload).
    // 50 ms is short enough to catch even fast macro-zoom cached loads.
    if (!_animating && !_preloading24h) {
      _pillTimer = Timer(const Duration(milliseconds: 50), () {
        if (mounted && _fetchGen == gen) setState(() => _showPill = true);
      });
    }

    try {
      final rawZoom = _mapController!.cameraPosition?.zoom ?? 15.0;

      // Below zoom 12: skip tile fetch — zoom interpolation fades shadows naturally.
      if (rawZoom < 12.0) {
        if (mounted) setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
        _setMapPointerEvents(true);
        if (!completer.isCompleted) completer.complete();
        return;
      }

      _lastFetchZoom = rawZoom.toInt();

      // Fetch sun angles + sunrise/sunset from lightweight meta endpoint.
      // Retry with backoff while server is cold-starting (typically 5–60 s after restart).
      Map<String, dynamic>? meta;
      const maxRetries = 12;
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          meta = await _api.fetchShadowMeta(
            _currentCenter.latitude, _currentCenter.longitude,
            _hour.toInt(), ((_hour * 60).toInt() % 60),
            _selectedDate.month, _selectedDate.day,
          );
          break;
        } catch (_) {
          if (gen != _fetchGen) { if (!completer.isCompleted) completer.complete(); return; }
          if (attempt >= maxRetries) rethrow;
          final delaySec = attempt < 3 ? 3 : attempt < 6 ? 5 : 8;
          final retryProg = ((attempt + 1) / maxRetries * 0.3).clamp(0.0, 0.3);
          if (mounted) setState(() {
            _loadingStage    = 'Connecting… (${attempt + 1}/$maxRetries)';
            _loadingProgress = retryProg;
          });
          await Future.delayed(Duration(seconds: delaySec));
          if (gen != _fetchGen) { if (!completer.isCompleted) completer.complete(); return; }
        }
      }
      if (gen != _fetchGen) { if (!completer.isCompleted) completer.complete(); return; }
      if (meta == null) throw Exception('shadow/meta returned null after retries');

      final metaData = meta;
      final elev   = (metaData['elevation'] as num?)?.toDouble() ?? 0.0;
      final srHour = (metaData['sunrise']   as num?)?.toDouble();
      final ssHour = (metaData['sunset']    as num?)?.toDouble();

      // Wire up (or refresh) the vector tile source for this time step.
      final tileUrl = _buildShadowTileUrl(
        _hour.toInt(), ((_hour * 60).toInt() % 60), _selectedDate.month, _selectedDate.day,
      );
      final nonceBefore = _shadowSourceNonce;
      await _ensureShadowTileSource(tileUrl, elev);
      final sourceRebuilt = _shadowSourceNonce != nonceBefore;
      if (gen != _fetchGen) { if (!completer.isCompleted) completer.complete(); return; }

      if (mounted) {
        setState(() {
          _sunriseHour = srHour;
          _sunsetHour  = ssHour;
          if (srHour != null && ssHour != null) {
            _hour = _hour.clamp(srHour, ssHour);
          }
          _loadingStage    = '';
        });
      }
      if (!completer.isCompleted) completer.complete();

      // Wait for MapLibre's 'idle' event — fires exactly when all tiles are rendered.
      // Skip during animation (tiles come from warm cache, animation manages its own state).
      if (!_animating) {
        const maxIter = 300; // 30 s hard ceiling
        for (var i = 0; i < maxIter && gen == _fetchGen && mounted; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!mounted || gen != _fetchGen) break;
          final fetchProg = _tileProgress();
          // When tiles are served from MapLibre's in-memory cache, fetch() is never
          // called so fetchProg stays 0. Use a time-based easing curve as fallback so
          // the bar visually advances; cap at 0.92 so idle completion always "finishes" it.
          final fakeProgress = (1.0 - pow(0.94, i + 1)).clamp(0.0, 0.92);
          setState(() => _loadingProgress = fetchProg > 0 ? fetchProg : fakeProgress);
          if (_isIdle()) break;
          // After 5 s with no idle signal, label changes to "Rendering…"
          if (i == 49 && mounted) setState(() => _loadingStage = 'Rendering…');
        }
        _stopIdleWait();
        // Snap to 100% so user sees completion before pill fades out.
        if (gen == _fetchGen && mounted) setState(() => _loadingProgress = 1.0);
        // New tiles are rendered — remove ghost layers from previous time step while
        // freeze overlay is still up, so there's no visible flash when it fades out.
        if (gen == _fetchGen && _prevNonce >= 0) {
          final old = _prevNonce;
          _prevNonce = -1;
          final mc = _mapController;
          if (mc != null) {
            for (final id in _shadowGhostLayerIds(old)) {
              try { await mc.removeLayer(id); } catch (_) {}
            }
            try { await mc.removeSource('shadow-macro-$old'); } catch (_) {}
            try { await mc.removeSource('shadow-micro-$old'); } catch (_) {}
          }
        }
        if (gen == _fetchGen && mounted && sourceRebuilt) {
          await _fadeShadowLayersIn(_shadowSourceNonce, elev);
        }
        await Future.delayed(const Duration(milliseconds: 180));
      }
      if (gen == _fetchGen && mounted) {
        setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; _loadingStage = ''; });
        _setMapPointerEvents(true);
      }

    } catch (e) {
      debugPrint('Fetch error: $e');
      _pillTimer?.cancel();
      if (_shadowLayersReady) {
        // Already have tiles on screen — silently keep them; don't flash an error.
      } else {
        _showError('Could not load shadows — is the server running?');
      }
      if (mounted) setState(() { _loading = false; _loadingProgress = 0.0; _showPill = false; });
      _setMapPointerEvents(true);
      if (!completer.isCompleted) completer.complete();
    }
  }

  // Build the tile URL template for the current time. MapLibre substitutes {z}/{x}/{y}.
  String _buildShadowTileUrl(int hour, int minute, int month, int day) =>
      '$flaskBaseUrl/shadow/tile/{z}/{x}/{y}.pbf'
      '?hour=$hour&minute=$minute&month=$month&day=$day';

  // Create or refresh two vector tile sources + 12 shadow layers for smooth z14→z15 cross-fade.
  //
  // Macro source (maxzoom:14): serves z12-z14 macro tiles; overzooms past z14 while fading out.
  // Micro source (maxzoom:17): serves z14 tiles at z14, switches to per-building z15 tiles at z15.
  //
  // Complementary opacity expressions keep the combined opacity constant across z14→z15:
  //   macro fades out: z12→op*0.50, z14→op*0.78, z15→0
  //   micro fades in:  z14→0,       z15→op*0.78,  z16→op
  //
  // When only elevation changes (same URL), only layer opacities are updated — no source teardown.
  // When the time changes (new URL), existing layers are dimmed then rebuilt.
  Future<void> _ensureShadowTileSource(String tileUrl, double elevation) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final t    = elevation <= 0 ? 1.0 : (elevation.clamp(0.0, 60.0) / 60.0);
    final opL0 = elevation <= 0 ? 0.82 : 0.40 + t * 0.10;
    final opL1 = elevation <= 0 ? 0.0  : 0.28 + t * 0.15;
    final opL2 = elevation <= 0 ? 0.0  : 0.30 + t * 0.18;

    // Macro: full ramp z10→z14, then fades out to 0 by z15.
    List<dynamic> macroOp(double op) =>
        ['interpolate', ['exponential', 1.4], ['zoom'], 10, 0.0, 12, op * 0.50, 14, op * 0.78, 15, 0.0];
    List<dynamic> macroLineOp(double op) => macroOp(op * 0.6);

    // Micro: invisible below z14, fades in to op*0.78 at z15, reaches full at z16.
    List<dynamic> microOp(double op) =>
        ['interpolate', ['exponential', 1.4], ['zoom'], 10, 0.0, 14, 0.0, 15, op * 0.78, 16, op];
    List<dynamic> microLineOp(double op) => microOp(op * 0.6);

    if (_shadowLayersReady && tileUrl == _currentTileUrl) {
      // URL unchanged (same time) — only update opacities, no source teardown.
      // This path fires on every zoom change; MapLibre's zoom expressions handle the cross-fade.
      // Arm idle wait: MapLibre may already be fetching new-zoom tiles autonomously.
      _startIdleWait();
      _resetTileProgress();
      final n = _shadowSourceNonce;
      try {
        await Future.wait([
          ctrl.setLayerProperties('shadow-macro-l0-fill-$n', FillLayerProperties(fillColor: '#455A64', fillAntialias: true, fillOpacity: macroOp(opL0))),
          ctrl.setLayerProperties('shadow-macro-l1-fill-$n', FillLayerProperties(fillColor: '#37474F', fillAntialias: true, fillOpacity: macroOp(opL1))),
          ctrl.setLayerProperties('shadow-macro-l2-fill-$n', FillLayerProperties(fillColor: '#263238', fillAntialias: true, fillOpacity: macroOp(opL2))),
          ctrl.setLayerProperties('shadow-macro-l0-line-$n', LineLayerProperties(lineColor: '#455A64', lineOpacity: macroLineOp(opL0))),
          ctrl.setLayerProperties('shadow-macro-l1-line-$n', LineLayerProperties(lineColor: '#37474F', lineOpacity: macroLineOp(opL1))),
          ctrl.setLayerProperties('shadow-macro-l2-line-$n', LineLayerProperties(lineColor: '#263238', lineOpacity: macroLineOp(opL2))),
          ctrl.setLayerProperties('shadow-micro-l0-fill-$n', FillLayerProperties(fillColor: '#455A64', fillAntialias: true, fillOpacity: microOp(opL0))),
          ctrl.setLayerProperties('shadow-micro-l1-fill-$n', FillLayerProperties(fillColor: '#37474F', fillAntialias: true, fillOpacity: microOp(opL1))),
          ctrl.setLayerProperties('shadow-micro-l2-fill-$n', FillLayerProperties(fillColor: '#263238', fillAntialias: true, fillOpacity: microOp(opL2))),
          ctrl.setLayerProperties('shadow-micro-l0-line-$n', LineLayerProperties(lineColor: '#455A64', lineOpacity: microLineOp(opL0))),
          ctrl.setLayerProperties('shadow-micro-l1-line-$n', LineLayerProperties(lineColor: '#37474F', lineOpacity: microLineOp(opL1))),
          ctrl.setLayerProperties('shadow-micro-l2-line-$n', LineLayerProperties(lineColor: '#263238', lineOpacity: microLineOp(opL2))),
        ]);
        return;
      } catch (_) {
        _shadowLayersReady = false;
      }
    }

    // Time changed (new URL) — keep existing layers as ghost while new tiles load.
    // Animation: ghost stays at full opacity (tiles load from preload cache in ~50ms, _run24hStep cleans up).
    // Manual swap: ghost is dimmed so it doesn't mislead while new tiles may take seconds to arrive.
    if (_shadowLayersReady) {
      final mc = ctrl;
      // If a previous ghost is still pending cleanup from a timed-out animation step:
      // during animation, dim it to invisible and park in _dimmedGhostNonce so _run24hStep()
      // can clean it up after the next idle event. Outside animation, remove it immediately.
      if (_prevNonce >= 0) {
        final old = _prevNonce;
        _prevNonce = -1;
        if (_animating) {
          _dimmedGhostNonce = old;
          try {
            ctrl.setLayerProperties('shadow-macro-l0-fill-$old', FillLayerProperties(fillOpacity: 0.0));
            ctrl.setLayerProperties('shadow-macro-l1-fill-$old', FillLayerProperties(fillOpacity: 0.0));
            ctrl.setLayerProperties('shadow-macro-l2-fill-$old', FillLayerProperties(fillOpacity: 0.0));
            ctrl.setLayerProperties('shadow-macro-l0-line-$old', LineLayerProperties(lineOpacity: 0.0));
            ctrl.setLayerProperties('shadow-macro-l1-line-$old', LineLayerProperties(lineOpacity: 0.0));
            ctrl.setLayerProperties('shadow-macro-l2-line-$old', LineLayerProperties(lineOpacity: 0.0));
            ctrl.setLayerProperties('shadow-micro-l0-fill-$old', FillLayerProperties(fillOpacity: 0.0));
            ctrl.setLayerProperties('shadow-micro-l1-fill-$old', FillLayerProperties(fillOpacity: 0.0));
            ctrl.setLayerProperties('shadow-micro-l2-fill-$old', FillLayerProperties(fillOpacity: 0.0));
            ctrl.setLayerProperties('shadow-micro-l0-line-$old', LineLayerProperties(lineOpacity: 0.0));
            ctrl.setLayerProperties('shadow-micro-l1-line-$old', LineLayerProperties(lineOpacity: 0.0));
            ctrl.setLayerProperties('shadow-micro-l2-line-$old', LineLayerProperties(lineOpacity: 0.0));
          } catch (_) {}
        } else {
          for (final id in _shadowGhostLayerIds(old)) {
            try { await ctrl.removeLayer(id); } catch (_) {}
          }
          try { await ctrl.removeSource('shadow-macro-$old'); } catch (_) {}
          try { await ctrl.removeSource('shadow-micro-$old'); } catch (_) {}
        }
      }
      _prevNonce = _shadowSourceNonce;
      final g = _prevNonce;
      if (!_animating) {
        // Dim ghost layers for manual tile swap — they should not dominate while new tiles load.
        try {
          mc.setLayerProperties('shadow-macro-l0-fill-$g', FillLayerProperties(fillColor: '#455A64', fillOpacity: 0.15));
          mc.setLayerProperties('shadow-macro-l1-fill-$g', FillLayerProperties(fillColor: '#37474F', fillOpacity: 0.10));
          mc.setLayerProperties('shadow-macro-l2-fill-$g', FillLayerProperties(fillColor: '#263238', fillOpacity: 0.08));
          mc.setLayerProperties('shadow-macro-l0-line-$g', LineLayerProperties(lineColor: '#455A64', lineOpacity: 0.09));
          mc.setLayerProperties('shadow-macro-l1-line-$g', LineLayerProperties(lineColor: '#37474F', lineOpacity: 0.06));
          mc.setLayerProperties('shadow-macro-l2-line-$g', LineLayerProperties(lineColor: '#263238', lineOpacity: 0.05));
          mc.setLayerProperties('shadow-micro-l0-fill-$g', FillLayerProperties(fillColor: '#455A64', fillOpacity: 0.12));
          mc.setLayerProperties('shadow-micro-l1-fill-$g', FillLayerProperties(fillColor: '#37474F', fillOpacity: 0.08));
          mc.setLayerProperties('shadow-micro-l2-fill-$g', FillLayerProperties(fillColor: '#263238', fillOpacity: 0.06));
          mc.setLayerProperties('shadow-micro-l0-line-$g', LineLayerProperties(lineColor: '#455A64', lineOpacity: 0.07));
          mc.setLayerProperties('shadow-micro-l1-line-$g', LineLayerProperties(lineColor: '#37474F', lineOpacity: 0.05));
          mc.setLayerProperties('shadow-micro-l2-line-$g', LineLayerProperties(lineColor: '#263238', lineOpacity: 0.04));
        } catch (_) {}
      }
      // Ghost layers stay on the map — do NOT removeLayer/removeSource here.
      _shadowLayersReady = false;
    }

    _currentTileUrl = tileUrl;
    _shadowSourceNonce++;
    final macroSrc = 'shadow-macro-$_shadowSourceNonce';
    final microSrc = 'shadow-micro-$_shadowSourceNonce';
    // Cache-buster: ensures MapLibre never serves stale tiles from a prior source's request.
    // Both sources share the same fetchUrl; nonce differs per rebuild so URLs are unique.
    final fetchUrl = '$tileUrl&_n=$_shadowSourceNonce';

    // Arm idle wait + reset fetch counter BEFORE addSource triggers tile fetches.
    _startIdleWait();
    _resetTileProgress();

    // Macro source: capped at z14 — uses z14 macro tiles and overzooms them past z14.
    await ctrl.addSource(macroSrc, VectorSourceProperties(tiles: [fetchUrl], minzoom: 0, maxzoom: 14));
    // Micro source: full range — switches to z15 per-building tiles when camera crosses z15.
    await ctrl.addSource(microSrc, VectorSourceProperties(tiles: [fetchUrl], minzoom: 0, maxzoom: 17));

    final n = _shadowSourceNonce;

    // Macro layers: start at 0 opacity so we can fade them in after tiles arrive (non-animation path).
    // During animation tiles come from warm cache immediately, so we use full opacity to avoid blank frames.
    final initMacroL0 = _animating ? macroOp(opL0) : 0.0;
    final initMacroL1 = _animating ? macroOp(opL1) : 0.0;
    final initMacroL2 = _animating ? macroOp(opL2) : 0.0;
    final initMacroLineL0 = _animating ? macroLineOp(opL0) : 0.0;
    final initMacroLineL1 = _animating ? macroLineOp(opL1) : 0.0;
    final initMacroLineL2 = _animating ? macroLineOp(opL2) : 0.0;
    final initMicroL0 = _animating ? microOp(opL0) : 0.0;
    final initMicroL1 = _animating ? microOp(opL1) : 0.0;
    final initMicroL2 = _animating ? microOp(opL2) : 0.0;
    final initMicroLineL0 = _animating ? microLineOp(opL0) : 0.0;
    final initMicroLineL1 = _animating ? microLineOp(opL1) : 0.0;
    final initMicroLineL2 = _animating ? microLineOp(opL2) : 0.0;

    await ctrl.addLayer(macroSrc, 'shadow-macro-l0-fill-$n',
      FillLayerProperties(fillColor: '#455A64', fillAntialias: true, fillOpacity: initMacroL0),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l0'], enableInteraction: false,
    );
    await ctrl.addLayer(macroSrc, 'shadow-macro-l0-line-$n',
      LineLayerProperties(lineColor: '#455A64', lineWidth: 1.2, lineOpacity: initMacroLineL0),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l0'], enableInteraction: false,
    );
    await ctrl.addLayer(macroSrc, 'shadow-macro-l1-fill-$n',
      FillLayerProperties(fillColor: '#37474F', fillAntialias: true, fillOpacity: initMacroL1),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l1'], enableInteraction: false,
    );
    await ctrl.addLayer(macroSrc, 'shadow-macro-l1-line-$n',
      LineLayerProperties(lineColor: '#37474F', lineWidth: 1.2, lineOpacity: initMacroLineL1),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l1'], enableInteraction: false,
    );
    await ctrl.addLayer(macroSrc, 'shadow-macro-l2-fill-$n',
      FillLayerProperties(fillColor: '#263238', fillAntialias: true, fillOpacity: initMacroL2),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l2'], enableInteraction: false,
    );
    await ctrl.addLayer(macroSrc, 'shadow-macro-l2-line-$n',
      LineLayerProperties(lineColor: '#263238', lineWidth: 1.2, lineOpacity: initMacroLineL2),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l2'], enableInteraction: false,
    );

    // Micro layers: invisible at z14, fade in to per-building detail at z15+.
    await ctrl.addLayer(microSrc, 'shadow-micro-l0-fill-$n',
      FillLayerProperties(fillColor: '#455A64', fillAntialias: true, fillOpacity: initMicroL0),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l0'], enableInteraction: false,
    );
    await ctrl.addLayer(microSrc, 'shadow-micro-l0-line-$n',
      LineLayerProperties(lineColor: '#455A64', lineWidth: 1.2, lineOpacity: initMicroLineL0),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l0'], enableInteraction: false,
    );
    await ctrl.addLayer(microSrc, 'shadow-micro-l1-fill-$n',
      FillLayerProperties(fillColor: '#37474F', fillAntialias: true, fillOpacity: initMicroL1),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l1'], enableInteraction: false,
    );
    await ctrl.addLayer(microSrc, 'shadow-micro-l1-line-$n',
      LineLayerProperties(lineColor: '#37474F', lineWidth: 1.2, lineOpacity: initMicroLineL1),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l1'], enableInteraction: false,
    );
    await ctrl.addLayer(microSrc, 'shadow-micro-l2-fill-$n',
      FillLayerProperties(fillColor: '#263238', fillAntialias: true, fillOpacity: initMicroL2),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l2'], enableInteraction: false,
    );
    await ctrl.addLayer(microSrc, 'shadow-micro-l2-line-$n',
      LineLayerProperties(lineColor: '#263238', lineWidth: 1.2, lineOpacity: initMicroLineL2),
      sourceLayer: 'shadows', filter: ['==', ['get', 'layer'], 'shadow-l2'], enableInteraction: false,
    );
    _shadowLayersReady = true;
  }

  List<String> _shadowGhostLayerIds(int nonce) => [
    'shadow-macro-l0-fill-$nonce', 'shadow-macro-l0-line-$nonce',
    'shadow-macro-l1-fill-$nonce', 'shadow-macro-l1-line-$nonce',
    'shadow-macro-l2-fill-$nonce', 'shadow-macro-l2-line-$nonce',
    'shadow-micro-l0-fill-$nonce', 'shadow-micro-l0-line-$nonce',
    'shadow-micro-l1-fill-$nonce', 'shadow-micro-l1-line-$nonce',
    'shadow-micro-l2-fill-$nonce', 'shadow-micro-l2-line-$nonce',
  ];

  // Ramps shadow layers from 0 → full opacity over 4 × 100 ms steps after tiles are rendered.
  Future<void> _fadeShadowLayersIn(int nonce, double elevation) async {
    final t    = elevation <= 0 ? 1.0 : (elevation.clamp(0.0, 60.0) / 60.0);
    final opL0 = elevation <= 0 ? 0.82 : 0.40 + t * 0.10;
    final opL1 = elevation <= 0 ? 0.0  : 0.28 + t * 0.15;
    final opL2 = elevation <= 0 ? 0.0  : 0.30 + t * 0.18;

    List<dynamic> mo(double op, double s)  => ['interpolate', ['exponential', 1.4], ['zoom'], 10, 0.0, 12, op * 0.50 * s, 14, op * 0.78 * s, 15, 0.0];
    List<dynamic> mlo(double op, double s) => mo(op * 0.6, s);
    List<dynamic> ui(double op, double s)  => ['interpolate', ['exponential', 1.4], ['zoom'], 10, 0.0, 14, 0.0, 15, op * 0.78 * s, 16, op * s];
    List<dynamic> ulo(double op, double s) => ui(op * 0.6, s);

    const steps = 4;
    final n = nonce;
    for (int step = 1; step <= steps; step++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final mc = _mapController;
      if (mc == null || _shadowSourceNonce != n || !mounted) return;
      final s = step / steps;
      try {
        await Future.wait([
          mc.setLayerProperties('shadow-macro-l0-fill-$n', FillLayerProperties(fillColor: '#455A64', fillAntialias: true, fillOpacity: mo(opL0, s))),
          mc.setLayerProperties('shadow-macro-l1-fill-$n', FillLayerProperties(fillColor: '#37474F', fillAntialias: true, fillOpacity: mo(opL1, s))),
          mc.setLayerProperties('shadow-macro-l2-fill-$n', FillLayerProperties(fillColor: '#263238', fillAntialias: true, fillOpacity: mo(opL2, s))),
          mc.setLayerProperties('shadow-macro-l0-line-$n', LineLayerProperties(lineColor: '#455A64', lineOpacity: mlo(opL0, s))),
          mc.setLayerProperties('shadow-macro-l1-line-$n', LineLayerProperties(lineColor: '#37474F', lineOpacity: mlo(opL1, s))),
          mc.setLayerProperties('shadow-macro-l2-line-$n', LineLayerProperties(lineColor: '#263238', lineOpacity: mlo(opL2, s))),
          mc.setLayerProperties('shadow-micro-l0-fill-$n', FillLayerProperties(fillColor: '#455A64', fillAntialias: true, fillOpacity: ui(opL0, s))),
          mc.setLayerProperties('shadow-micro-l1-fill-$n', FillLayerProperties(fillColor: '#37474F', fillAntialias: true, fillOpacity: ui(opL1, s))),
          mc.setLayerProperties('shadow-micro-l2-fill-$n', FillLayerProperties(fillColor: '#263238', fillAntialias: true, fillOpacity: ui(opL2, s))),
          mc.setLayerProperties('shadow-micro-l0-line-$n', LineLayerProperties(lineColor: '#455A64', lineOpacity: ulo(opL0, s))),
          mc.setLayerProperties('shadow-micro-l1-line-$n', LineLayerProperties(lineColor: '#37474F', lineOpacity: ulo(opL1, s))),
          mc.setLayerProperties('shadow-micro-l2-line-$n', LineLayerProperties(lineColor: '#263238', lineOpacity: ulo(opL2, s))),
        ]);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Animation
  // -------------------------------------------------------------------------

  void _toggle24h() {
    if (_preloading24h) {
      _preloadGen++; // cancel in-flight preload callbacks
      setState(() { _preloading24h = false; _showPill = false; _loadingProgress = 0; _loadingStage = ''; });
      return;
    }
    if (_animating) {
      setState(() => _animating = false);
      return;
    }
    final start = _sunriseHour ?? 6.0;
    _preloadGen++; // new run — stale callbacks from any previous preload self-abort
    setState(() { _preloading24h = true; _liveMode = false; _hour = start; _showPill = true; _loadingStage = 'Warming'; _loadingProgress = 0; });
    _preload24h().then((_) {
      if (!mounted || !_preloading24h) return;
      setState(() { _preloading24h = false; _animating = true; _showPill = false; _loadingProgress = 0; _loadingStage = ''; });
      _run24hStep();
    });
  }

  // Warm the server tile cache for every daylight hour — 3×3 tile grid, all hours in parallel.
  // 144 simultaneous requests let the server compute all sun angles at once.
  // Gen counter (_preloadGen) lets stale callbacks self-abort when a new run starts.
  // Only HTTP 200 counts as success; failed tiles are retried up to 2 extra times.
  Future<void> _preload24h() async {
    if (!_mapReady || _mapController == null) return;
    final gen    = _preloadGen; // snapshot — if _preloadGen advances, we've been cancelled
    final zoom   = (_mapController!.cameraPosition?.zoom ?? 14).toInt().clamp(10, 17);
    final startH = (_sunriseHour ?? 6.0).toInt();
    final endH   = (_sunsetHour  ?? 21.0).toInt();
    final total  = endH - startH + 1;
    final tileX  = _lonToTileX(_currentCenter.longitude, zoom);
    final tileY  = _latToTileY(_currentCenter.latitude, zoom);

    final specs = <(int, int, int)>[
      for (int h = startH; h <= endH; h++)
        for (var dx = -1; dx <= 1; dx++)
          for (var dy = -1; dy <= 1; dy++)
            (h, tileX + dx, tileY + dy),
    ];
    final totalTiles = specs.length;
    int progressCount = 0;

    String tileUrl(int h, int x, int y) =>
        '$flaskBaseUrl/shadow/tile/$zoom/$x/$y.pbf'
        '?hour=$h&minute=0&month=${_selectedDate.month}&day=${_selectedDate.day}';

    // First pass: all tiles in parallel; track which fail.
    final okFlags = List<bool>.filled(totalTiles, false);
    await Future.wait([
      for (var i = 0; i < specs.length; i++)
        () async {
          final (h, x, y) = specs[i];
          final ok = await _api.fetchTile(tileUrl(h, x, y));
          if (_preloadGen != gen) return;
          okFlags[i] = ok;
          if (mounted && _preloading24h) {
            progressCount++;
            setState(() {
              _loadingProgress = progressCount / totalTiles;
              _loadingStage    = 'Warming ${(progressCount / 9).ceil()}/$total hours';
            });
          }
        }(),
    ]);
    if (_preloadGen != gen || !mounted || !_preloading24h) return;

    // Retry failed tiles — up to 2 extra passes, silent (no progress bar update).
    var failed = [for (var i = 0; i < specs.length; i++) if (!okFlags[i]) specs[i]];
    for (var pass = 0; pass < 2 && failed.isNotEmpty; pass++) {
      if (_preloadGen != gen) return;
      final results = await Future.wait(failed.map((s) => _api.fetchTile(tileUrl(s.$1, s.$2, s.$3))));
      if (_preloadGen != gen || !mounted || !_preloading24h) return;
      failed = [for (var i = 0; i < failed.length; i++) if (!results[i]) failed[i]];
    }
  }

  // Fire-and-forget: warm the server cache for a single hour's 3×3 tile grid.
  // Called during the animation hold period so the next step's tiles are hot
  // before MapLibre requests them. No await — runs concurrently with the hold delay.
  void _warmHourTiles(int hour) {
    if (!_mapReady || _mapController == null) return;
    final zoom  = (_mapController!.cameraPosition?.zoom ?? 14).toInt().clamp(10, 17);
    final tileX = _lonToTileX(_currentCenter.longitude, zoom);
    final tileY = _latToTileY(_currentCenter.latitude, zoom);
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        _api.warmTile(
          '$flaskBaseUrl/shadow/tile/$zoom/${tileX + dx}/${tileY + dy}.pbf'
          '?hour=$hour&minute=0&month=${_selectedDate.month}&day=${_selectedDate.day}',
        );
      }
    }
  }

  int _lonToTileX(double lon, int z) => ((lon + 180.0) / 360.0 * (1 << z)).floor();
  int _latToTileY(double lat, int z) {
    final latRad = lat * pi / 180.0;
    return ((1.0 - (log(tan(latRad) + 1.0 / cos(latRad)) / pi)) / 2.0 * (1 << z)).floor();
  }

  Future<void> _run24hStep() async {
    while (_animating) {
      await fetchShadows();
      if (!_animating) break;

      // Wait for MapLibre idle — fires only after all tiles are fully painted to canvas.
      // Hard ceiling: 5 s (100 × 50 ms). Track whether idle actually fired or we timed out.
      for (var i = 0; i < 100 && _animating && !_isIdle(); i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (!_animating) break;
      final idleFired = _isIdle();
      _stopIdleWait();

      // 80 ms GPU buffer — compositing pipeline has a few ms lag after idle event.
      if (idleFired) await Future.delayed(const Duration(milliseconds: 80));
      if (!_animating) break;

      // Only remove ghosts when tiles are confirmed fully rendered.
      // Cleans up both _prevNonce (current ghost) and _dimmedGhostNonce (any 0-opacity
      // ghost parked by _ensureShadowTileSource during a previous timed-out step).
      if (idleFired && (_prevNonce >= 0 || _dimmedGhostNonce >= 0)) {
        final mc = _mapController;
        if (mc != null) {
          for (final nonce in [_prevNonce, _dimmedGhostNonce]) {
            if (nonce < 0) continue;
            for (final id in _shadowGhostLayerIds(nonce)) {
              try { await mc.removeLayer(id); } catch (_) {}
            }
            try { await mc.removeSource('shadow-macro-$nonce'); } catch (_) {}
            try { await mc.removeSource('shadow-micro-$nonce'); } catch (_) {}
          }
        }
        _prevNonce = -1;
        _dimmedGhostNonce = -1;
      }

      final end = _sunsetHour ?? 20.0;
      if (_hour >= end) {
        setState(() => _animating = false);
        break;
      }

      // During the hold, pre-warm the next hour's 3×3 tiles on the server.
      // Runs concurrently with the delay so tiles are hot before MapLibre requests them.
      _warmHourTiles((_hour + 1.0).toInt());

      // Fixed hold — each shadow is shown for 500 ms after it finishes rendering.
      await Future.delayed(const Duration(milliseconds: 500));
      if (!_animating) break;
      setState(() => _hour = _hour + 1.0);
    }
  }

  // -------------------------------------------------------------------------
  // Date picker
  // -------------------------------------------------------------------------

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      fetchShadows();
    }
  }

  // -------------------------------------------------------------------------
  // Live mode
  // -------------------------------------------------------------------------

  void _toggleLiveMode() {
    if (_liveMode) {
      _liveTimer?.cancel();
      setState(() => _liveMode = false);
    } else {
      setState(() {
        _liveMode = true;
        _animating = false;  // stop animation when going live
        final now = viennaNow();
        _selectedDate = DateTime(now.year, now.month, now.day);
        _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
      });
      fetchShadows();
      _liveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted || !_liveMode) return;
        setState(() {
          final now = viennaNow();
          _selectedDate = DateTime(now.year, now.month, now.day);
          _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
        });
        fetchShadows();
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _pillTimer?.cancel();
    _sliderDebounce?.cancel();
    _liveTimer?.cancel();
    _positionStreamSub?.cancel();
    _compassPollTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _panelScroll.dispose();
    _mobileContentScroll.dispose();
    _sunSpinCtrl.dispose();
    if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
      _fetchCompleter!.complete();
    }
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Address search (Nominatim)
  // -------------------------------------------------------------------------

  void _onSearchChanged(String query) =>
      _search.onQueryChanged(query, _api, _setMapPointerEvents);

  Future<void> _runSearch(String query) =>
      _search.runSearch(query, _api, _setMapPointerEvents);

  Widget _buildSearchDropdown(List<Map<String, dynamic>> results, {bool isHomeSuggestion = false}) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: results.asMap().entries.map((entry) {
          final i      = entry.key;
          final result = entry.value;
          final parts  = (result['display_name'] as String).split(',');
          final title  = isHomeSuggestion ? 'Home' : parts.first.trim();
          // For home: display_name is "number, street, ..." → show "Street Number"
          final sub    = isHomeSuggestion
              ? (parts.length > 1 ? '${parts[1].trim()} ${parts[0].trim()}' : parts.first.trim())
              : (parts.length > 1 ? parts.skip(1).take(2).map((s) => s.trim()).join(', ') : '');
          final homeAddr = context.read<SearchState>().homeAddress;
          final isHome = isHomeSuggestion || (
            homeAddr != null &&
            result['lat'] == homeAddr['lat'] &&
            result['lon'] == homeAddr['lon']
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (i > 0) Divider(height: 1, color: Colors.grey.shade100),
              GestureDetector(
                onTap: () => _selectSearchResult(result),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        isHome ? Icons.home : Icons.location_on_outlined,
                        size: 16,
                        color: isHome ? Colors.orange.shade400 : Colors.grey.shade500,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            if (sub.isNotEmpty)
                              Text(sub, style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      if (!isHomeSuggestion)
                        GestureDetector(
                          onTap: () => _setHomeAddress(result),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              isHome ? Icons.home : Icons.home_outlined,
                              size: 18,
                              color: isHome ? Colors.orange.shade400 : Colors.grey.shade400,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  void _selectSearchResult(Map<String, dynamic> result) {
    final lat = double.parse(result['lat'] as String);
    final lon = double.parse(result['lon'] as String);
    final name = (result['display_name'] as String).split(',').first.trim();
    final target = LatLng(lat, lon);
    _searchController.text = name;
    _search.clearResults();
    setState(() {
      _currentCenter = target;
      _searchMarkerPos = target;
      _searchMarkerName = name;
      _searchMarkerScreenPos = null;
      _showSearchMarkerDetail = false;
      _searchMarkerInfo = null;
    });
    _setMapPointerEvents(true);
    _searchFocus.unfocus();
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 16.0)),
      );
      fetchShadows();
      _fetchWeather(target.latitude, target.longitude);
      _refreshSearchMarkerPosition();
      _fetchSearchMarkerInfo(lat, lon);
    });
  }

  Future<void> _fetchSearchMarkerInfo(double lat, double lon) async {
    final data = await _api.fetchPointInfo(
      lat, lon, formatDate(_selectedDate), _hour.toInt(), ((_hour * 60).toInt() % 60),
    );
    if (mounted && data != null) setState(() => _searchMarkerInfo = data);
  }

  @override
  Widget build(BuildContext context) {
    _screenWidth  = MediaQuery.of(context).size.width;
    final isMobile = _isMobile;
    const panelRightPad = 0;
    final keyboardOpen = isMobile && MediaQuery.of(context).viewInsets.bottom > 0;

    final shell    = context.watch<AppShellState>();
    final errorMsg = shell.errorMessage;
    final panelExpanded = shell.panelExpanded;
    final panelHidden   = shell.panelHidden;
    final mobileTab     = shell.mobileTab;
    final search   = context.watch<SearchState>();

    // Map area — used as Expanded child on mobile, full Scaffold body on desktop
    final mapArea = Stack(
      children: [
        AbsorbPointer(
          absorbing: _draggingSlider || (_loading && !_animating),
          child: MapLibreMap(
            key: _mapKey,
            styleString: mapStyle,
            initialCameraPosition: CameraPosition(target: _currentCenter, zoom: 14.0),
            onMapCreated:          _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle:          _onCameraIdle,
            onMapClick:            _onMapClick,
            trackCameraPosition:   true,
            compassEnabled:        false,
          ),
        ),

        // Radial vignette — fades shadow layer edges so rectangular boundary is hidden
        if (_shadowLayersReady)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _VignettePainter()),
            ),
          ),

        // Map freeze overlay — dims the map while new shadow tiles are loading so the
        // user can clearly see it's updating (not stuck). Fades in/out smoothly.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: (_loading && !_animating) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.32),
                ),
              ),
            ),
          ),
        ),

        // Zoom-in hint badge — shown at all macro zoom levels (below z15 where per-building detail starts)
        if (_currentZoom < 15.0)
          Positioned(
            bottom: 24, left: 0, right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.zoom_in_rounded, size: 14, color: Colors.orange.shade500),
                    const SizedBox(width: 6),
                    Text('For more details, please zoom in.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700,
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
            ),
          ),

        // Tap-to-inspect hint badge (Saved tab only)
        if (_isMobile && mobileTab == 3)
          Positioned(
            bottom: 24, left: 0, right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.touch_app_outlined, size: 14, color: Colors.orange.shade500),
                    const SizedBox(width: 6),
                    Text('Tap map to inspect',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700,
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
            ),
          ),

        // Number labels overlaid on map dots
        IgnorePointer(
          child: Stack(children: [
            ..._sunnySpotScreenPos.asMap().entries.map((e) => Positioned(
              left: e.value.dx - 5,
              top: e.value.dy - 6,
              child: Text('${e.key + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.bold, height: 1)),
            )),
            ..._tourMarkerScreenPos.asMap().entries.map((e) => Positioned(
              left: e.value.dx - 5,
              top: e.value.dy - 6,
              child: Text('${e.key + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.bold, height: 1)),
            )),
            ..._poiScreenPos.asMap().entries.map((e) => Positioned(
              left: e.value.dx - 5,
              top: e.value.dy - 6,
              child: Text('${e.key + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.bold, height: 1)),
            )),
          ]),
        ),

        // Search result marker dot
        if (_searchMarkerScreenPos != null)
          Positioned(
            left: _searchMarkerScreenPos!.dx - 18,
            top:  _searchMarkerScreenPos!.dy - 36,
            child: GestureDetector(
              onTap: () => setState(() => _showSearchMarkerDetail = !_showSearchMarkerDetail),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: Colors.orange.shade500,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                  child: const Icon(Icons.place, color: Colors.white, size: 22),
                ),
              ]),
            ),
          ),

        // Full-screen map blocker — prevents MapLibre from stealing touches when results are visible
        if (search.results.isNotEmpty)
          Positioned.fill(
            child: PointerInterceptor(
              child: GestureDetector(
                onTap: () => _search.clearResults(setPointerEvents: _setMapPointerEvents),
                child: Container(color: Colors.transparent),
              ),
            ),
          ),

        // Search bar
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          top: 12, left: 12, right: 12,
          child: PointerInterceptor(
            child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 10, offset: const Offset(0, 3))],
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(Icons.search, color: Colors.grey.shade500, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        onChanged: _onSearchChanged,
                        onSubmitted: (v) { if (v.trim().isNotEmpty) _runSearch(v.trim()); },
                        textInputAction: TextInputAction.search,
                        keyboardType: TextInputType.text,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Search address or place…',
                          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    if (search.loading)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange.shade400)),
                      )
                    else if (_searchController.text.isNotEmpty)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () { _searchController.clear(); _search.clearResults(setPointerEvents: _setMapPointerEvents); },
                          child: Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Icon(Icons.close, color: Colors.grey.shade400, size: 18),
                          ),
                        ),
                      )
                    else if (!_searchFocus.hasFocus)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (search.homeAddress != null)
                            GestureDetector(
                              onTap: _navigateToHome,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 2, left: 4),
                                child: Icon(Icons.home, size: 22, color: Colors.orange.shade400),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: const WeatherWidget(),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (_searchFocus.hasFocus && search.results.isEmpty && search.homeAddress != null && _searchController.text.isEmpty)
                _buildSearchDropdown([search.homeAddress!], isHomeSuggestion: true),
              if (search.results.isNotEmpty)
                _buildSearchDropdown(search.results),
            ],
            ),
          ),
          ),
        ),

        // Loading bar (top)
        if (_loading)
          Positioned(
            top: 0, left: 0, right: panelRightPad.toDouble(),
            child: LinearProgressIndicator(
              value: _loadingProgress > 0 ? _loadingProgress : null,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              color: Colors.orangeAccent,
            ),
          ),


        // Time-of-day pill — fades in below search bar during 24h animation
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          top: 66, left: 0, right: 0,
          child: Center(child: _buildTimePill()),
        ),

        // Loading pill
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          bottom: 24, left: 0, right: panelRightPad.toDouble(),
          child: Center(child: _buildLoadingPill()),
        ),


        // GPS button — bottom-left on mobile, bottom-right on desktop
        // State 0: grey my_location  State 1: blue my_location  State 2: blue explore
        if (!keyboardOpen)
          Positioned(
            bottom: 16,
            left:  isMobile ? 16  : null,
            right: isMobile ? null : 16,
            child: FloatingActionButton.small(
              heroTag: 'gps',
              onPressed: _onGpsButtonTap,
              backgroundColor: Colors.white,
              foregroundColor: _gpsState == 0 ? Colors.black54 : Colors.blue,
              elevation: 2,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              child: Icon(
                _gpsState == 2 ? Icons.explore : Icons.my_location,
                size: 20,
              ),
            ),
          ),

        // Compass needle — top-right, just below the search bar.
        // Fades in when map is rotated; fades out when North-up.
        // Tap: animate back to North + exit any GPS tracking state.
        if (!keyboardOpen)
          Positioned(
            top: 64, right: 12,
            child: AnimatedOpacity(
              opacity: _mapBearing.abs() > 1.0 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: _mapBearing.abs() <= 1.0,
                child: PointerInterceptor(
                  child: FloatingActionButton.small(
                    heroTag: 'compass',
                    onPressed: _resetToNorth,
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.red.shade600,
                    elevation: 2,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    child: Transform.rotate(
                      angle: -_mapBearing * pi / 180,
                      child: const Icon(Icons.navigation, size: 20),
                    ),
                  ),
                ),
              ),
            ),
          ),

        // Zoom buttons — left on desktop, right on mobile
        if (!keyboardOpen) ...[
          Positioned(
            bottom: 68,
            left:  isMobile ? null : 16,
            right: isMobile ? 16   : null,
            child: _buildZoomButton(Icons.add, () async {
              final cam = _mapController?.cameraPosition;
              if (cam == null) return;
              await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                  CameraPosition(target: cam.target, zoom: (cam.zoom + 0.5).clamp(1, 20))));
            }),
          ),
          Positioned(
            bottom: 16,
            left:  isMobile ? null : 16,
            right: isMobile ? 16   : null,
            child: _buildZoomButton(Icons.remove, () async {
              final cam = _mapController?.cameraPosition;
              if (cam == null) return;
              await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                  CameraPosition(target: cam.target, zoom: (cam.zoom - 0.5).clamp(1, 20))));
            }),
          ),
        ],

        // Error banner
        if (errorMsg != null)
          Positioned(
            bottom: 80, left: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(8)),
              child: Text(errorMsg, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),

      ],
    );

    return Scaffold(
      body: Stack(
        children: [
          isMobile
              ? LayoutBuilder(builder: (ctx, constraints) {
                  final totalH     = constraints.maxHeight;
                  const collapsedH = 256.0;
                  final safeBottom = MediaQuery.of(ctx).padding.bottom;
                  final hiddenH    = 24.0 + 1.0 + 56.0 + safeBottom;
                  final bottomH    = keyboardOpen ? 57.0 : (panelHidden ? hiddenH : (panelExpanded ? totalH : collapsedH));
                  final mapH       = totalH - bottomH;
                  return Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeInOut,
                      height: mapH,
                      child: mapArea,
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeInOut,
                      height: bottomH,
                      child: MobileBottomSheet(
                        contentScroll: _mobileContentScroll,
                        keyboardOpen:  keyboardOpen,
                        onTabTap:      _onMobileTabTap,
                        child:         _buildMobileTabContent(),
                      ),
                    ),
                  ]);
                })
              : Row(children: [
                  Expanded(child: mapArea),
                  SizedBox(width: 280, child: DesktopSidebar(
                    panelScroll: _panelScroll,
                    onTabTap:    _onDesktopTabTap,
                    child:       _buildMobileTabContent(),
                  )),
                ]),
          _buildSplash(),
        ],
      ),
    );
  }

  Widget _buildZoomButton(IconData icon, VoidCallback onTap) {
    return FloatingActionButton.small(
      heroTag: icon == Icons.add ? 'zoom_in' : 'zoom_out',
      onPressed: onTap,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black87,
      elevation: 2,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      child: Icon(icon, size: 20),
    );
  }

  Widget _buildLoadingPill() {
    final visible = _showPill;
    final rawStage = _loadingStage;
    final label = rawStage.isEmpty
        ? 'Loading…'
        : (_lastFetchZoom <= 13 && rawStage.startsWith('Projecting')
            ? 'Computing…'
            : rawStage);
    final pct = _loadingProgress > 0 ? _loadingProgress : null;
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      child: IgnorePointer(
        ignoring: !visible,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RotationTransition(
                    turns: _sunSpinCtrl,
                    child: const Icon(Icons.wb_sunny, color: Colors.orange, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${(_loadingProgress * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: 210,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 5,
                    backgroundColor: Colors.orange.shade100,
                    color: Colors.orange,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimePill() {
    final h     = _hour.toInt();
    final m     = ((_hour % 1.0) * 60).round().clamp(0, 59);
    final ampm  = h < 12 ? 'AM' : 'PM';
    final dispH = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final timeStr = '$dispH:${m.toString().padLeft(2, '0')} $ampm';
    return AnimatedOpacity(
      opacity: _animating ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 400),
      child: IgnorePointer(
        ignoring: !_animating,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xD21A1A2E),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.orange.withValues(alpha: 0.28),
                blurRadius: 20,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wb_sunny_rounded, color: Colors.orange, size: 14),
              const SizedBox(width: 8),
              Text(
                timeStr,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSplash() {
    final splashVisible = context.watch<AppShellState>().splashVisible;
    return AnimatedOpacity(
      opacity: splashVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 600),
      child: IgnorePointer(
        ignoring: !splashVisible,
        child: Container(
          color: const Color(0xFFFFFBF5),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RotationTransition(
                  turns: _sunSpinCtrl,
                  child: const Icon(Icons.wb_sunny, color: Colors.orange, size: 64),
                ),
                const SizedBox(height: 20),
                const Text(
                  'sunspot',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                    color: Color(0xFF444444),
                    letterSpacing: 5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Tab-bar callbacks (shared by mobile and desktop shells)
  // -------------------------------------------------------------------------

  void _onMobileTabTap(int i) {
    if (i != 1) {
      setState(() {
        _sunnySpots = []; _sunnyPois = [];
        _sunnySpotScreenPos = []; _poiScreenPos = [];
      });
      _clearSunnySpots();
      _clearPoiMarkers();
      _lastSearchCenter = null;
      _lastSearchZoom   = null;
    }
    _spotsSearchGen++; _poisSearchGen++;
    _searchController.clear();
    _shell.setMobileTab(i);
    _shell.clearSpot();
    _search.clearResults(setPointerEvents: _setMapPointerEvents);
    setState(() {
      _showSearchMarkerDetail = false;
      _searchMarkerPos        = null;
      _searchMarkerScreenPos  = null;
    });
    _mobileContentScroll.jumpTo(0);
    if (i == 3) _saved.refreshSunnyStatus(_api, _selectedDate, _hour);
  }

  void _onDesktopTabTap(int i) {
    if (i != 1) {
      setState(() {
        _sunnySpots = []; _sunnyPois = [];
        _sunnySpotScreenPos = []; _poiScreenPos = [];
      });
      _clearSunnySpots();
      _clearPoiMarkers();
      _lastSearchCenter = null;
      _lastSearchZoom   = null;
    }
    _spotsSearchGen++; _poisSearchGen++;
    _shell.setMobileTab(i);
    _shell.clearSpot();
    _panelScroll.jumpTo(0);
    if (i == 3) _saved.refreshSunnyStatus(_api, _selectedDate, _hour);
  }

  // ---- Time header ----
  Widget _buildTimeHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Icon(timePeriodIcon(timePeriod(_hour)), color: Colors.orange.shade300, size: 22),
        const SizedBox(width: 6),
        Text(timePeriod(_hour),
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w300,
                color: Colors.grey.shade400, letterSpacing: -0.5)),
        const Spacer(),
        if (!_isToday(_selectedDate))
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade50,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.blueGrey.shade200, width: 1),
            ),
            child: Text('Historical',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                    color: Colors.blueGrey.shade400)),
          ),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: _hour, end: _hour),  // begin=_hour: no sweep-from-midnight on load; subsequent changes animate from current value
          duration: const Duration(milliseconds: 350),
          builder: (context, value, _) {
            return Text(
              formatDisplayHour(value),
              style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w300,
                color: _draggingSlider ? Colors.orange : Colors.black87,
                letterSpacing: -0.5,
              ),
            );
          },
        ),
      ],
    );
  }

  // ---- Time slider ----
  Widget _buildTimeSlider() {
    final minH      = _sunriseHour ?? 5.0;
    final maxH      = _sunsetHour  ?? 22.0;
    final divisions = (maxH - minH).round().clamp(1, 23);
    final sliderVal = _hour.clamp(minH, maxH);
    final noonInRange = minH < 12.0 && maxH > 12.0;

    // Slider full width — locked when LIVE is active
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: _liveMode ? Colors.red.shade300 : Colors.orange,
        inactiveTrackColor: _liveMode ? Colors.red.shade100 : Colors.orange.shade100,
        thumbColor: _liveMode ? Colors.grey.shade400 : Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayColor: _liveMode ? Colors.transparent : Colors.orange.withValues(alpha: 0.2),
        disabledThumbColor: Colors.grey.shade400,
        disabledActiveTrackColor: Colors.red.shade200,
        disabledInactiveTrackColor: Colors.red.shade100,
      ),
      child: Slider(
        value: sliderVal,
        min: minH, max: maxH, divisions: divisions,
        onChangeStart: _liveMode ? null : (_) {
          _liveTimer?.cancel();
          setState(() { _draggingSlider = true; _liveMode = false; });
          _setMapPointerEvents(false);
        },
        onChanged:  _liveMode ? null : (v) => setState(() => _hour = v),
        onChangeEnd: _liveMode ? null : (_) {
          setState(() => _draggingSlider = false);
          _setMapPointerEvents(true);
          // Debounce: if user scrubs rapidly, only the final position triggers a fetch.
          _sliderDebounce?.cancel();
          _sliderDebounce = Timer(const Duration(milliseconds: 250), fetchShadows);
        },
      ),
    );

    // Row 1: ☀ sunrise · 12 PM · 🌙 sunset
    final labelsRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.wb_sunny_outlined, size: 11, color: Colors.orange.shade400),
            const SizedBox(width: 3),
            Text(_formatSliderHour(minH),
                style: TextStyle(fontSize: 13, color: Colors.orange.shade400, fontWeight: FontWeight.w500)),
          ]),
          if (noonInRange)
            Text('12 PM', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.nightlight_round, size: 11, color: Colors.blueGrey.shade300),
            const SizedBox(width: 3),
            Text(_formatSliderHour(maxH),
                style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade300, fontWeight: FontWeight.w500)),
          ]),
        ],
      ),
    );

    // Row 2: [LIVE] · [24h] pills
    final pillsRow = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: _toggleLiveMode,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: _liveMode ? Colors.red.shade400 : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _liveMode ? Colors.red.shade400 : Colors.grey.shade300,
                width: 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 7, height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: _liveMode ? Colors.white : Colors.red.shade300,
                  shape: BoxShape.circle,
                ),
              ),
              Text('LIVE', style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: _liveMode ? Colors.white : Colors.grey.shade500,
                letterSpacing: 0.6,
              )),
            ]),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _toggle24h,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: (_animating || _preloading24h) ? Colors.orange.shade400 : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (_animating || _preloading24h) ? Colors.orange.shade400 : Colors.grey.shade300,
                width: 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _preloading24h ? Icons.hourglass_top_rounded : (_animating ? Icons.stop_rounded : Icons.play_arrow_rounded),
                size: 14,
                color: (_animating || _preloading24h) ? Colors.white : Colors.grey.shade500,
              ),
              const SizedBox(width: 3),
              Text(_preloading24h ? '…' : (_animating ? '■' : '24h'),
                  style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: (_animating || _preloading24h) ? Colors.white : Colors.grey.shade500,
                  )),
            ]),
          ),
        ),
      ],
    );

    return Column(children: [
      slider,
      const SizedBox(height: 6),
      labelsRow,
      const SizedBox(height: 8),
      pillsRow,
    ]);
  }

  String _formatSliderHour(double hour) {
    final h = hour.toInt().clamp(0, 23);
    final m = ((hour - h) * 60).round();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  // -------------------------------------------------------------------------
  // Sunny Tour
  // -------------------------------------------------------------------------

  List<Map<String, dynamic>> _orderByNearestNeighbor(
      List<Map<String, dynamic>> spots, LatLng start) {
    final remaining = List<Map<String, dynamic>>.from(spots);
    final ordered   = <Map<String, dynamic>>[];
    LatLng current  = start;
    while (remaining.isNotEmpty) {
      int    ni = 0;
      double nd = double.infinity;
      for (int i = 0; i < remaining.length; i++) {
        final d = _distanceMeters(current,
            LatLng(remaining[i]['lat'] as double, remaining[i]['lon'] as double));
        if (d < nd) { nd = d; ni = i; }
      }
      ordered.add(remaining[ni]);
      current = LatLng(ordered.last['lat'] as double, ordered.last['lon'] as double);
      remaining.removeAt(ni);
    }
    return ordered;
  }

  Future<void> _buildTour() async {
    if (_tourBuilding) return;
    setState(() { _tourBuilding = true; _tourSpots = []; });
    await _clearSunnySpots();

    try {
      final date = _selectedDate;
      final data = await _api.findSunnySpotsUnbounded(
        lat: _currentCenter.latitude, lon: _currentCenter.longitude,
        hour: _hour.toInt(), minute: ((_hour * 60).toInt() % 60),
        month: date.month, day: date.day, n: 12,
      );
      final raw  = ((data?['spots'] as List?) ?? []).cast<Map<String, dynamic>>()
          .map((s) => <String, dynamic>{
                'lat':            (s['lat']  as num).toDouble(),
                'lon':            (s['lon']  as num).toDouble(),
                'sun_hours_left': (s['sun_hours_left'] as num?)?.toInt() ?? 0,
                'sun_until':      s['sun_until'] as int?,
              })
          .toList();

      if (raw.isEmpty) {
        setState(() => _tourBuilding = false);
        _showError('No sun at this hour — move the time slider');
        return;
      }

      // Order nearest-neighbor, then trim to walking budget
      final start   = _gpsPosition ?? _currentCenter;
      final ordered = _orderByNearestNeighbor(raw, start);
      final budget  = _tourDuration * 80.0;   // meters at 80 m/min
      double walked = 0;
      LatLng cur    = start;
      final kept    = <Map<String, dynamic>>[];
      for (final s in ordered) {
        final pos = LatLng(s['lat'] as double, s['lon'] as double);
        final d   = _distanceMeters(cur, pos);
        if (walked + d > budget) break;
        walked += d;
        kept.add({ ...s, '_dist': d.round() });
        cur = pos;
      }
      if (kept.isEmpty) kept.add({ ...ordered.first, '_dist':
          _distanceMeters(start, LatLng(ordered.first['lat'] as double,
              ordered.first['lon'] as double)).round() });

      setState(() => _tourSpots = kept);
      _geocodeSpots(kept);
      await _drawTourLine(start, kept);
      await _refreshTourMarkerPositions();
    } catch (e) {
      _showError('Tour error: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _tourBuilding = false);
    }
  }

  Future<void> _drawTourLine(LatLng start, List<Map<String, dynamic>> spots) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    // Line
    final coords = [
      [start.longitude, start.latitude],
      ...spots.map((s) => [s['lon'] as double, s['lat'] as double]),
    ];
    final lineGeojson = {
      'type': 'FeatureCollection',
      'features': [{
        'type': 'Feature',
        'geometry': {'type': 'LineString', 'coordinates': coords},
        'properties': {},
      }],
    };

    // Markers — numbered points for each stop
    final markerFeatures = spots.asMap().entries.map((e) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [e.value['lon'], e.value['lat']],
      },
      'properties': {'index': e.key + 1},
    }).toList();
    final markerGeojson = {
      'type': 'FeatureCollection',
      'features': markerFeatures,
    };

    if (_tourLayerReady) {
      await ctrl.setGeoJsonSource('tour-route', lineGeojson);
      await ctrl.setGeoJsonSource('tour-markers', markerGeojson);
    } else {
      // Line
      await ctrl.addSource('tour-route', GeojsonSourceProperties(data: lineGeojson));
      await ctrl.addLayer(
        'tour-route', 'tour-line',
        LineLayerProperties(lineColor: '#FF8C00', lineWidth: 3.0,
            lineDasharray: [6.0, 4.0]),
        enableInteraction: false,
      );
      // Markers
      await ctrl.addSource('tour-markers', GeojsonSourceProperties(data: markerGeojson));
      await ctrl.addLayer(
        'tour-markers', 'tour-marker-glow',
        CircleLayerProperties(
          circleRadius: 20,
          circleColor: '#FF8C00',
          circleOpacity: 0.25,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'tour-markers', 'tour-marker-dot',
        CircleLayerProperties(
          circleRadius: 10,
          circleColor: '#FF8C00',
          circleOpacity: 1.0,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _tourLayerReady = true;
    }
  }

  Future<void> _clearTourLine() async {
    if (mounted) setState(() => _tourMarkerScreenPos = []);
    if (!_tourLayerReady) return;
    final empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};
    await _mapController?.setGeoJsonSource('tour-route', empty);
    await _mapController?.setGeoJsonSource('tour-markers', empty);
  }

  Widget _buildTourTab() {
    final saved = context.watch<SavedSpotsState>();
    final totalDist = _tourSpots.fold<int>(
        0, (sum, s) => sum + ((s['_dist'] as num?)?.toInt() ?? 0));
    final totalMin  = (totalDist / 80).round();
    final totalSun  = _tourSpots.fold<int>(
        0, (sum, s) => sum + ((s['sun_hours_left'] as num?)?.toInt() ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Duration chips + clear
        Wrap(alignment: WrapAlignment.center, runSpacing: 6, children: [
          ...[15, 30, 60].map((min) {
            final sel = _tourDuration == min;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(() => _tourDuration = min),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? Colors.orange : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text('$min min',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: sel ? Colors.white : Colors.black54)),
                ),
              ),
            );
          }),
          if (_tourSpots.isNotEmpty || _tourBuilding)
            GestureDetector(
              onTap: () {
                setState(() { _tourSpots = []; _tourMarkerScreenPos = []; });
                _clearTourLine();
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                child: Icon(Icons.close, size: 16, color: Colors.grey.shade500),
              ),
            ),
        ]),
        const SizedBox(height: 10),

        // Plan button — same style as Find sunny spots
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: _tourBuilding ? null : _buildTour,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _tourBuilding ? Colors.orange : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _tourBuilding
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(Icons.wb_sunny_outlined, size: 15, color: Colors.black54),
                  const SizedBox(width: 6),
                  Text(_tourBuilding ? 'Planning...' : 'Plan sunny tour',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _tourBuilding ? Colors.white : Colors.black54)),
                ]),
              ),
            ),
          ),
        ]),

        // Results
        if (_tourSpots.isNotEmpty) ...[
          const SizedBox(height: 16),
          // Summary row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _tourStat(Icons.straighten, '${totalDist}m'),
                _tourStat(Icons.timer_outlined, '~$totalMin min'),
                _tourStat(Icons.wb_sunny_outlined, '~${totalSun}h sun'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Spot list
          ..._tourSpots.asMap().entries.map((e) {
            final idx  = e.key;
            final spot = e.value;
            final lat  = spot['lat'] as double;
            final lon  = spot['lon'] as double;
            final key  = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
            final addr = saved.addresses[key] ?? 'Spot ${idx + 1}';
            final dist = (spot['_dist'] as num?)?.toInt() ?? 0;
            final sunH = spot['sun_hours_left'] as int? ?? 0;
            final until = spot['sun_until'] as int?;
            final walkMin = (dist / 80).round();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Walk arrow (except first)
                if (idx > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 11, top: 2, bottom: 2),
                    child: Row(children: [
                      Icon(Icons.arrow_downward, size: 12, color: Colors.grey.shade400),
                      const SizedBox(width: 4),
                      Text('$walkMin min walk · ${dist}m',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                    ]),
                  ),
                GestureDetector(
                  onTap: () => _mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(LatLng(lat, lon), 17.0)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Container(
                        width: 20, height: 20,
                        decoration: const BoxDecoration(
                            color: Color(0xFFFFD700), shape: BoxShape.circle),
                        child: Center(child: Text('${idx + 1}',
                            style: const TextStyle(fontSize: 10,
                                fontWeight: FontWeight.bold, color: Colors.white))),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(addr, style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500,
                              color: Color(0xFF1A1A1A)),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            until != null
                                ? '$sunH h · until ${until.toString().padLeft(2,'0')}:00'
                                : '$sunH h of sun',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      )),
                    ]),
                  ),
                ),
              ],
            );
          }),
        ],
      ],
    );
  }

  Widget _tourStat(IconData icon, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: Colors.grey.shade500),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
    ]);
  }

  // ---- Haversine distance helper ----
  double _distanceMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final lat1 = a.latitude  * pi / 180;
    final lat2 = b.latitude  * pi / 180;
    final dlat = (b.latitude  - a.latitude)  * pi / 180;
    final dlon = (b.longitude - a.longitude) * pi / 180;
    final x = sin(dlat / 2) * sin(dlat / 2) +
        cos(lat1) * cos(lat2) * sin(dlon / 2) * sin(dlon / 2);
    return r * 2 * atan2(sqrt(x), sqrt(1 - x));
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }


  IconData _poiIcon(String amenity) {
    if (amenity.contains('cafe'))        return Icons.local_cafe;
    if (amenity.contains('park') || amenity.contains('garden')) return Icons.park;
    if (amenity.contains('square') || amenity.contains('pedestrian')) return Icons.location_city;
    if (amenity.contains('bar') || amenity.contains('pub') || amenity.contains('beer')) return Icons.sports_bar;
    if (amenity.contains('restaurant') || amenity.contains('fast_food')) return Icons.restaurant;
    return Icons.place;
  }

  String _poiLabel(String amenity) {
    if (amenity.contains('cafe'))        return 'Café';
    if (amenity.contains('park') || amenity.contains('garden')) return 'Park';
    if (amenity.contains('square') || amenity.contains('pedestrian')) return 'Square';
    if (amenity.contains('beer_garden')) return 'Beer garden';
    if (amenity.contains('bar') || amenity.contains('pub')) return 'Bar';
    if (amenity.contains('restaurant'))  return 'Restaurant';
    if (amenity.contains('fast_food'))   return 'Food';
    return 'Spot';
  }

  // ---- Find sunny spots / places ----
  Widget _buildFindSunnySpotsSection() {
    final saved = context.watch<SavedSpotsState>();
    // Mode toggle
    Widget modeToggle = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _modeBtn('Spots', Icons.wb_sunny_outlined, !_placesMode, () { setState(() { _placesMode = false; _sunnyPois = []; _poisNoResults = false; }); _clearPoiMarkers(); }),
      const SizedBox(width: 8),
      _modeBtn('Places', Icons.storefront_outlined, _placesMode, () { setState(() { _placesMode = true; _sunnySpots = []; _spotsNoResults = false; }); _clearSunnySpots(); }),
    ]);

    if (!_placesMode) {
      // ── Spots mode ──────────────────────────────────────────────────────────
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        modeToggle,
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: _findingSunnySpots ? null : _findSunnySpots,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _findingSunnySpots ? Colors.orange : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _findingSunnySpots
                      ? SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(Icons.wb_sunny_outlined, size: 15,
                          color: _findingSunnySpots ? Colors.white : Colors.black54),
                  const SizedBox(width: 6),
                  Text(_findingSunnySpots ? 'Searching...' : 'Find sunny spots',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _findingSunnySpots ? Colors.white : Colors.black54)),
                ]),
              ),
            ),
          ),
          if (_sunnySpots.isNotEmpty) ...[
            const SizedBox(width: 8),
            IconButton(
              onPressed: _clearSunnySpots,
              icon: const Icon(Icons.close, size: 16),
              style: IconButton.styleFrom(
                backgroundColor: Colors.grey.shade100,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              padding: const EdgeInsets.all(10),
            ),
          ],
        ]),
        if (_spotsZoomHint) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.zoom_in, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Text('Zoom in to see results', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ],
        if (_spotsNoResults) ...[
          const SizedBox(height: 16),
          _buildNoResultsMessage(),
        ],
        if (_sunnySpots.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._sunnySpots.asMap().entries.map((e) {
            final idx      = e.key;
            final spot     = e.value;
            final spotPos  = LatLng(spot['lat'] as double, spot['lon'] as double);
            final sunH     = (spot['sun_hours_left'] as int?) ?? 0;
            final sunUntil = spot['sun_until'] as int?;
            final gps      = _gpsPosition;
            final distLbl  = gps != null ? _formatDistance(_distanceMeters(gps, spotPos)) : null;
            final addrKey  = '${spotPos.latitude.toStringAsFixed(6)},${spotPos.longitude.toStringAsFixed(6)}';
            final poiName  = (spot['_poi_name'] as String? ?? '');
            final address  = poiName.isNotEmpty ? poiName : (saved.addresses[addrKey] ?? 'Sunny spot ${idx + 1}');
            final isSaved  = saved.isSaved(spotPos.latitude, spotPos.longitude);
            final category = spot['_category'] as String? ?? 'spot';
            final (catIcon, catLabel, catColor) = switch (category) {
              'park'   => (Icons.park,          'Park',   const Color(0xFF4CAF50)),
              'square' => (Icons.location_city, 'Square', const Color(0xFF7B61FF)),
              _        => (Icons.wb_sunny,      'Spot',   const Color(0xFFFF9800)),
            };
            final inShadow = sunUntil == null;
            final sunLbl = inShadow
                ? 'In shadow'
                : sunH == 0
                    ? '< 1h · until ${sunUntil.toString().padLeft(2,'0')}:00'
                    : '$sunH h · until ${sunUntil.toString().padLeft(2,'0')}:00';
            return _spotCard(
              circleChild: Text('${idx + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
              circleColor: inShadow ? Colors.grey.shade400 : const Color(0xFFFFD700),
              address: address,
              distLabel: distLbl,
              sunLabel: sunLbl,
              categoryIcon: catIcon,
              categoryLabel: catLabel,
              isSaved: isSaved,
              inShadow: inShadow,
              onTap: () => _selectSpot(spot, idx),
            );
          }),
        ],
      ]);
    }

    // ── Places mode ─────────────────────────────────────────────────────────
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      modeToggle,
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: GestureDetector(
            onTap: _loadingPois ? null : _findSunnyPois,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _loadingPois ? Colors.orange : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _loadingPois
                    ? SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(Icons.storefront_outlined, size: 15, color: Colors.black54),
                const SizedBox(width: 6),
                Text(_loadingPois ? 'Searching...' : 'Find sunny places',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: _loadingPois ? Colors.white : Colors.black54)),
              ]),
            ),
          ),
        ),
        if (_sunnyPois.isNotEmpty) ...[
          const SizedBox(width: 8),
          IconButton(
            onPressed: () { setState(() => _sunnyPois = []); _clearPoiMarkers(); },
            icon: const Icon(Icons.close, size: 16),
            style: IconButton.styleFrom(
              backgroundColor: Colors.grey.shade100,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            padding: const EdgeInsets.all(10),
          ),
        ],
      ]),
      if (_poisNoResults) ...[
        const SizedBox(height: 16),
        _buildNoResultsMessage(),
      ],
      if (_sunnyPois.isNotEmpty) ...[
        const SizedBox(height: 10),
        ..._sunnyPois.asMap().entries.map((e) {
          final idx     = e.key;
          final poi     = e.value;
          final lat     = poi['lat'] as double;
          final lon     = poi['lon'] as double;
          final name    = (poi['name'] as String? ?? '').isNotEmpty
              ? poi['name'] as String
              : (poi['amenity'] as String? ?? 'Place ${idx + 1}');
          final dist          = poi['dist'] as int? ?? 0;
          final amenity       = poi['amenity'] as String? ?? '';
          final sunH          = (poi['sun_hours_left'] as int?) ?? 0;
          final sunUntil      = poi['sun_until'] as int?;
          final openingHours  = poi['opening_hours'] as String? ?? '';
          final outdoorSeating = poi['outdoor_seating'] as String? ?? '';
          final isSaved  = saved.isSaved(lat, lon);
          final catLabel = _poiLabel(amenity);
          final catIcon  = _poiIcon(amenity);
          final inShadow = sunUntil == null;
          final sunLbl = inShadow
              ? 'In shadow'
              : sunH == 0
                  ? '< 1h · until ${sunUntil.toString().padLeft(2,'0')}:00'
                  : '$sunH h · until ${sunUntil.toString().padLeft(2,'0')}:00';
          return _spotCard(
            circleChild: Text('${idx + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
            circleColor: inShadow ? Colors.grey.shade400 : const Color(0xFFFF8C00),
            address: name,
            distLabel: _formatDistance(dist.toDouble()),
            sunLabel: sunLbl,
            categoryIcon: catIcon,
            categoryLabel: catLabel,
            isSaved: isSaved,
            inShadow: inShadow,
            onTap: () => _selectSpot({
              'lat': lat, 'lon': lon,
              'sun_hours_left': sunH, 'sun_until': sunUntil,
              '_poi_name': name, '_poi_amenity': amenity,
              '_opening_hours': openingHours,
              '_outdoor_seating': outdoorSeating,
            }, idx),
          );
        }),
      ],
    ]);
  }

  Widget _modeBtn(String label, IconData icon, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? Colors.orange : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14,
              color: active ? Colors.white : Colors.black54),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: active ? Colors.white : Colors.black54,
          )),
        ]),
      ),
    );
  }

  Widget _spotCard({
    required Widget circleChild,
    required Color circleColor,
    required String address,
    required String? distLabel,
    required String sunLabel,
    required bool isSaved,
    required VoidCallback onTap,
    IconData? categoryIcon,
    String? categoryLabel,
    bool inShadow = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Container(
                width: 26, height: 26,
                decoration: BoxDecoration(color: circleColor, shape: BoxShape.circle),
                child: Center(child: circleChild),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(address,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                          color: Color(0xFF1A1A1A)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (distLabel != null) ...[
                      Icon(Icons.directions_walk, size: 11, color: Colors.grey.shade400),
                      const SizedBox(width: 2),
                      Text(distLabel, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      const SizedBox(width: 5),
                      Text('·', style: TextStyle(fontSize: 11, color: Colors.grey.shade300)),
                      const SizedBox(width: 5),
                    ],
                    Icon(inShadow ? Icons.nights_stay_outlined : Icons.wb_sunny_outlined,
                        size: 11, color: inShadow ? Colors.grey.shade400 : Colors.orange.shade400),
                    const SizedBox(width: 2),
                    Flexible(child: Text(sunLabel, style: TextStyle(fontSize: 11,
                        color: inShadow ? Colors.grey.shade400 : Colors.orange.shade600),
                        overflow: TextOverflow.ellipsis)),
                    if (categoryIcon != null) ...[
                      const SizedBox(width: 5),
                      Text('·', style: TextStyle(fontSize: 11, color: Colors.grey.shade300)),
                      const SizedBox(width: 5),
                      Icon(categoryIcon, size: 11, color: Colors.grey.shade400),
                      const SizedBox(width: 2),
                      Flexible(child: Text(categoryLabel ?? '', style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          overflow: TextOverflow.ellipsis)),
                    ],
                  ]),
                ]),
              ),
              if (isSaved) ...[const SizedBox(width: 4), Icon(Icons.favorite, size: 14, color: Colors.red.shade300)],
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade300),
            ]),
          ),
        ),
      ),
    );
  }

  // ---- Date section ----
  Widget _buildDateSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: const [
          Icon(Icons.calendar_today, size: 14, color: Colors.grey),
          SizedBox(width: 4),
          Text('Date', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        const SizedBox(height: 6),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formattedDate,
                      style: const TextStyle(fontSize: 14)),
                  const Icon(Icons.calendar_month, size: 18, color: Colors.grey),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNoResultsMessage() {
    return Column(children: [
      Icon(Icons.wb_cloudy_outlined, size: 32, color: Colors.grey.shade300),
      const SizedBox(height: 8),
      Text('No sunny spots found here',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Text('Everything is in shadow right now.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
    ]);
  }

  Widget _buildSearchMarkerDetail() {
    final saved = context.watch<SavedSpotsState>();
    final pos  = _searchMarkerPos!;
    final name = _searchMarkerName ?? 'Selected location';
    final info = _searchMarkerInfo;
    final isSunny   = info?['is_sunny'] as bool? ?? false;
    final sunUntil  = info?['sun_until'] as int?;
    final sunHours  = info?['sun_hours_left'] as int? ?? 0;
    final gps       = _gpsPosition;
    final distLabel = gps != null ? _formatDistance(_distanceMeters(gps, pos)) : null;
    final isSaved   = saved.isSaved(pos.latitude, pos.longitude);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 26, height: 26,
            decoration: BoxDecoration(color: Colors.orange.shade500, shape: BoxShape.circle),
            child: const Icon(Icons.place, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          GestureDetector(
            onTap: () { _searchController.clear(); _search.clearResults(); setState(() { _showSearchMarkerDetail = false; _searchMarkerPos = null; _searchMarkerScreenPos = null; }); },
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.close, size: 22, color: Colors.grey.shade500),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          if (distLabel != null) Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.directions_walk, size: 12, color: Colors.grey.shade500),
            const SizedBox(width: 3),
            Text(distLabel, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
          if (info != null) Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isSunny ? Icons.wb_sunny_outlined : Icons.nights_stay_outlined,
                size: 12, color: isSunny ? Colors.orange.shade400 : Colors.grey.shade400),
            const SizedBox(width: 3),
            Text(
              isSunny
                  ? (sunUntil != null ? '$sunHours h · until ${sunUntil.toString().padLeft(2, '0')}:00' : 'Sunny')
                  : 'In shadow',
              style: TextStyle(fontSize: 12,
                  color: isSunny ? Colors.orange.shade700 : Colors.grey.shade500),
            ),
          ]),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          _sheetButton(
            icon: Icons.directions_walk, label: 'Navigate',
            color: Colors.orange.shade700,
            onTap: () => html.window.open(
              'https://www.google.com/maps/dir/?api=1&destination=${pos.latitude},${pos.longitude}&travelmode=walking',
              '_blank'),
          ),
          const SizedBox(width: 8),
          _sheetButton(
            icon: isSaved ? Icons.favorite : Icons.favorite_outline,
            label: isSaved ? 'Saved' : 'Save',
            color: isSaved ? Colors.orange.shade800 : Colors.orange.shade600,
            onTap: () {
              if (isSaved) {
                _saved.removeWhere((s) => s['lat'] == pos.latitude && s['lon'] == pos.longitude);
              } else {
                _saved.add({'lat': pos.latitude, 'lon': pos.longitude, 'address': name});
              }
            },
          ),
          const SizedBox(width: 8),
          _sheetButton(
            icon: Icons.share, label: 'Share',
            color: Colors.orange.shade600,
            onTap: () => html.window.navigator.clipboard?.writeText(
              '${html.window.location.href.split('?').first}?server=${Uri.encodeComponent(flaskBaseUrl)}&lat=${pos.latitude}&lon=${pos.longitude}'),
          ),
        ]),
      ]),
    );
  }

  Widget _buildMobileTabContent() {
    final shell = context.watch<AppShellState>();
    final saved = context.watch<SavedSpotsState>();
    if (_showSearchMarkerDetail && _searchMarkerPos != null) return _buildSearchMarkerDetail();
    if (shell.selectedSpot != null) return _buildSpotDetail();
    switch (shell.mobileTab) {
      case 0: // Time
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTimeHeader(),
            const SizedBox(height: 4),
            _buildTimeSlider(),
            const SizedBox(height: 16),
            _buildDateSection(),
          ],
        );
      case 1: // Spots
        return _buildFindSunnySpotsSection();
      case 2: // Tour
        return _buildTourTab();
      case 3: // Saved
        if (saved.spots.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.favorite_outline, size: 44, color: Colors.grey.shade300),
                  const SizedBox(height: 10),
                  Text('No saved spots yet',
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade400)),
                  const SizedBox(height: 4),
                  Text('Tap a spot and press Save',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade300)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.touch_app_outlined, size: 14, color: Colors.grey.shade400),
                      const SizedBox(width: 6),
                      Text('Tap the map to inspect any point',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                    ]),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tap-to-inspect hint
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.touch_app_outlined, size: 13, color: Colors.grey.shade400),
                const SizedBox(width: 6),
                Text('Tap the map to inspect any point',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ]),
            ),
            ...saved.spots.asMap().entries.map((e) {
              final idx   = e.key;
              final s     = e.value;
              final lat   = s['lat'] as double;
              final lon   = s['lon'] as double;
              final addr  = s['address'] as String? ?? 'Saved spot ${idx + 1}';
              final sunH  = s['sun_hours_left'] as int? ?? 0;
              final until = s['sun_until'] as int?;
              final key   = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
              final sunny = saved.sunnyStatus[key];
              final gps   = _gpsPosition;
              final distLabel = gps != null
                  ? _formatDistance(_distanceMeters(gps, LatLng(lat, lon)))
                  : null;

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _showPin(LatLng(lat, lon));
                      _selectSpot(s, idx);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          // Heart circle
                          Container(
                            width: 22, height: 22,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF8C00),
                              shape: BoxShape.circle,
                            ),
                            child: const Center(
                              child: Icon(Icons.favorite, size: 11, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(addr,
                                    style: const TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.w500),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Row(children: [
                                  if (distLabel != null) ...[
                                    Icon(Icons.directions_walk, size: 11,
                                        color: Colors.grey.shade500),
                                    const SizedBox(width: 2),
                                    Text(distLabel,
                                        style: TextStyle(fontSize: 11,
                                            color: Colors.grey.shade600)),
                                    const SizedBox(width: 8),
                                  ],
                                  Icon(Icons.wb_sunny_outlined, size: 11,
                                      color: Colors.grey.shade400),
                                  const SizedBox(width: 2),
                                  Text(
                                    until != null
                                        ? '$sunH h · until ${until.toString().padLeft(2, '0')}:00'
                                        : '$sunH h of sun',
                                    style: TextStyle(fontSize: 11,
                                        color: Colors.grey.shade500),
                                  ),
                                  if (sunny != null) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      sunny ? Icons.wb_sunny : Icons.nights_stay_outlined,
                                      size: 11,
                                      color: sunny ? Colors.orange.shade500 : Colors.blueGrey.shade300,
                                    ),
                                  ],
                                ]),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _saved.removeAt(idx),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.close, size: 16,
                                  color: Colors.grey.shade400),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

}

class _VignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
