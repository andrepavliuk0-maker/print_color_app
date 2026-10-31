import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/color_selection.dart';
import '../models/mask_data.dart';
import 'cmyk_processor.dart';
import 'global_corrector.dart';
import 'mask_generator.dart';
import 'project_file.dart';

// ============================================================
// RUNNER
// ============================================================

/// Выполняет тяжёлую работу в отдельном изолейте, чтобы интерфейс
/// не зависал на больших изображениях.
///
/// Если изолейт запустить не удалось, задача выполняется
/// в текущем изолейте.
///
/// Все замыкания ниже создаются в top-level функциях и захватывают
/// только свои аргументы — состояние виджетов в изолейт не попадает.
Future<T> _runHeavy<T>(T Function() job) async {
  try {
    return await Isolate.run<T>(job);
  } catch (_) {
    return job();
  }
}

// ============================================================
// DECODE IMAGE
// ============================================================

/// Декодирует изображение и приводит его к 8 бит на канал, RGBA.
///
/// Так все остальные алгоритмы работают с одним и тем же
/// диапазоном значений 0..255 (в том числе для 16-битных TIFF/PNG
/// и изображений с палитрой).
Future<img.Image?> decodeImageAsync(Uint8List bytes) {
  return _runHeavy<img.Image?>(() => _decodeImage(bytes));
}

img.Image? _decodeImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);

  if (decoded == null) {
    return null;
  }

  return decoded.convert(
    format: img.Format.uint8,
    numChannels: 4,
  );
}

// ============================================================
// SELECTION
// ============================================================

class SelectionResult {
  final MaskData mask;

  /// Готовая прозрачная PNG-картинка для предпросмотра маски.
  final Uint8List overlayPng;

  const SelectionResult({
    required this.mask,
    required this.overlayPng,
  });
}

Future<SelectionResult> computeSelectionAsync({
  required img.Image image,
  required ColorSelection selection,
  int? tapX,
  int? tapY,
}) {
  return _runHeavy<SelectionResult>(
    () => _computeSelection(image, selection, tapX, tapY),
  );
}

SelectionResult _computeSelection(
  img.Image image,
  ColorSelection selection,
  int? tapX,
  int? tapY,
) {
  final mask = MaskGenerator.generate(
    image: image,
    selection: selection,
    tapX: tapX,
    tapY: tapY,
  );

  return SelectionResult(
    mask: mask,
    overlayPng: _buildOverlayPng(mask),
  );
}

Uint8List _buildOverlayPng(MaskData mask) {
  final overlay = img.Image(
    width: mask.width,
    height: mask.height,
    numChannels: 4,
  );

  final values = mask.values;

  for (var y = 0; y < mask.height; y++) {
    final row = y * mask.width;

    for (var x = 0; x < mask.width; x++) {
      final value = values[row + x];

      if (value == 0) {
        continue;
      }

      final alpha = (value * 0.55).round().clamp(0, 255).toInt();

      overlay.setPixelRgba(x, y, 0, 190, 255, alpha);
    }
  }

  return Uint8List.fromList(img.encodePng(overlay));
}

// ============================================================
// CORRECTIONS
// ============================================================

Future<img.Image> applyCmykAsync({
  required img.Image source,
  required MaskData mask,
  required CmykCorrection correction,
}) {
  return _runHeavy<img.Image>(
    () => CmykProcessor.applyCorrection(
      source: source,
      mask: mask,
      correction: correction,
    ),
  );
}

Future<img.Image> applyGlobalAsync({
  required img.Image source,
  required double brightness,
  required double contrast,
  required double saturation,
}) {
  return _runHeavy<img.Image>(
    () => GlobalCorrector.apply(
      source: source,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
    ),
  );
}

// ============================================================
// PNG
// ============================================================

Future<Uint8List> encodePngAsync(img.Image image) {
  return _runHeavy<Uint8List>(
    () => Uint8List.fromList(img.encodePng(image)),
  );
}

// ============================================================
// PROJECT
// ============================================================

class LoadedProject {
  final Map<String, dynamic> settings;
  final img.Image original;
  final img.Image processed;

  const LoadedProject({
    required this.settings,
    required this.original,
    required this.processed,
  });
}

Future<Uint8List> encodeProjectAsync({
  required Map<String, dynamic> settings,
  required img.Image original,
  required img.Image processed,
}) {
  return _runHeavy<Uint8List>(
    () => ProjectFile.encode(
      settings: settings,
      originalPng: Uint8List.fromList(img.encodePng(original)),
      processedPng: Uint8List.fromList(img.encodePng(processed)),
    ),
  );
}

Future<LoadedProject> decodeProjectAsync(Uint8List bytes) {
  return _runHeavy<LoadedProject>(() => _decodeProject(bytes));
}

LoadedProject _decodeProject(Uint8List bytes) {
  final project = ProjectFile.decode(bytes);

  final original = _decodeImage(project.originalPng);

  if (original == null) {
    throw const FormatException(
      'Не удалось прочитать изображение из проекта.',
    );
  }

  final processedBytes = project.processedPng;

  img.Image? processed;

  if (processedBytes != null) {
    processed = _decodeImage(processedBytes);
  }

  if (processed == null ||
      processed.width != original.width ||
      processed.height != original.height) {
    processed = original.clone();
  }

  return LoadedProject(
    settings: project.settings,
    original: original,
    processed: processed,
  );
}
