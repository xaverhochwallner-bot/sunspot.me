import 'dart:async';
import 'package:flutter/material.dart';

class AppShellState extends ChangeNotifier {
  // Bottom-sheet / sidebar panel
  bool panelExpanded = false;
  bool panelHidden   = false;

  // Active tab (0=Time, 1=Spots, 2=Tour, 3=Saved)
  int mobileTab = 0;

  // Spot detail overlay
  Map<String, dynamic>? selectedSpot;
  int selectedSpotIdx = 0;

  // Splash screen + error banner
  bool    splashVisible = true;
  String? errorMessage;
  Timer?  _errorTimer;

  // ---------------------------------------------------------------------------

  void togglePanel() {
    if (panelHidden) {
      panelHidden   = false;
      panelExpanded = false;
    } else if (panelExpanded) {
      panelExpanded = false;
      panelHidden   = true;
    } else {
      panelExpanded = true;
    }
    notifyListeners();
  }

  void collapsePanel() {
    if (!panelExpanded && !panelHidden) return;
    panelExpanded = false;
    panelHidden   = false;
    notifyListeners();
  }

  void setMobileTab(int tab, {bool resetPanel = true}) {
    mobileTab = tab;
    if (resetPanel) {
      panelExpanded = false;
      panelHidden   = false;
    }
    notifyListeners();
  }

  void selectSpot(Map<String, dynamic> spot, int idx) {
    selectedSpot    = spot;
    selectedSpotIdx = idx;
    notifyListeners();
  }

  void clearSpot() {
    if (selectedSpot == null) return;
    selectedSpot = null;
    notifyListeners();
  }

  void hideSplash() {
    if (!splashVisible) return;
    splashVisible = false;
    notifyListeners();
  }

  void showError(String msg) {
    _errorTimer?.cancel();
    errorMessage = msg;
    notifyListeners();
    _errorTimer = Timer(const Duration(seconds: 3), () {
      errorMessage = null;
      notifyListeners();
    });
  }

  void clearError() {
    _errorTimer?.cancel();
    errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    super.dispose();
  }
}
