import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/weather_state.dart';
import '../utils/weather_utils.dart';

class WeatherWidget extends StatelessWidget {
  const WeatherWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final data = context.watch<WeatherState>().data;
    if (data == null) return const SizedBox.shrink();

    final temp  = (data['temperature_2m'] as num?)?.round() ?? 0;
    final code  = (data['weather_code']   as num?)?.toInt() ?? 0;
    final uv    = (data['uv_index']       as num?) ?? 0;
    final uvInt = uv.round();
    final emoji = weatherEmoji(code);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
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
            decoration: BoxDecoration(color: uvColor(uv), shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }
}
