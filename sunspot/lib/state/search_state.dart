import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import '../services/api_client.dart';

class SearchState extends ChangeNotifier {
  List<Map<String, dynamic>> results = [];
  bool loading = false;
  Map<String, dynamic>? homeAddress;
  Timer? _debounce;

  void load() {
    try {
      final raw = html.window.localStorage['sunspot_home'];
      if (raw != null) {
        homeAddress = jsonDecode(raw) as Map<String, dynamic>;
        notifyListeners();
      }
    } catch (_) {}
  }

  void setHome(Map<String, dynamic> result) {
    final home = {
      'lat': result['lat'],
      'lon': result['lon'],
      'display_name': result['display_name'],
    };
    html.window.localStorage['sunspot_home'] = jsonEncode(home);
    homeAddress = home;
    notifyListeners();
  }

  void clearResults({void Function(bool)? setPointerEvents}) {
    if (results.isEmpty) return;
    results = [];
    notifyListeners();
    setPointerEvents?.call(true);
  }

  void onQueryChanged(String query, ApiClient api, void Function(bool) setPointerEvents) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      clearResults(setPointerEvents: setPointerEvents);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => runSearch(query.trim(), api, setPointerEvents),
    );
  }

  Future<void> runSearch(String query, ApiClient api, void Function(bool) setPointerEvents) async {
    loading = true;
    notifyListeners();
    try {
      final r = await api.searchPlaces(query);
      results = r;
      if (results.isNotEmpty) setPointerEvents(false);
    } catch (_) {
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
