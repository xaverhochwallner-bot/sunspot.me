import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_shell_state.dart';

class MobileBottomSheet extends StatelessWidget {
  final ScrollController contentScroll;
  final Widget child;
  final void Function(int) onTabTap;
  final bool keyboardOpen;

  const MobileBottomSheet({
    required this.contentScroll,
    required this.child,
    required this.onTabTap,
    this.keyboardOpen = false,
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

    return SafeArea(
      top: false,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          children: [
            if (!keyboardOpen) ...[
              // Expand/collapse/hide handle
              GestureDetector(
                onTap: () => context.read<AppShellState>().togglePanel(),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: 24,
                  child: Center(
                    child: Container(
                      width: 36, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              // Content area — hidden when panel is slid away
              if (!shell.panelHidden)
                Expanded(
                  child: ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white,
                        Colors.white,
                        Colors.white.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.75, 1.0],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: SingleChildScrollView(
                      controller: contentScroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: child,
                    ),
                  ),
                ),
            ],
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
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
