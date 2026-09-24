import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/color_selection.dart';
import '../models/mask_data.dart';

class ColorDetector {
  /// Определяет RGB-цвет выбранного пользователем пикселя.
  static RgbColor? pickColor(
    img.Image image,
    int x,
    int y,
  ) {
    if (x < 0 ||
        y < 0 ||
        x >= image.width ||
        y >= image.height) {
      return null;
    }

    final pixel = image.getPixel(x, y);

    return RgbColor(
      r: pixel.r.toInt().clamp(0, 255),
      g: pixel.g.toInt().clamp(0, 255),
      b: pixel.b.toInt().clamp(0, 255),
    );
  }

  /// Создаёт маску всех оттенков, похожих на выбранный цвет.
  ///
  /// tolerance:
  /// 0   = практически только выбранный цвет
  /// 100 = очень широкий диапазон
  ///
  /// softness:
  /// 0   = жёсткая граница
  /// 100 = максимально плавный переход
  static MaskData createColorMask({
    required img.Image image,
    required RgbColor target,
    double tolerance = 20,
    double softness = 10,
  }) {
    final width = image.width;
    final height = image.height;

    final values = Uint8List(width * height);

    final safeTolerance =
        tolerance.clamp(0.0, 100.0);

    final safeSoftness =
        softness.clamp(0.0, 100.0);

    const maxRgbDistance = 441.67295593;

    /*
     * Tolerance определяет радиус поиска.
     */
    final threshold =
        maxRgbDistance * (safeTolerance / 100.0);

    /*
     * Softness определяет размер плавного перехода
     * за пределами основного диапазона.
     */
    final feather =
        maxRgbDistance * (safeSoftness / 100.0);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = image.getPixel(x, y);

        final dr = pixel.r.toDouble() - target.r;
        final dg = pixel.g.toDouble() - target.g;
        final db = pixel.b.toDouble() - target.b;

        final distance = math.sqrt(
          dr * dr +
              dg * dg +
              db * db,
        );

        double strength;

        if (safeTolerance <= 0) {
          strength = distance < 1.0 ? 1.0 : 0.0;
        } else if (feather <= 0) {
          strength =
              distance <= threshold ? 1.0 : 0.0;
        } else {
          final edge = threshold + feather;

          if (distance <= threshold) {
            strength = 1.0;
          } else if (distance >= edge) {
            strength = 0.0;
          } else {
            final position =
                (distance - threshold) / feather;

            /*
             * Smoothstep делает границу
             * плавной и естественной.
             */
            final smooth =
                position *
                position *
                (3.0 - 2.0 * position);

            strength = 1.0 - smooth;
          }
        }

        values[y * width + x] =
            (strength * 255.0)
                .round()
                .clamp(0, 255);
      }
    }

    return MaskData(
      width: width,
      height: height,
      values: values,
    );
  }

  /// Считает количество выбранных пикселей.
  static int countSelectedPixels(
    MaskData mask,
  ) {
    var count = 0;

    for (final value in mask.values) {
      if (value > 0) {
        count++;
      }
    }

    return count;
  }

  /// Возвращает процент изображения,
  /// попавшего в выделение.
  static double selectedPercentage(
    MaskData mask,
  ) {
    if (mask.values.isEmpty) {
      return 0;
    }

    return countSelectedPixels(mask) /
        mask.values.length *
        100.0;
  }

  /// Проверяет, есть ли вообще выделение.
  static bool hasSelection(
    MaskData mask,
  ) {
    for (final value in mask.values) {
      if (value > 0) {
        return true;
      }
    }

    return false;
  }
}
