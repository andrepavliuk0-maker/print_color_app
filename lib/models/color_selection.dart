import 'dart:math' as math;

class RgbColor {
  final int r;
  final int g;
  final int b;

  const RgbColor({
    required this.r,
    required this.g,
    required this.b,
  });

  String get hex =>
      '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}'.toUpperCase();

  double get brightness =>
      (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;

  double distanceTo(RgbColor other) {
    final dr = r - other.r;
    final dg = g - other.g;
    final db = b - other.b;

    return math.sqrt(
      dr * dr +
          dg * dg +
          db * db,
    );
  }

  RgbColor copyWith({
    int? r,
    int? g,
    int? b,
  }) {
    return RgbColor(
      r: r ?? this.r,
      g: g ?? this.g,
      b: b ?? this.b,
    );
  }
}

class CmykCorrection {
  final double cyan;
  final double magenta;
  final double yellow;
  final double black;

  const CmykCorrection({
    this.cyan = 0,
    this.magenta = 0,
    this.yellow = 0,
    this.black = 0,
  });

  CmykCorrection copyWith({
    double? cyan,
    double? magenta,
    double? yellow,
    double? black,
  }) {
    return CmykCorrection(
      cyan: cyan ?? this.cyan,
      magenta: magenta ?? this.magenta,
      yellow: yellow ?? this.yellow,
      black: black ?? this.black,
    );
  }

  bool get isNeutral =>
      cyan == 0 &&
      magenta == 0 &&
      yellow == 0 &&
      black == 0;
}

class ColorSelection {
  final RgbColor color;

  /// 0..100
  final double tolerance;

  /// 0..100
  final double softness;

  /// Whether selection should include every similar color
  /// or only the connected region around the tapped pixel.
  final bool connectedOnly;

  const ColorSelection({
    required this.color,
    this.tolerance = 20,
    this.softness = 10,
    this.connectedOnly = false,
  });

  ColorSelection copyWith({
    RgbColor? color,
    double? tolerance,
    double? softness,
    bool? connectedOnly,
  }) {
    return ColorSelection(
      color: color ?? this.color,
      tolerance: tolerance ?? this.tolerance,
      softness: softness ?? this.softness,
      connectedOnly: connectedOnly ?? this.connectedOnly,
    );
  }
}
