import 'package:image/image.dart' as img;

class GlobalCorrector {
  /// Применяет общую коррекцию ко всему изображению.
  ///
  /// brightness, contrast, saturation: -100 ... +100
  static img.Image apply({
    required img.Image source,
    required double brightness,
    required double contrast,
    required double saturation,
  }) {
    final result = source.clone();

    final brightnessShift = brightness / 100.0 * 255.0;
    final contrastFactor = (100.0 + contrast) / 100.0;
    final saturationFactor = (100.0 + saturation) / 100.0;

    for (var y = 0; y < result.height; y++) {
      for (var x = 0; x < result.width; x++) {
        final pixel = source.getPixel(x, y);

        var r = pixel.r.toDouble();
        var g = pixel.g.toDouble();
        var b = pixel.b.toDouble();

        // Яркость.
        r += brightnessShift;
        g += brightnessShift;
        b += brightnessShift;

        // Контраст относительно среднего серого.
        r = ((r - 128.0) * contrastFactor) + 128.0;
        g = ((g - 128.0) * contrastFactor) + 128.0;
        b = ((b - 128.0) * contrastFactor) + 128.0;

        // Насыщенность относительно яркости пикселя.
        final gray = 0.299 * r + 0.587 * g + 0.114 * b;

        r = gray + (r - gray) * saturationFactor;
        g = gray + (g - gray) * saturationFactor;
        b = gray + (b - gray) * saturationFactor;

        result.setPixelRgba(
          x,
          y,
          _toByte(r),
          _toByte(g),
          _toByte(b),
          pixel.a.toInt(),
        );
      }
    }

    return result;
  }

  static int _toByte(double value) {
    return value.round().clamp(0, 255).toInt();
  }
}
