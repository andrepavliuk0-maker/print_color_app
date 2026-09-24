import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../models/color_selection.dart';
import '../models/mask_data.dart';

class CmykProcessor {
  /// Применяет CMYK-коррекцию только к выделенной области.
  ///
  /// Не выделенные пиксели остаются без изменений.
  ///
  /// Значения CMYK:
  /// -100 ... +100
  ///
  /// Значение маски:
  /// 0   = пиксель не изменяется
  /// 255 = полная коррекция
  static img.Image applyCorrection({
    required img.Image source,
    required MaskData mask,
    required CmykCorrection correction,
  }) {
    if (source.width != mask.width ||
        source.height != mask.height) {
      throw ArgumentError(
        'Размер изображения и маски должен совпадать.',
      );
    }

    if (correction.isNeutral) {
      return source.clone();
    }

    final result = source.clone();

    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final maskValue = mask.valueAt(x, y);

        if (maskValue <= 0) {
          continue;
        }

        final pixel = source.getPixel(x, y);

        final originalR = pixel.r.toDouble();
        final originalG = pixel.g.toDouble();
        final originalB = pixel.b.toDouble();

        /*
         * Перевод RGB → CMYK.
         */
        final rgb = _rgbToCmyk(
          originalR / 255.0,
          originalG / 255.0,
          originalB / 255.0,
        );

        var c = rgb[0];
        var m = rgb[1];
        var yy = rgb[2];
        var k = rgb[3];

        /*
         * Применяем изменение CMYK.
         *
         * -100 = -100%
         * +100 = +100%
         */
        c = _clamp01(
          c + correction.cyan / 100.0,
        );

        m = _clamp01(
          m + correction.magenta / 100.0,
        );

        yy = _clamp01(
          yy + correction.yellow / 100.0,
        );

        k = _clamp01(
          k + correction.black / 100.0,
        );

        /*
         * CMYK → RGB.
         */
        final correctedRgb = _cmykToRgb(
          c,
          m,
          yy,
          k,
        );

        /*
         * Сила маски.
         *
         * 0.0 = оригинал
         * 1.0 = полностью исправленный цвет
         */
        final strength =
            (maskValue / 255.0).clamp(0.0, 1.0);

        final outputR = _blend(
          originalR,
          correctedRgb[0],
          strength,
        );

        final outputG = _blend(
          originalG,
          correctedRgb[1],
          strength,
        );

        final outputB = _blend(
          originalB,
          correctedRgb[2],
          strength,
        );

        /*
         * Сохраняем исходную прозрачность.
         */
        final alpha = pixel.a.toInt();

        result.setPixelRgba(
          x,
          y,
          _toByte(outputR),
          _toByte(outputG),
          _toByte(outputB),
          alpha,
        );
      }
    }

    return result;
  }

  /// RGB → CMYK.
  ///
  /// Все значения на входе и выходе находятся
  /// в диапазоне 0.0 ... 1.0.
  static List<double> _rgbToCmyk(
    double r,
    double g,
    double b,
  ) {
    r = _clamp01(r);
    g = _clamp01(g);
    b = _clamp01(b);

    final maxChannel = math.max(
      r,
      math.max(g, b),
    );

    final k = 1.0 - maxChannel;

    if (k >= 0.999999) {
      return <double>[
        0.0,
        0.0,
        0.0,
        1.0,
      ];
    }

    final denominator = 1.0 - k;

    final c = (1.0 - r - k) / denominator;
    final m = (1.0 - g - k) / denominator;
    final y = (1.0 - b - k) / denominator;

    return <double>[
      _clamp01(c),
      _clamp01(m),
      _clamp01(y),
      _clamp01(k),
    ];
  }

  /// CMYK → RGB.
  ///
  /// Все значения находятся
  /// в диапазоне 0.0 ... 1.0.
  static List<double> _cmykToRgb(
    double c,
    double m,
    double y,
    double k,
  ) {
    c = _clamp01(c);
    m = _clamp01(m);
    y = _clamp01(y);
    k = _clamp01(k);

    final r =
        (1.0 - c) *
        (1.0 - k) *
        255.0;

    final g =
        (1.0 - m) *
        (1.0 - k) *
        255.0;

    final b =
        (1.0 - y) *
        (1.0 - k) *
        255.0;

    return <double>[
      r,
      g,
      b,
    ];
  }

  /// Плавно смешивает исходный и исправленный цвет.
  static double _blend(
    double original,
    double corrected,
    double strength,
  ) {
    return original +
        (corrected - original) *
            strength.clamp(0.0, 1.0);
  }

  /// Ограничивает значение диапазоном 0...1.
  static double _clamp01(double value) {
    return value.clamp(0.0, 1.0);
  }

  /// Переводит значение 0...255 в целое.
  static int _toByte(double value) {
    return value
        .round()
        .clamp(0, 255);
  }
}
