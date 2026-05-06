import 'dart:convert';
import 'package:http/http.dart' as http;

/// Centralised HTTP layer for all Sunspot API + third-party calls.
/// All methods return decoded data or null/throw — no setState, no BuildContext.
class ApiClient {
  final String baseUrl;
  const ApiClient(this.baseUrl);

  // ---------------------------------------------------------------------------
  // Flask server
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> fetchPointInfo(
    double lat, double lon, String date, int hour, int minute,
  ) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/point_info?lat=$lat&lon=$lon&date=$date&hour=$hour&minute=$minute',
      );
      final resp = await http.get(uri);
      if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {}
    return null;
  }

  Future<bool?> isSunny(
    double lat, double lon, String date, int hour, int minute,
  ) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/is_sunny?lat=$lat&lon=$lon&date=$date&hour=$hour&minute=$minute',
      );
      final res = await http.get(uri);
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['sunny'] as bool?;
    } catch (_) {}
    return null;
  }

  /// Single attempt — retry loop stays in caller (needs setState for progress).
  Future<Map<String, dynamic>> fetchShadowMeta(
    double lat, double lon, int hour, int minute, int month, int day,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/shadow/meta?lat=$lat&lon=$lon'
      '&hour=$hour&minute=$minute&month=$month&day=$day',
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) throw Exception('shadow/meta HTTP ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> findSunnySpots({
    required double lat, required double lon,
    required double minLat, required double minLon,
    required double maxLat, required double maxLon,
    required int hour, required int minute,
    required int month, required int day,
    required int zoom, int n = 8,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/find_sunny_spots?lat=$lat&lon=$lon'
      '&hour=$hour&minute=$minute&month=$month&day=$day'
      '&minLat=$minLat&minLon=$minLon&maxLat=$maxLat&maxLon=$maxLon'
      '&zoom=$zoom&n=$n',
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    return null;
  }

  /// findSunnySpots without viewport bounds — used for tour building.
  Future<Map<String, dynamic>?> findSunnySpotsUnbounded({
    required double lat, required double lon,
    required int hour, required int minute,
    required int month, required int day,
    int n = 8,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/find_sunny_spots?lat=$lat&lon=$lon'
      '&hour=$hour&minute=$minute&month=$month&day=$day&n=$n',
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    return null;
  }

  Future<Map<String, dynamic>?> findSunnyPois({
    required double lat, required double lon,
    required double minLat, required double minLon,
    required double maxLat, required double maxLon,
    required int hour, required int minute, required String date,
    required String types, required int zoom,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/sunny_pois?lat=$lat&lon=$lon'
      '&minLat=$minLat&minLon=$minLon&maxLat=$maxLat&maxLon=$maxLon'
      '&hour=$hour&minute=$minute&date=$date&types=$types&zoom=$zoom',
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    return null;
  }

  /// Returns true if the tile was fetched successfully (used by 24h preloader).
  Future<bool> fetchTile(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fire-and-forget tile cache warm.
  void warmTile(String url) {
    http.get(Uri.parse(url))
        .timeout(const Duration(seconds: 30))
        .catchError((_) => http.Response('', 0));
  }

  // ---------------------------------------------------------------------------
  // Third-party
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> fetchWeather(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code,uv_index,cloud_cover'
        '&timezone=auto',
      );
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['current'] as Map<String, dynamic>?;
      }
    } catch (_) {}
    return null;
  }

  Future<String> reverseGeocode(double lat, double lon) async {
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
      return label;
    } catch (_) {
      return '';
    }
  }

  Future<List<Map<String, dynamic>>> searchPlaces(String query) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}&format=json&limit=5&addressdetails=1'
        '&viewbox=16.18,48.33,16.58,48.12&bounded=1',
      );
      final resp = await http.get(uri, headers: {'User-Agent': 'Sunspot.me/1.0'});
      if (resp.statusCode == 200) {
        return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }
}
