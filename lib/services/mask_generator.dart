import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../models/color_selection.dart';
import '../models/mask_data.dart';

class MaskGenerator {
  /// Создаёт маску по выбранному цвету.
  ///
  /// tolerance:
  /// 0   = только практически идентичный цвет
  /// 100 = очень широкий диапазон
  ///
  /// softness:
  /// 0   = жёсткая граница
  /// 100 = очень плавный переход
  ///
  /// connectedOnly:
  /// false = ищем похожие цвета по всему изображению
  /// true  = выделяем только связанную область вокруг точки
  static MaskData generate({
    required img.Image image,
    required ColorSelection selection,
    int? tapX,
    int? tapY,
  }) {
    if (selection.connectedOnly &&
        tapX != null &&
        tapY != null) {
      return _generateConnected(
        image: image,
        selection: selection,
        startX: tapX,
        startY: tapY,
      );
    }

    return _generateGlobal(
      image: image,
      selection: selection,
    );
  }

  /// Глобальное выделение:
  /// все похожие оттенки во всём изображении.
  static MaskData _generateGlobal({
    required img.Image image,
    required ColorSelection selection,
  }) {
    final width = image.width;
    final height = image.height;

    final values = Uint8List(width * height);

    final tolerance =
        selection.tolerance.clamp(0.0, 100.0);

    final softness =
        selection.softness.clamp(0.0, 100.0);

    const maxDistance = 441.67295593;

    final threshold =
        maxDistance * tolerance / 100.0;

    final feather =
        maxDistance * softness / 100.0;

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = image.getPixel(x, y);

        final distance = _distance(
          pixel.r.toDouble(),
          pixel.g.toDouble(),
          pixel.b.toDouble(),
          selection.color.r.toDouble(),
          selection.color.g.toDouble(),
          selection.color.b.toDouble(),
        );

        values[y * width + x] =
            _strengthToByte(
          _calculateStrength(
            distance: distance,
            threshold: threshold,
            feather: feather,
          ),
        );
      }
    }

    return MaskData(
      width: width,
      height: height,
      values: values,
    );
  }

  /// Связанное выделение.
  ///
  /// Начинаем с точки, по которой пользователь
  /// нажал на изображение, и распространяемся
  /// только по соседним пикселям похожего цвета.
  static MaskData _generateConnected({
    required img.Image image,
    required ColorSelection selection,
    required int startX,
    required int startY,
  }) {
    final width = image.width;
    final height = image.height;

    final values = Uint8List(width * height);

    if (startX < 0 ||
        startY < 0 ||
        startX >= width ||
        startY >= height) {
      return MaskData(
        width: width,
        height: height,
        values: values,
      );
    }

    /*
     * Получаем реальный цвет точки,
     * по которой пользователь нажал.
     */
    final startPixel =
        image.getPixel(startX, startY);

    final target = RgbColor(
      r: startPixel.r.toInt().clamp(0, 255),
      g: startPixel.g.toInt().clamp(0, 255),
      b: startPixel.b.toInt().clamp(0, 255),
    );

    /*
     * Основной диапазон цвета.
     */
    final tolerance =
        selection.tolerance.clamp(0.0, 100.0);

    final softness =
        selection.softness.clamp(0.0, 100.0);

    const maxDistance = 441.67295593;

    final threshold =
        maxDistance * tolerance / 100.0;

    final feather =
        maxDistance * softness / 100.0;

    /*
     * Очередь пикселей для flood fill.
     */
    final queue = <int>[];

    final visited =
        Uint8List(width * height);

    final startIndex =
        startY * width + startX;

    queue.add(startIndex);
    visited[startIndex] = 1;

    var queuePosition = 0;

    while (queuePosition < queue.length) {
      final index =
          queue[queuePosition++];

      final x = index % width;
      final y = index ~/ width;

      final pixel =
          image.getPixel(x, y);

      final distance = _distance(
        pixel.r.toDouble(),
        pixel.g.toDouble(),
        pixel.b.toDouble(),
        target.r.toDouble(),
        target.g.toDouble(),
        target.b.toDouble(),
      );

      final strength =
          _calculateStrength(
        distance: distance,
        threshold: threshold,
        feather: feather,
      );

      /*
       * Записываем силу выделения.
       */
      if (strength > 0) {
        values[index] =
            _strengthToByte(strength);
      }

      /*
       * Если пиксель полностью вне диапазона,
       * дальше через него не распространяемся.
       */
      if (strength <= 0) {
        continue;
      }

      /*
       * 4-связность:
       *
       *     ↑
       * ←   •   →
       *     ↓
       *
       * Это предотвращает слишком агрессивное
       * перескакивание через диагональные области.
       */
      _addNeighbor(
        queue: queue,
        visited: visited,
        width: width,
        height: height,
        x: x - 1,
        y: y,
      );

      _addNeighbor(
        queue: queue,
        visited: visited,
        width: width,
        height: height,
        x: x + 1,
        y: y,
      );

      _addNeighbor(
        queue: queue,
        visited: visited,
        width: width,
        height: height,
        x: x,
        y: y - 1,
      );

      _addNeighbor(
        queue: queue,
        visited: visited,
        width: width,
        height: height,
        x: x,
        y: y + 1,
      );
    }

    return MaskData(
      width: width,
      height: height,
      values: values,
    );
  }

  /// Добавляет соседний пиксель в очередь.
  static void _addNeighbor({
    required List<int> queue,
    required Uint8List visited,
    required int width,
    required int height,
    required int x,
    required int y,
  }) {
    if (x < 0 ||
        y < 0 ||
        x >= width ||
        y >= height) {
      return;
    }

    final index =
        y * width + x;

    if (visited[index] != 0) {
      return;
    }

    visited[index] = 1;
    queue.add(index);
  }

  /// Евклидово расстояние между двумя RGB-цветами.
  static double _distance(
    double r1,
    double g1,
    double b1,
    double r2,
    double g2,
    double b2,
  ) {
    final dr = r1 - r2;
    final dg = g1 - g2;
    final db = b1 - b2;

    return math.sqrt(
      dr * dr +
          dg * dg +
          db * db,
    );
  }

  /// Вычисляет силу маски для конкретного пикселя.
  static double _calculateStrength({
    required double distance,
    required double threshold,
    required double feather,
  }) {
    /*
     * При tolerance = 0 разрешаем только
     * практически идентичный цвет.
     */
    if (threshold <= 0) {
      return distance < 1.0
          ? 1.0
          : 0.0;
    }

    /*
     * Без softness граница жёсткая.
     */
    if (feather <= 0) {
      return distance <= threshold
          ? 1.0
          : 0.0;
    }

    final edge =
        threshold + feather;

    if (distance <= threshold) {
      return 1.0;
    }

    if (distance >= edge) {
      return 0.0;
    }

    /*
     * Плавный переход.
     */
    final position =
        (distance - threshold) /
            feather;

    final smooth =
        position *
        position *
        (3.0 - 2.0 * position);

    return 1.0 - smooth;
  }

  static int _strengthToByte(
    double strength,
  ) {
    return (strength.clamp(0.0, 1.0) * 255.0)
        .round()
        .clamp(0, 255);
  }
}
