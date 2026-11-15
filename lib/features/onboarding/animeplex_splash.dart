import 'dart:math' as math;

import 'package:flutter/material.dart';

/// AnimePlex's launch mark, driven by the startup animation controller.
class AnimePlexSplash extends StatelessWidget {
  const AnimePlexSplash({super.key, required this.progress, this.size = 200});

  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = progress.clamp(0.0, 1.0).toDouble();
    final reveal = Curves.easeOutCubic.transform(
      ((t - 0.12) / 0.48).clamp(0.0, 1.0).toDouble(),
    );
    final logoSize = size * 0.82;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0x554979C5),
                    Color(0x1F284A91),
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(child: CustomPaint(painter: _OrbitPainter(t))),
          Opacity(
            opacity: reveal,
            child: Transform.scale(
              scale: 0.78 + 0.22 * reveal,
              child: ClipOval(
                child: SizedBox.square(
                  dimension: logoSize,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        'assets/icon/app_icon.png',
                        fit: BoxFit.contain,
                      ),
                      CustomPaint(painter: _SheenPainter(t)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0).toDouble();
    final opacity = math.min(
      (t / 0.22).clamp(0.0, 1.0).toDouble(),
      ((1 - t) / 0.35).clamp(0.0, 1.0).toDouble(),
    );
    if (opacity <= 0) return;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * (0.40 + 0.08 * t);
    final angle = -math.pi * 0.67 + t * math.pi * 1.95;
    final gold = Paint()
      ..color = const Color(0xFFFFC78E).withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, size.width * 0.008)
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius), angle, 1.8, false, gold,
    );
    final blue = Paint()
      ..color = const Color(0xFF88C5FF).withValues(alpha: opacity * 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, size.width * 0.005)
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.95),
      -angle,
      1.65,
      false,
      blue,
    );
    final dot = center +
        Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    canvas.drawCircle(
      dot,
      size.width * 0.025,
      Paint()
        ..color = const Color(0xFFFFA65C).withValues(alpha: opacity * 0.7)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.035),
    );
    canvas.drawCircle(
      dot,
      math.max(1.5, size.width * 0.013),
      Paint()..color = const Color(0xFFFFF7E4).withValues(alpha: opacity),
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) => oldDelegate.progress != progress;
}

class _SheenPainter extends CustomPainter {
  _SheenPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = ((progress - 0.35) / 0.4).clamp(0.0, 1.0).toDouble();
    if (p <= 0 || p >= 1) return;
    final x = (p * 1.8 - 0.4) * size.width;
    canvas.save();
    canvas.translate(x, size.height / 2);
    canvas.rotate(-0.35);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width * 0.17,
      height: size.height * 1.8,
    );
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Colors.transparent, Color(0x66FFFFFF), Colors.transparent],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter oldDelegate) => oldDelegate.progress != progress;
}
