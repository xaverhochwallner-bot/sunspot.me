import 'package:flutter/material.dart';
import '../services/api_client.dart';

class WeatherState extends ChangeNotifier {
  Map<String, dynamic>? data;

  Future<void> fetch(ApiClient api, double lat, double lon) async {
    final result = await api.fetchWeather(lat, lon);
    if (result != null) {
      data = result;
      notifyListeners();
    }
  }
}
