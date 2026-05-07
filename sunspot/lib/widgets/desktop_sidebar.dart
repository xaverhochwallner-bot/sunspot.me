import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_shell_state.dart';

class DesktopSidebar extends StatelessWidget {
  final ScrollController panelScroll;
  final Widget child;
  final void Function(int) onTabTap;

  const DesktopSidebar({
    required this.panelScroll,
    required this.child,
    required this.onTabTap,
    super.key,
  });

  static const _tabs = [
    (Icons.access_time,       'Time'),
    (Icons.wb_sunny_outlined, 'Spots'),
    (Icons.route,             'Tour'),
    (Icons.favorite_outline,  'Saved'),
  ];

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<AppShellState>();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Content area
          Expanded(
            child: SingleChildScrollView(
              controller: panelScroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: child,
            ),
          ),
          // Tab bar
          Divider(height: 1, color: Colors.grey.shade200),
          SizedBox(
            height: 56,
            child: Row(
              children: _tabs.asMap().entries.map((entry) {
                final i     = entry.key;
                final icon  = entry.value.$1;
                final label = entry.value.$2;
                final sel   = shell.mobileTab == i;
                return Expanded(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => onTabTap(i),
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: sel
                                  ? Colors.orange.withValues(alpha: 0.12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(icon, size: 22,
                                color: sel
                                    ? Colors.orange
                                    : Colors.grey.shade400),
                          ),
                          const SizedBox(height: 1),
                          Text(label,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: sel
                                    ? Colors.orange
                                    : Colors.grey.shade400,
                              )),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
