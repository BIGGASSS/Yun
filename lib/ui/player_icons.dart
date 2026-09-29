import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Vector glyphs for the desktop player bar.
///
/// Drawn locally with [CustomPainter] instead of the icon font so desktop
/// builds never depend on font subsetting for the transport, volume, and
/// queue metaphors, and every glyph shares one stroke weight and geometry.
enum PlayerGlyph {
  shuffle,
  previous,
  play,
  pause,
  next,
  repeat,
  repeatOne,
  volumeMute,
  volumeLow,
  volumeHigh,
  queue,
}

/// An icon-font free [Icon] replacement that follows the ambient [IconTheme]
/// for size and color (including [IconButton] selected/disabled colors).
class PlayerIcon extends StatelessWidget {
  const PlayerIcon(this.glyph, {super.key});
  final PlayerGlyph glyph;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: PlayerGlyphPainter(
          glyph,
          color: theme.color ?? Colors.black87,
        ),
      ),
    );
  }
}

/// Paints a [PlayerGlyph] on a normalized 24x24 grid scaled to the canvas.
///
/// Outline glyphs (shuffle, repeat, volume, queue) share a single rounded
/// 1.9 stroke; transport glyphs are filled rounded shapes, matching common
/// desktop player conventions.
class PlayerGlyphPainter extends CustomPainter {
  const PlayerGlyphPainter(this.glyph, {required this.color});

  final PlayerGlyph glyph;
  final Color color;

  static const double _grid = 24;
  static const double _stroke = 1.9;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.scale(size.width / _grid, size.height / _grid);
    switch (glyph) {
      case PlayerGlyph.shuffle:
        canvas
          ..drawPath(
            _path(const [Offset(16, 3.2), Offset(20.8, 3.2), Offset(20.8, 8)]),
            stroke,
          )
          ..drawLine(const Offset(4, 20.2), const Offset(20.8, 3.2), stroke)
          ..drawPath(
            _path(const [
              Offset(20.8, 15.8),
              Offset(20.8, 20.8),
              Offset(16, 20.8),
            ]),
            stroke,
          )
          ..drawLine(const Offset(14.8, 14.8), const Offset(20.8, 20.8), stroke)
          ..drawLine(const Offset(4, 3.8), const Offset(9.2, 9), stroke);
      case PlayerGlyph.previous:
        canvas
          ..drawRRect(
            RRect.fromLTRBR(5.2, 6.2, 7.9, 17.8, const Radius.circular(1.35)),
            fill,
          )
          ..drawPath(
            _roundedPolygon(const [
              Offset(18.8, 6.6),
              Offset(9.9, 12),
              Offset(18.8, 17.4),
            ], 1.8),
            fill,
          );
      case PlayerGlyph.play:
        canvas.drawPath(
          _roundedPolygon(const [
            Offset(9.6, 6.4),
            Offset(18.8, 12),
            Offset(9.6, 17.6),
          ], 1.7),
          fill,
        );
      case PlayerGlyph.pause:
        canvas
          ..drawRRect(
            RRect.fromLTRBR(7.4, 6.2, 10.5, 17.8, const Radius.circular(1.5)),
            fill,
          )
          ..drawRRect(
            RRect.fromLTRBR(13.5, 6.2, 16.6, 17.8, const Radius.circular(1.5)),
            fill,
          );
      case PlayerGlyph.next:
        canvas
          ..drawRRect(
            RRect.fromLTRBR(16.1, 6.2, 18.8, 17.8, const Radius.circular(1.35)),
            fill,
          )
          ..drawPath(
            _roundedPolygon(const [
              Offset(5.2, 6.6),
              Offset(14.1, 12),
              Offset(5.2, 17.4),
            ], 1.8),
            fill,
          );
      case PlayerGlyph.repeat:
        _paintRepeat(canvas, stroke);
      case PlayerGlyph.repeatOne:
        _paintRepeat(canvas, stroke);
        canvas.drawPath(
          _path(const [
            Offset(11.1, 10.4),
            Offset(12.7, 9.3),
            Offset(12.7, 14.7),
          ]),
          stroke,
        );
        canvas.drawLine(
          const Offset(10.8, 14.7),
          const Offset(14.6, 14.7),
          stroke,
        );
      case PlayerGlyph.volumeMute:
        _paintSpeaker(canvas, stroke);
        canvas
          ..drawLine(const Offset(15.4, 9.4), const Offset(20.6, 14.6), stroke)
          ..drawLine(const Offset(20.6, 9.4), const Offset(15.4, 14.6), stroke);
      case PlayerGlyph.volumeLow:
        _paintSpeaker(canvas, stroke);
        _paintWave(canvas, stroke, 4.9);
      case PlayerGlyph.volumeHigh:
        _paintSpeaker(canvas, stroke);
        _paintWave(canvas, stroke, 4.9);
        _paintWave(canvas, stroke, 8.6);
      case PlayerGlyph.queue:
        canvas
          ..drawLine(const Offset(4, 6.5), const Offset(20, 6.5), stroke)
          ..drawLine(const Offset(4, 10.5), const Offset(20, 10.5), stroke)
          ..drawLine(const Offset(4, 14.5), const Offset(13, 14.5), stroke)
          ..drawCircle(const Offset(15.7, 17.6), 2.1, stroke)
          ..drawPath(
            _path(const [
              Offset(17.8, 17.5),
              Offset(17.8, 11.7),
              Offset(20.9, 11.7),
              Offset(20.9, 13.9),
            ]),
            stroke,
          );
    }
    canvas.restore();
  }

  void _paintRepeat(Canvas canvas, Paint stroke) {
    canvas
      ..drawPath(
        _path(const [Offset(17, 1.2), Offset(21, 5.2), Offset(17, 9.2)]),
        stroke,
      )
      ..drawPath(
        Path()
          ..moveTo(3, 11.5)
          ..lineTo(3, 9.5)
          ..arcToPoint(const Offset(7, 5.5), radius: const Radius.circular(4))
          ..lineTo(20.6, 5.5),
        stroke,
      )
      ..drawPath(
        _path(const [Offset(7, 22.8), Offset(3, 18.8), Offset(7, 14.8)]),
        stroke,
      )
      ..drawPath(
        Path()
          ..moveTo(21, 12.5)
          ..lineTo(21, 14.5)
          ..arcToPoint(const Offset(17, 18.5), radius: const Radius.circular(4))
          ..lineTo(3.4, 18.5),
        stroke,
      );
  }

  void _paintSpeaker(Canvas canvas, Paint stroke) {
    canvas.drawPath(
      _path(const [
        Offset(10.8, 5.4),
        Offset(6.5, 9.4),
        Offset(3.8, 9.4),
        Offset(3.8, 14.6),
        Offset(6.5, 14.6),
        Offset(10.8, 18.6),
      ], close: true),
      stroke,
    );
  }

  void _paintWave(Canvas canvas, Paint stroke, double radius) {
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(11.8, 12), radius: radius),
      -math.pi / 3,
      math.pi * 2 / 3,
      false,
      stroke,
    );
  }

  static Path _path(List<Offset> points, {bool close = false}) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    if (close) path.close();
    return path;
  }

  static Path _roundedPolygon(List<Offset> vertices, double radius) {
    final path = Path();
    for (var i = 0; i < vertices.length; i++) {
      final previous = vertices[(i - 1 + vertices.length) % vertices.length];
      final current = vertices[i];
      final next = vertices[(i + 1) % vertices.length];
      final incoming = current - previous;
      final outgoing = next - current;
      final start =
          current -
          incoming /
              incoming.distance *
              math.min(radius, incoming.distance / 2);
      final end =
          current +
          outgoing /
              outgoing.distance *
              math.min(radius, outgoing.distance / 2);
      if (i == 0) {
        path.moveTo(start.dx, start.dy);
      } else {
        path.lineTo(start.dx, start.dy);
      }
      path.quadraticBezierTo(current.dx, current.dy, end.dx, end.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(PlayerGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
