import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';

class ScanOverlayPainter extends CustomPainter {
  final Rect scanWindow;
  final Color borderColor;

  const ScanOverlayPainter({
    required this.scanWindow,
    this.borderColor = JamTimeColors.cyan,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = Colors.black.withValues(alpha: 0.65);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, scanWindow.top), background);
    canvas.drawRect(Rect.fromLTWH(0, scanWindow.bottom, size.width, size.height - scanWindow.bottom), background);
    canvas.drawRect(Rect.fromLTWH(0, scanWindow.top, scanWindow.left, scanWindow.height), background);
    canvas.drawRect(Rect.fromLTWH(scanWindow.right, scanWindow.top, size.width - scanWindow.right, scanWindow.height), background);

    final borderPaint = Paint()
      ..color = borderColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    const radius = Radius.circular(8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(scanWindow, radius),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(ScanOverlayPainter old) => old.borderColor != borderColor;
}
