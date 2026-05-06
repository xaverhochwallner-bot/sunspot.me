import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../utils/time_utils.dart';

class SavedSpotsState extends ChangeNotifier {
  List<Map<String, dynamic>> spots = [];
  Map<String, bool?> sunnyStatus = {};
  Map<String, String> addresses = {};

  void load() {
    try {
      final raw = html.window.localStorage['sunspot_saved'];
      if (raw != null) {
        spots = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        notifyListeners();
      }
    } catch (_) {}
  }

  void _persist() {
    html.window.localStorage['sunspot_saved'] = jsonEncode(spots);
  }

  bool isSaved(double lat, double lon) =>
      spots.any((s) => s['lat'] == lat && s['lon'] == lon);

  void add(Map<String, dynamic> spot) {
    spots.add(spot);
    _persist();
    notifyListeners();
  }

  void removeWhere(bool Function(Map<String, dynamic>) test) {
    spots.removeWhere(test);
    _persist();
    notifyListeners();
  }

  void removeAt(int idx) {
    spots.removeAt(idx);
    _persist();
    notifyListeners();
  }

  void cacheAddress(String key, String label) {
    if (addresses[key] == label) return;
    addresses[key] = label;
    notifyListeners();
  }

  Future<void> refreshSunnyStatus(ApiClient api, DateTime date, double hour) async {
    if (spots.isEmpty) return;
    final h       = hour.toInt();
    final min     = ((hour * 60).toInt() % 60);
    final dateStr = formatDate(date);
    for (final s in List.of(spots)) {
      final lat = s['lat'] as double;
      final lon = s['lon'] as double;
      final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
      sunnyStatus[key] = null;
      notifyListeners();
      final sunny = await api.isSunny(lat, lon, dateStr, h, min);
      sunnyStatus[key] = sunny;
      notifyListeners();
    }
  }
}
