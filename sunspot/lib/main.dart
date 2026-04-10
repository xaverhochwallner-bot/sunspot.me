import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Sunshadow Map',
      home: SunMapScreen(),
      debugShowCheckedModeBanner: false,
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
  static const String mapStyle     = 'https://tiles.openfreemap.org/styles/bright';

  MapLibreMapController? _mapController;
  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  Timer? _debounceTimer;

  double   _hour          = DateTime.now().hour.toDouble();
  DateTime _selectedDate  = DateTime.now();
  double   _elevation     = 0.0;
  double   _azimuth       = 0.0;
  bool     _loading       = false;
  bool     _mapReady      = false;
  bool     _animating      = false;
  bool     _draggingSlider = false;
  String?  _errorMessage;

  double              _loadingProgress = 0.0;
  String              _loadingStage    = '';
  bool                _showPill        = false;  // only true after 150ms delay
  Timer?              _pillTimer;
  html.EventSource?   _activeEventSource;
  int                 _fetchGen        = 0;
  Completer<void>?    _fetchCompleter;
  bool                _shadowLayersReady = false;
  int                 _lastFetchZoom     = -1;

  // Panel
  bool _panelOpen = true;

  // Live mode
  bool   _liveMode  = false;
  Timer? _liveTimer;

  // Sunrise / sunset (local hours, e.g. 6.0, 20.0)
  double? _sunriseHour;
  double? _sunsetHour;

  // Point info popup
  LatLng?                _clickedPoint;
  bool                   _pointInfoLoading = false;
  Map<String, dynamic>?  _pointInfo;
  bool                   _ignoreNextMapClick = false;
  bool                   _pinLayerReady = false;
  double                 _screenWidth = 1200;

  // GPS blue dot
  LatLng? _gpsPosition;
  bool    _myLocationLayerReady = false;

  // Sunny spots
  List<Map<String, dynamic>> _sunnySpots          = [];
  bool                       _sunnySpotsLayerReady = false;
  bool                       _findingSunnySpots    = false;

  // Weather overlay
  Map<String, dynamic>? _weatherData;

  // Reverse-geocoded addresses — keyed by "lat,lon"
  Map<String, String> _spotAddresses = {};

  // Saved spots — persisted to localStorage
  List<Map<String, dynamic>> _savedSpots = [];

  // Panel scroll
  final ScrollController _panelScroll = ScrollController();

  // Mobile bottom UI
  int _mobileTab = 0;
  final ScrollController _mobileContentScroll = ScrollController();
  double _screenHeight = 800.0;

  bool get _isMobile => _screenWidth < 650;

  // Search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode             _searchFocus      = FocusNode();
  List<Map<String, dynamic>>  _searchResults    = [];
  bool                        _searchLoading    = false;
  Timer?                      _searchDebounce;

  late final AnimationController _sunSpinCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  // Used by TweenAnimationBuilder — accepts fractional hours during animation
  String _formatDisplayHour(double h) {
    final totalMinutes = (h * 60).round() % (24 * 60);
    final hour   = totalMinutes ~/ 60;
    final minute = totalMinutes % 60;
    final period = hour < 12 ? 'AM' : 'PM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:${minute.toString().padLeft(2, '0')} $period';
  }

  String get _timePeriod {
    final h = _hour.toInt();
    if (h >= 5  && h < 12) return 'MORNING';
    if (h >= 12 && h < 17) return 'AFTERNOON';
    if (h >= 17 && h < 21) return 'EVENING';
    return 'NIGHT';
  }

  IconData get _timePeriodIcon {
    switch (_timePeriod) {
      case 'MORNING':   return Icons.wb_sunny_outlined;
      case 'AFTERNOON': return Icons.wb_sunny;
      case 'EVENING':   return Icons.wb_twilight;
      default:          return Icons.nightlight_round;
    }
  }

  String _azimuthDirection(double az) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[((az + 22.5) / 45).floor() % 8];
  }

  String get _formattedDate {
    return '${_selectedDate.day.toString().padLeft(2, '0')}.'
           '${_selectedDate.month.toString().padLeft(2, '0')}.'
           '${_selectedDate.year}';
  }

  // -------------------------------------------------------------------------
  // Map callbacks
  // -------------------------------------------------------------------------

  void _onMapCreated(MapLibreMapController controller) {
    _mapController = controller;
  }

  void _setMapCanvasInteractive(bool interactive) {
    final pe = interactive ? '' : 'none';
    html.document.querySelectorAll('.maplibregl-canvas-container').forEach((e) {
      e.style.pointerEvents = pe;
    });
  }

  Future<void> _onStyleLoaded() async {
    _mapReady = true;
    _shadowLayersReady    = false;
    _pinLayerReady        = false;
    _myLocationLayerReady = false;
    _sunnySpotsLayerReady = false;
    _injectAttributionCss();
    _loadSaved();
    fetchShadows();
    _initGpsOnStart();
    _fetchWeather(_currentCenter.latitude, _currentCenter.longitude);
  }

  void _injectAttributionCss() {
    final style = html.StyleElement();
    style.text = '.maplibregl-ctrl-bottom-right { padding-right: 4px !important; }'
        '.maplibregl-ctrl-attrib { font-size: 10px !important; }';
    html.document.head!.append(style);
  }

  void _onCameraIdle() {
    if (_mapController == null) return;
    final center = _mapController!.cameraPosition?.target;
    if (center == null) return;
    _currentCenter = center;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), fetchShadows);
  }

  void _onMapClick(Point<double> point, LatLng coordinates) {
    if (_ignoreNextMapClick) {
      _ignoreNextMapClick = false;
      return;
    }
    // Reject clicks in the panel/toggle zone (desktop only)
    final panelZone = _isMobile ? 0.0 : (_panelOpen ? 300.0 : 22.0);
    if (panelZone > 0 && point.x > _screenWidth - panelZone) return;
    if (_searchResults.isNotEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() {
      _clickedPoint      = coordinates;
      _pointInfo         = null;
      _pointInfoLoading  = true;
    });
    _showPin(coordinates);
    _fetchPointInfo(coordinates);
  }

  Future<void> _fetchPointInfo(LatLng point) async {
    try {
      final d       = _selectedDate;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
      final uri     = Uri.parse(
        '$flaskBaseUrl/point_info'
        '?lat=${point.latitude}&lon=${point.longitude}'
        '&date=$dateStr&hour=${_hour.toInt()}&minute=${((_hour * 60).toInt() % 60)}',
      );
      final resp = await http.get(uri);
      if (mounted && resp.statusCode == 200) {
        setState(() {
          _pointInfo        = jsonDecode(resp.body) as Map<String, dynamic>;
          _pointInfoLoading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isMobile) {
            setState(() => _mobileTab = 2);
          } else if (_panelScroll.hasClients) {
            _panelScroll.animateTo(
              _panelScroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _pointInfoLoading = false);
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

    setState(() => _findingSunnySpots = true);
    try {
      final bounds = await ctrl.getVisibleRegion();
      final zoom   = ctrl.cameraPosition?.zoom ?? 15.0;
      final h      = _hour.toInt();
      final min    = ((_hour * 60).toInt() % 60);
      final date   = _selectedDate;

      final uri = Uri.parse(
        '$flaskBaseUrl/find_sunny_spots'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=$h&minute=$min'
        '&month=${date.month}&day=${date.day}'
        '&zoom=${zoom.round()}'
        '&minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}'
        '&n=5',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      final data     = jsonDecode(response.body) as Map<String, dynamic>;
      final spots    = (data['spots'] as List<dynamic>? ?? [])
          .map((s) => <String, dynamic>{
                'lat':            (s['lat']  as num).toDouble(),
                'lon':            (s['lon']  as num).toDouble(),
                'sun_hours_left': (s['sun_hours_left'] as num?)?.toInt() ?? 0,
                'sun_until':      s['sun_until'] as int?,
              })
          .toList();

      setState(() => _sunnySpots = spots);
      _geocodeSpots(spots);
      await _showSunnySpotMarkers(spots);

      if (spots.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (_isMobile) {
          setState(() => _mobileTab = 1);
        } else if (_panelScroll.hasClients) {
          _panelScroll.animateTo(
            _panelScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          );
        }
      }
    } catch (_) {
      _showError('Could not find sunny spots');
    } finally {
      if (mounted) setState(() => _findingSunnySpots = false);
    }
  }

  Future<void> _showSunnySpotMarkers(List<Map<String, dynamic>> spots) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final features = spots.asMap().entries.map((e) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [e.value['lon'], e.value['lat']],
      },
      'properties': {'index': e.key + 1},
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
          circleColor: '#FFD700',
          circleOpacity: 0.25,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'sunny-spots', 'sunny-spots-dot',
        CircleLayerProperties(
          circleRadius: 8,
          circleColor: '#FFD700',
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
    setState(() => _sunnySpots = []);
    if (!_sunnySpotsLayerReady) return;
    await _mapController?.setGeoJsonSource(
        'sunny-spots', {'type': 'FeatureCollection', 'features': []});
  }

  // -------------------------------------------------------------------------
  // Saved spots — localStorage persistence
  // -------------------------------------------------------------------------

  void _loadSaved() {
    try {
      final raw = html.window.localStorage['sunspot_saved'];
      if (raw != null) {
        setState(() {
          _savedSpots = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
  }

  void _persistSaved() {
    html.window.localStorage['sunspot_saved'] = jsonEncode(_savedSpots);
  }

  // -------------------------------------------------------------------------
  // Weather (Open-Meteo, no API key)
  // -------------------------------------------------------------------------

  Future<void> _fetchWeather(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code,uv_index'
        '&timezone=auto',
      );
      final res = await http.get(uri);
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _weatherData = data['current'] as Map<String, dynamic>?);
      }
    } catch (_) {}
  }

  String _weatherEmoji(int code) {
    if (code == 0)           return '☀️';
    if (code <= 3)           return '⛅';
    if (code <= 48)          return '🌫️';
    if (code <= 67)          return '🌧️';
    if (code <= 77)          return '❄️';
    if (code <= 82)          return '🌦️';
    return                          '⛈️';
  }

  Color _uvColor(num uv) {
    if (uv <= 2)  return Colors.green;
    if (uv <= 5)  return Colors.yellow.shade700;
    if (uv <= 7)  return Colors.orange;
    if (uv <= 10) return Colors.red;
    return                Colors.purple;
  }

  Widget _buildWeatherWidget() {
    final data = _weatherData;
    if (data == null) return const SizedBox.shrink();
    final temp    = (data['temperature_2m'] as num?)?.round() ?? 0;
    final code    = (data['weather_code']   as num?)?.toInt() ?? 0;
    final uv      = (data['uv_index']       as num?) ?? 0;
    final uvInt   = uv.round();
    final emoji   = _weatherEmoji(code);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 5),
          Text('$temp°',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('UV $uvInt',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700)),
          const SizedBox(width: 3),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: _uvColor(uv),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Reverse geocoding (Nominatim)
  // -------------------------------------------------------------------------

  Future<void> _geocodeSpots(List<Map<String, dynamic>> spots) async {
    for (final spot in spots) {
      final lat = spot['lat'] as double;
      final lon = spot['lon'] as double;
      await _reverseGeocode(lat, lon);
      await Future.delayed(const Duration(milliseconds: 300)); // respect Nominatim rate limit
    }
  }

  Future<String> _reverseGeocode(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    if (_spotAddresses.containsKey(key)) return _spotAddresses[key]!;
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json',
      );
      final res = await http.get(uri, headers: {'User-Agent': 'Sunspot.me/1.0'});
      if (res.statusCode != 200) return '';
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = data['address'] as Map<String, dynamic>?;
      String label = '';
      if (addr != null) {
        final road = (addr['road'] ?? addr['pedestrian'] ?? addr['path'] ?? '') as String;
        final num  = (addr['house_number'] ?? '') as String;
        label = num.isNotEmpty ? '$road $num' : road;
      }
      if (label.isEmpty) {
        label = ((data['display_name'] as String?) ?? '').split(',').first.trim();
      }
      if (mounted) setState(() => _spotAddresses[key] = label);
      return label;
    } catch (_) {
      return '';
    }
  }

  // -------------------------------------------------------------------------
  // Spot bottom sheet
  // -------------------------------------------------------------------------

  void _showSpotSheet(Map<String, dynamic> spot, int idx) {
    final lat         = spot['lat'] as double;
    final lon         = spot['lon'] as double;
    final key         = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    final address     = _spotAddresses[key] ?? 'Sunny spot ${idx + 1}';
    final sunHoursLeft = spot['sun_hours_left'] as int;
    final sunUntil    = spot['sun_until'] as int?;
    final gps         = _gpsPosition;
    final distLabel   = gps != null
        ? _formatDistance(_distanceMeters(gps, LatLng(lat, lon)))
        : null;

    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lon), 17.5));

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFFFFF8F0),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final isSaved = _savedSpots.any(
              (s) => s['lat'] == lat && s['lon'] == lon);
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 36, height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade200,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Address + meta
                Text(address,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(children: [
                  if (distLabel != null) ...[
                    Icon(Icons.directions_walk, size: 13, color: Colors.grey.shade500),
                    const SizedBox(width: 3),
                    Text(distLabel,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                    const SizedBox(width: 10),
                  ],
                  Icon(Icons.wb_sunny_outlined, size: 13, color: Colors.orange.shade400),
                  const SizedBox(width: 3),
                  Text(
                    sunUntil != null
                        ? '$sunHoursLeft h · until ${sunUntil.toString().padLeft(2, '0')}:00'
                        : '$sunHoursLeft h of sun',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                  ),
                ]),
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
                      setState(() {
                        if (isSaved) {
                          _savedSpots.removeWhere(
                              (s) => s['lat'] == lat && s['lon'] == lon);
                        } else {
                          _savedSpots.add({
                            'lat': lat,
                            'lon': lon,
                            'address': address,
                            'sun_hours_left': sunHoursLeft,
                            'sun_until': sunUntil,
                          });
                        }
                        _persistSaved();
                      });
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
                      final link =
                          'https://coruscating-fenglisu-505ed3.netlify.app/'
                          '?server=${Uri.encodeComponent(server)}'
                          '&lat=$lat&lon=$lon';
                      await Clipboard.setData(ClipboardData(text: link));
                      Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Link copied to clipboard'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
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
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Geolocation
  // -------------------------------------------------------------------------

  Future<LatLng?> _getGpsPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        final req = await Geolocator.requestPermission();
        if (req == LocationPermission.denied ||
            req == LocationPermission.deniedForever) {
          _showError('GPS: permission denied');
          return null;
        }
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 20));
      return LatLng(pos.latitude, pos.longitude);
    } on TimeoutException {
      _showError('GPS: location timed out — try again');
      return null;
    } catch (e) {
      _showError('GPS: ${e.toString().split('\n').first}');
      return null;
    }
  }

  Future<void> _initGpsOnStart() async {
    final newPos = await _getGpsPosition();
    if (newPos == null || !mounted) return;
    setState(() {
      _gpsPosition   = newPos;
      _currentCenter = newPos;
    });
    _fetchWeather(newPos.latitude, newPos.longitude);
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: newPos, zoom: 15.0)),
    );
    await _showMyLocationDot(newPos);
  }

  void _goToMyLocation() async {
    final newPos = await _getGpsPosition();
    if (newPos == null || !mounted) return;
    setState(() {
      _gpsPosition   = newPos;
      _currentCenter = newPos;
    });
    final zoom = _mapController?.cameraPosition?.zoom ?? 16.0;
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: newPos, zoom: zoom)),
    );
    await _showMyLocationDot(newPos);
    fetchShadows();
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

  void _showError(String msg) {
    setState(() => _errorMessage = msg);
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) setState(() => _errorMessage = null);
    });
  }

  // -------------------------------------------------------------------------
  // Shadow fetch
  // -------------------------------------------------------------------------

  Future<void> fetchShadows() async {
    if (!_mapReady || _mapController == null) return;

    _activeEventSource?.close();
    _activeEventSource = null;
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

    // Only show the pill if loading takes longer than 150ms (skips cached hits)
    _pillTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _loading) setState(() => _showPill = true);
    });

    try {
      final bounds   = await _mapController!.getVisibleRegion();
      final rawZoom  = _mapController!.cameraPosition?.zoom ?? 15.0;
      final zoom     = rawZoom.toInt();

      // Below zoom 11.5, building shadows are too fragmented — clear and skip.
      if (rawZoom < 11.5) {
        if (_shadowLayersReady) {
          final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': <dynamic>[]};
          await _mapController!.setGeoJsonSource('dark-area', empty);
        }
        _pillTimer?.cancel();
        if (mounted) setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
        if (!completer.isCompleted) completer.complete();
        return;
      }

      if (_shadowLayersReady && _lastFetchZoom != -1 && zoom != _lastFetchZoom) {
        final zoomDelta = (zoom - _lastFetchZoom).abs();
        if (zoomDelta >= 2) {
          // Large jump — old rectangle looks obviously wrong: clear it.
          final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': <dynamic>[]};
          await _mapController!.setGeoJsonSource('dark-area', empty);
        } else {
          // Small step — keep old shadow visible but dim it to signal stale data.
          await _mapController!.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillColor: '#4a6d8a', fillOpacity: 0.15));
          await _mapController!.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: 0.10));
          await _mapController!.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillColor: '#2d4862', fillOpacity: 0.08));
        }
      }

      _lastFetchZoom = zoom;

      final uri = Uri.parse(
        '$flaskBaseUrl/shadow/stream'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=${_hour.toInt()}'
        '&minute=${((_hour * 60).toInt() % 60)}'
        '&month=${_selectedDate.month}'
        '&day=${_selectedDate.day}'
        '&zoom=$zoom'
        '&minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}',
      );

      final es = html.EventSource(uri.toString());
      _activeEventSource = es;

      es.onMessage.listen((event) async {
        if (gen != _fetchGen) { es.close(); return; }

        final data  = jsonDecode(event.data as String) as Map<String, dynamic>;
        final pct   = (data['progress'] as num?)?.toDouble() ?? 0.0;
        final stage = data['stage'] as String? ?? '';

        if (mounted) setState(() {
          _loadingProgress = pct / 100.0;
          _loadingStage    = stage;
        });

        if (data.containsKey('result')) {
          es.close();
          _activeEventSource = null;
          final result  = data['result'] as Map<String, dynamic>;
          final elev    = (result['elevation'] as num?)?.toDouble() ?? 0.0;
          final azim    = (result['azimuth']   as num?)?.toDouble() ?? 0.0;
          final srHour  = (result['sunrise']   as num?)?.toDouble();
          final ssHour  = (result['sunset']    as num?)?.toDouble();
          if (result['dark_area'] != null) {
            await _updateMapLayers(result['dark_area'] as Map<String, dynamic>, elev);
          }
          _pillTimer?.cancel();
          if (mounted) {
            setState(() {
              _elevation   = elev;
              _azimuth     = azim;
              _sunriseHour = srHour;
              _sunsetHour  = ssHour;
              // Clamp current hour to daylight window
              if (srHour != null && ssHour != null) {
                _hour = _hour.clamp(srHour, ssHour);
              }
              _loading     = false;
              _showPill    = false;
            });
          }
          if (!completer.isCompleted) completer.complete();
        }

        if (data.containsKey('error')) {
          es.close();
          _activeEventSource = null;
          _pillTimer?.cancel();
          _showError(data['error'] as String? ?? 'Server error');
          if (mounted) {
            setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
          }
          if (!completer.isCompleted) completer.complete();
        }
      });

      es.onError.listen((_) {
        if (gen != _fetchGen) return;
        es.close();
        _activeEventSource = null;
        _pillTimer?.cancel();
        _showError('Could not load shadows — is the server running?');
        if (mounted) setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
        if (!completer.isCompleted) completer.complete();
      });

      return completer.future;

    } catch (e) {
      debugPrint('Fetch error: $e');
      _showError('Could not load shadows — is the server running?');
      if (mounted) setState(() { _loading = false; _loadingProgress = 0.0; });
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<void> _updateMapLayers(Map<String, dynamic> geoJson, double elevation) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final t   = elevation <= 0 ? 1.0 : (elevation.clamp(0.0, 60.0) / 60.0);
    final opL0 = elevation <= 0 ? 0.82 : 0.20 + t * 0.10;
    final opL1 = elevation <= 0 ? 0.0  : 0.22 + t * 0.13;
    final opL2 = elevation <= 0 ? 0.0  : 0.24 + t * 0.16;

    if (_shadowLayersReady) {
      // Update source data + opacity in-place — no remove/re-add, no flicker
      await ctrl.setGeoJsonSource('dark-area', geoJson);
      await ctrl.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillColor: '#4a6d8a', fillOpacity: opL0));
      await ctrl.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: opL1));
      await ctrl.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillColor: '#2d4862', fillOpacity: opL2));
      return;
    }

    // First time (or after style reload): create source and layers
    await ctrl.addSource('dark-area', GeojsonSourceProperties(data: geoJson));

    // Three concentric rings — topo-map style shadow density:
    //   l0 (widest)  → light tint, shadow edges
    //   l1 (middle)  → medium, stacks on l0
    //   l2 (core)    → darkest, stacks on l0+l1
    // Result: edge zones ≈ 0.25 opacity, deep shadow cores ≈ 0.65 opacity.
    await ctrl.addLayer(
      'dark-area', 'shadow-l0-fill',
      FillLayerProperties(fillColor: '#4a6d8a', fillOpacity: opL0),
      filter: ['==', ['get', 'layer'], 'shadow-l0'],
      enableInteraction: false,
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l1-fill',
      FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: opL1),
      filter: ['==', ['get', 'layer'], 'shadow-l1'],
      enableInteraction: false,
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l2-fill',
      FillLayerProperties(fillColor: '#2d4862', fillOpacity: opL2),
      filter: ['==', ['get', 'layer'], 'shadow-l2'],
      enableInteraction: false,
    );
    _shadowLayersReady = true;
  }

  // -------------------------------------------------------------------------
  // Animation
  // -------------------------------------------------------------------------

  void _toggle24h() {
    if (_animating) {
      setState(() => _animating = false);
      return;
    }
    final start = _sunriseHour ?? 6.0;
    setState(() {
      _animating = true;
      _liveMode = false;
      _hour = start;
    });
    _run24hStep();
  }

  Future<void> _run24hStep() async {
    if (!_animating) return;
    await fetchShadows();
    await Future.delayed(const Duration(milliseconds: 400));
    if (!_animating) return;
    final end = _sunsetHour ?? 20.0;
    if (_hour >= end) {
      setState(() => _animating = false);
      return;
    }
    setState(() => _hour = _hour + 1.0);
    _run24hStep();
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
        _selectedDate = DateTime.now();
        final now = DateTime.now();
        _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
      });
      fetchShadows();
      _liveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted || !_liveMode) return;
        setState(() {
          final now = DateTime.now();
          _selectedDate = now;
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
    _searchDebounce?.cancel();
    _liveTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _panelScroll.dispose();
    _mobileContentScroll.dispose();
    _sunSpinCtrl.dispose();
    _activeEventSource?.close();
    if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
      _fetchCompleter!.complete();
    }
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Address search (Nominatim)
  // -------------------------------------------------------------------------

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _runSearch(query.trim()));
  }

  Future<void> _runSearch(String query) async {
    setState(() => _searchLoading = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}&format=json&limit=5&addressdetails=1',
      );
      final resp = await http.get(uri, headers: {'User-Agent': 'Sunspot.me/1.0'});
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as List;
        setState(() => _searchResults = data.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // silently ignore network errors during search
    } finally {
      setState(() => _searchLoading = false);
    }
  }

  void _selectSearchResult(Map<String, dynamic> result) {
    final lat = double.parse(result['lat'] as String);
    final lon = double.parse(result['lon'] as String);
    final name = result['display_name'] as String;
    final target = LatLng(lat, lon);
    _searchController.text = name.split(',').first.trim();
    setState(() {
      _searchResults = [];
      _currentCenter = target;
    });
    _searchFocus.unfocus();
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 16.0)),
    );
    fetchShadows();
    _fetchWeather(target.latitude, target.longitude);
  }

  @override
  Widget build(BuildContext context) {
    _screenWidth  = MediaQuery.of(context).size.width;
    _screenHeight = MediaQuery.of(context).size.height;
    final isMobile = _isMobile;
    final panelRightPad = isMobile ? 0 : ((_panelOpen ? 280 : 0));

    // Map area — used as Expanded child on mobile, full Scaffold body on desktop
    final mapArea = Stack(
      children: [
        AbsorbPointer(
          absorbing: _draggingSlider,
          child: MapLibreMap(
            styleString: mapStyle,
            initialCameraPosition: CameraPosition(target: _currentCenter, zoom: 13.0),
            onMapCreated:          _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle:          _onCameraIdle,
            onMapClick:            _onMapClick,
            trackCameraPosition:   true,
            compassEnabled:        false,
          ),
        ),

        // Search bar
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          top: 12, left: 12, right: isMobile ? 12 : (_panelOpen ? 292 : 12),
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
                    if (_searchLoading)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange.shade400)),
                      )
                    else if (_searchController.text.isNotEmpty)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () { _searchController.clear(); setState(() => _searchResults = []); },
                          child: Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Icon(Icons.close, color: Colors.grey.shade400, size: 18),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_searchResults.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _searchResults.asMap().entries.map((entry) {
                      final i      = entry.key;
                      final result = entry.value;
                      final parts  = (result['display_name'] as String).split(',');
                      final title  = parts.first.trim();
                      final sub    = parts.length > 1 ? parts.skip(1).take(2).map((s) => s.trim()).join(', ') : '';
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (i > 0) Divider(height: 1, color: Colors.grey.shade100),
                          InkWell(
                            onTap: () => _selectSearchResult(result),
                            mouseCursor: SystemMouseCursors.click,
                            borderRadius: BorderRadius.vertical(
                              top:    i == 0 ? const Radius.circular(12) : Radius.zero,
                              bottom: i == _searchResults.length - 1 ? const Radius.circular(12) : Radius.zero,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  Icon(Icons.location_on_outlined, size: 16, color: Colors.grey.shade500),
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
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
            ],
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

        // Weather widget — top-right, below search bar
        Positioned(
          top: 64, right: 12,
          child: _buildWeatherWidget(),
        ),

        // Loading pill
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          bottom: 24, left: 0, right: panelRightPad.toDouble(),
          child: Center(child: _buildLoadingPill()),
        ),

        // GPS button — right side; Listener blocks map-click from firing underneath
        Positioned(
          bottom: 68, right: 16,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: FloatingActionButton.small(
              onPressed: _goToMyLocation,
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 2,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _loading
                    ? RotationTransition(key: const ValueKey('spin'), turns: _sunSpinCtrl,
                        child: const Icon(Icons.wb_sunny, size: 20, color: Colors.orange))
                    : const Icon(Icons.my_location, size: 20, key: ValueKey('loc')),
              ),
            ),
          ),
        ),

        // Zoom buttons — left side
        Positioned(
          bottom: 50, left: 16,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: Column(
              children: [
                _buildZoomButton(Icons.add, () async {
                  final cam = _mapController?.cameraPosition;
                  if (cam == null) return;
                  await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                      CameraPosition(target: cam.target, zoom: (cam.zoom + 1).clamp(1, 20))));
                }),
                const SizedBox(height: 4),
                _buildZoomButton(Icons.remove, () async {
                  final cam = _mapController?.cameraPosition;
                  if (cam == null) return;
                  await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                      CameraPosition(target: cam.target, zoom: (cam.zoom - 1).clamp(1, 20))));
                }),
              ],
            ),
          ),
        ),

        // Error banner
        if (_errorMessage != null)
          Positioned(
            bottom: 80, left: 16,
            right: isMobile ? 16 : (_panelOpen ? 296 : 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(8)),
              child: Text(_errorMessage!, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),

        // Desktop panel
        if (!isMobile) ...[
          Positioned(
            top: 0, right: 0, bottom: 0, width: 280,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _setMapCanvasInteractive(false),
              onPointerUp:   (_) => _setMapCanvasInteractive(true),
              onPointerCancel: (_) => _setMapCanvasInteractive(true),
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                offset: _panelOpen ? Offset.zero : const Offset(1.0, 0),
                child: _buildPanel(),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            top: 0, bottom: 0,
            right: _panelOpen ? 280 : 0,
            width: 36,
            child: Align(
              alignment: Alignment.center,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _panelOpen = !_panelOpen),
                  child: Container(
                    width: 36, height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 6, offset: const Offset(-2, 0))],
                    ),
                    child: Icon(_panelOpen ? Icons.chevron_right : Icons.chevron_left,
                        size: 20, color: Colors.grey.shade600),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );

    return Scaffold(
      body: isMobile
          ? Column(
              children: [
                Expanded(child: mapArea),
                _buildMobileBottom(),
              ],
            )
          : mapArea,
    );
  }

  Widget _buildZoomButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          width: 36, height: 36,
          child: Icon(icon, size: 20, color: Colors.black87),
        ),
      ),
    );
  }

  Widget _buildLoadingPill() {
    return AnimatedOpacity(
      opacity: _showPill ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      child: IgnorePointer(
        ignoring: !_showPill,
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
                    _loadingStage.isEmpty ? 'Loading…' : _loadingStage,
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
                    value: _loadingProgress > 0 ? _loadingProgress : null,
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

  Widget _buildPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          controller: _panelScroll,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTimeHeader(),
              const SizedBox(height: 4),
              _buildTimeSlider(),
              const SizedBox(height: 16),
              _buildDateSection(),
              const Divider(height: 28),
              _buildSunPosition(),
              const Divider(height: 28),
              _buildFindSunnySpotsSection(),
              const Divider(height: 28),
              if (_clickedPoint != null)
                _buildPointInfoCard()
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app_outlined, size: 15, color: Colors.grey.shade400),
                      const SizedBox(width: 6),
                      Text('Tap the map to inspect a point',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Time header ----
  Widget _buildTimeHeader() {
    return Row(
      children: [
        Icon(_timePeriodIcon, color: Colors.orange, size: 18),
        const SizedBox(width: 6),
        Text(_timePeriod,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.grey, letterSpacing: 1.2)),
        const Spacer(),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: _hour, end: _hour),  // begin=_hour: no sweep-from-midnight on load; subsequent changes animate from current value
          duration: const Duration(milliseconds: 350),
          builder: (context, value, _) {
            return Text(
              _formatDisplayHour(value),
              style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold,
                color: _draggingSlider ? Colors.orange : Colors.black87,
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

    final sliderColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.orange,
            inactiveTrackColor: Colors.orange.shade100,
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayColor: Colors.orange.withValues(alpha: 0.2),
          ),
          child: Slider(
            value: sliderVal,
            min: minH, max: maxH, divisions: divisions,
            onChangeStart: (_) {
              _liveTimer?.cancel();
              setState(() { _draggingSlider = true; _liveMode = false; });
              _setMapPointerEvents(false);
            },
            onChanged:   (v) => setState(() => _hour = v),
            onChangeEnd: (_) {
              setState(() => _draggingSlider = false);
              _setMapPointerEvents(true);
              fetchShadows();
            },
          ),
        ),
        // Labels: sunrise · (noon) · sunset
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.wb_sunny_outlined, size: 9, color: Colors.orange.shade400),
                const SizedBox(width: 2),
                Text(_formatSliderHour(minH),
                    style: TextStyle(fontSize: 10, color: Colors.orange.shade700, fontWeight: FontWeight.w600)),
              ]),
              if (noonInRange)
                const Text('12 PM', style: TextStyle(fontSize: 10, color: Colors.grey)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.nightlight_round, size: 9, color: Colors.blueGrey.shade400),
                const SizedBox(width: 2),
                Text(_formatSliderHour(maxH),
                    style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade500, fontWeight: FontWeight.w600)),
              ]),
            ],
          ),
        ),
      ],
    );

    // LIVE left · slider · 24h right
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // LIVE button
        GestureDetector(
          onTap: _toggleLiveMode,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _liveMode ? Colors.red.shade400 : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_liveMode)
                  Container(
                    width: 6, height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  ),
                Text('LIVE', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: _liveMode ? Colors.white : Colors.black54,
                  letterSpacing: 0.5,
                )),
              ],
            ),
          ),
        ),
        // Slider in the middle
        Expanded(child: sliderColumn),
        // 24h button
        GestureDetector(
          onTap: _toggle24h,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _animating ? Colors.orange : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _animating ? Icons.stop : Icons.play_arrow,
                  size: 13,
                  color: _animating ? Colors.white : Colors.black54,
                ),
                const SizedBox(width: 3),
                Text('24h', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: _animating ? Colors.white : Colors.black54,
                )),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatSliderHour(double hour) {
    final h = hour.toInt().clamp(0, 23);
    final m = ((hour - h) * 60).round();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  // ---- Point info popup ----
  Widget _buildPointInfoCard() {
    final info = _pointInfo;
    final inShadow = info == null ? true : (info['in_shadow'] as bool? ?? true);
    final sunCount = info == null ? 0 : (info['sun_hours_count'] as int? ?? 0);
    final periods  = info == null ? <dynamic>[] : (info['sun_periods'] as List<dynamic>? ?? []);

    String fmt(int h) => '${h.toString().padLeft(2, '0')}:00';

    final statusColor = inShadow ? const Color(0xFF2d4862) : const Color(0xFFFF8C00);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          // Header row — same style as other section headers
          Row(
            children: [
              Icon(
                inShadow ? Icons.nights_stay_outlined : Icons.wb_sunny,
                color: statusColor, size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                _pointInfoLoading
                    ? 'Checking…'
                    : inShadow ? 'In Shadow' : 'In Sun',
                style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: statusColor, letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    _ignoreNextMapClick = true;
                    _hidePin();
                    setState(() {
                      _clickedPoint = null;
                      _pointInfo    = null;
                    });
                  },
                  child: Icon(Icons.close, color: Colors.grey.shade400, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_pointInfoLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
              ),
            )
          else ...[
            Row(
              children: [
                const Icon(Icons.wb_sunny_outlined, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Text(
                  sunCount == 0
                      ? 'No direct sun today'
                      : '$sunCount hour${sunCount == 1 ? '' : 's'} of direct sun today',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (periods.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6, runSpacing: 4,
                children: periods.map((p) {
                  final from = p['from'] as int;
                  final to   = p['to']   as int;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Text(
                      '${fmt(from)} – ${fmt(to)}',
                      style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                    ),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '${_clickedPoint!.latitude.toStringAsFixed(5)}°, '
              '${_clickedPoint!.longitude.toStringAsFixed(5)}°',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
            ),
          ],
        ],
      );
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

  // ---- Find sunny spots ----
  Widget _buildFindSunnySpotsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _findingSunnySpots ? null : _findSunnySpots,
                icon: _findingSunnySpots
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.wb_sunny, size: 16),
                label: Text(_findingSunnySpots ? 'Searching...' : 'Find sunny spots'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.orange.shade200,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            if (_sunnySpots.isNotEmpty) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: _clearSunnySpots,
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Clear spots',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.grey.shade100,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                padding: const EdgeInsets.all(10),
              ),
            ],
          ],
        ),
        if (_sunnySpots.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._sunnySpots.asMap().entries.map((e) {
            final idx          = e.key;
            final spot         = e.value;
            final spotPos      = LatLng(spot['lat'] as double, spot['lon'] as double);
            final sunHoursLeft = spot['sun_hours_left'] as int;
            final sunUntil     = spot['sun_until'] as int?;

            // Distance from GPS fix (if available)
            final gps = _gpsPosition;
            final distLabel = gps != null
                ? _formatDistance(_distanceMeters(gps, spotPos))
                : null;

            // "Sun until HH:00" label
            final sunUntilLabel = sunUntil != null
                ? 'until ${sunUntil.toString().padLeft(2, '0')}:00'
                : null;

            final addrKey = '${spotPos.latitude.toStringAsFixed(6)},${spotPos.longitude.toStringAsFixed(6)}';
            final address = _spotAddresses[addrKey] ?? 'Sunny spot ${idx + 1}';
            final isSaved = _savedSpots.any(
                (s) => s['lat'] == spotPos.latitude && s['lon'] == spotPos.longitude);

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _showSpotSheet(spot, idx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 22, height: 22,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFFD700),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${idx + 1}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                address,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  if (distLabel != null) ...[
                                    Icon(Icons.directions_walk, size: 11,
                                        color: Colors.grey.shade500),
                                    const SizedBox(width: 2),
                                    Text(distLabel,
                                        style: TextStyle(
                                            fontSize: 11, color: Colors.grey.shade600)),
                                    const SizedBox(width: 8),
                                  ],
                                  Icon(Icons.wb_sunny_outlined, size: 11,
                                      color: Colors.orange.shade400),
                                  const SizedBox(width: 2),
                                  Text(
                                    sunUntilLabel != null
                                        ? '$sunHoursLeft h · $sunUntilLabel'
                                        : '$sunHoursLeft h left',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.orange.shade700),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (isSaved)
                          Icon(Icons.favorite, size: 14, color: Colors.red.shade300),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, size: 16, color: Colors.orange.shade300),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ],
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

  // ---- Sun position ----
  Widget _buildSunPosition() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SUN POSITION',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.grey, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _sunCard(
            label: 'ELEVATION',
            icon: Icons.trending_up,
            value: '${_elevation.toStringAsFixed(1)}°',
          )),
          const SizedBox(width: 8),
          Expanded(child: _sunCard(
            label: 'AZIMUTH',
            icon: Icons.explore_outlined,
            value: '${_azimuth.toStringAsFixed(0)}° ${_azimuthDirection(_azimuth)}',
          )),
        ]),
      ],
    );
  }

  Widget _sunCard({required String label, required IconData icon, required String value}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 12, color: Colors.grey),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: Colors.grey,
                    fontWeight: FontWeight.w600, letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // =========================================================================
  // Mobile bottom UI — separated from map (no overlap = no panning conflict)
  // =========================================================================

  Widget _buildMobileBottom() {
    const tabs = [
      (Icons.access_time,       'Time'),
      (Icons.wb_sunny_outlined, 'Spots'),
      (Icons.info_outline,      'Info'),
      (Icons.favorite_outline,  'Saved'),
    ];
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Content area — fade at bottom signals more content below
            SizedBox(
              height: (_screenHeight * 0.30 - 56).clamp(160.0, 260.0),
              child: ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.white.withValues(alpha: 0.0)],
                  stops: const [0.0, 0.75, 1.0],
                ).createShader(bounds),
                blendMode: BlendMode.dstIn,
                child: SingleChildScrollView(
                  controller: _mobileContentScroll,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: _buildMobileTabContent(),
                ),
              ),
            ),
            // Tab bar
            Divider(height: 1, color: Colors.grey.shade200),
            SizedBox(
              height: 56,
              child: Row(
                children: tabs.asMap().entries.map((entry) {
                  final i     = entry.key;
                  final icon  = entry.value.$1;
                  final label = entry.value.$2;
                  final sel   = _mobileTab == i;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _mobileTab = i);
                        _mobileContentScroll.jumpTo(0);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: sel ? Colors.orange.withValues(alpha: 0.12) : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(icon, size: 22,
                                color: sel ? Colors.orange : Colors.grey.shade400),
                          ),
                          const SizedBox(height: 1),
                          Text(label,
                              style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w600,
                                color: sel ? Colors.orange : Colors.grey.shade400,
                              )),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileTabContent() {
    switch (_mobileTab) {
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
      case 2: // Info
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSunPosition(),
            const Divider(height: 28),
            if (_clickedPoint != null)
              _buildPointInfoCard()
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.touch_app_outlined, size: 15,
                        color: Colors.grey.shade400),
                    const SizedBox(width: 6),
                    Text('Tap the map to inspect a point',
                        style: TextStyle(fontSize: 12,
                            color: Colors.grey.shade400)),
                  ],
                ),
              ),
          ],
        );
      case 3: // Saved
        if (_savedSpots.isEmpty) {
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
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._savedSpots.asMap().entries.map((e) {
              final idx  = e.key;
              final s    = e.value;
              final lat  = s['lat'] as double;
              final lon  = s['lon'] as double;
              final addr = s['address'] as String? ?? 'Saved spot ${idx + 1}';
              final sunH = s['sun_hours_left'] as int? ?? 0;
              final until = s['sun_until'] as int?;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _mapController?.animateCamera(
                          CameraUpdate.newLatLngZoom(LatLng(lat, lon), 17.5));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade100),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.favorite, size: 16, color: Colors.red.shade300),
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
                                Text(
                                  until != null
                                      ? '$sunH h · until ${until.toString().padLeft(2, '0')}:00'
                                      : '$sunH h of sun',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.orange.shade700),
                                ),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() {
                              _savedSpots.removeAt(idx);
                              _persistSaved();
                            }),
                            child: Icon(Icons.close, size: 16, color: Colors.grey.shade400),
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
