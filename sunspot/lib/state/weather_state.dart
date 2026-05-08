import 'package:flutter/material.dart';
import '../services/api_client.dart';

class WeatherState extends ChangeNotifier {
  Map<String, dynamic>? data;
  bool hasError = false;

  Future<void> fetch(ApiClient api, double lat, double lon) async {
    hasError = false;
    try {
      final result = await api.fetchWeather(lat, lon);
      if (result != null) {
        data = result;
      } else {
        hasError = true;
      }
    } catch (_) {
      hasError = true;
    }
    notifyListeners();
  }
}
