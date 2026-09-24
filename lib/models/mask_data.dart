import 'dart:typed_data';

class MaskData {
  final int width;
  final int height;

  /// Значение каждого пикселя:
  /// 0   = не выбран
  /// 255 = выбран полностью
  /// 1..254 = частичное выделение / мягкая граница
  final Uint8List values;

  const MaskData({
    required this.width,
    required this.height,
    required this.values,
  });

  int get length => values.length;

  int valueAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return 0;
    }

    return values[y * width + x];
  }

  bool isSelected(int x, int y) {
    return valueAt(x, y) > 0;
  }

  double strengthAt(int x, int y) {
    return valueAt(x, y) / 255.0;
  }

  int get selectedPixels {
    var count = 0;

    for (final value in values) {
      if (value > 0) {
        count++;
      }
    }

    return count;
  }

  double get selectedPercentage {
    if (values.isEmpty) {
      return 0;
    }

    return selectedPixels / values.length * 100.0;
  }

  MaskData copy() {
    return MaskData(
      width: width,
      height: height,
      values: Uint8List.fromList(values),
    );
  }
}
