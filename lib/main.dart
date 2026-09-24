import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'models/color_selection.dart';
import 'models/mask_data.dart';
import 'services/cmyk_processor.dart';
import 'services/color_detector.dart';
import 'services/mask_generator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const PrintColorApp(),
  );
}

class PrintColorApp extends StatelessWidget {
  const PrintColorApp({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Color App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: const EditorPage(),
    );
  }
}

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
  });

  @override
  State<EditorPage> createState() =>
      _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  // ============================================================
  // IMAGE DATA
  // ============================================================

  img.Image? originalImage;
  img.Image? processedImage;

  Uint8List? originalBytes;

  String? openedFileName;
  String? openedFilePath;

  // ============================================================
  // COLOR SELECTION
  // ============================================================

  RgbColor? selectedColor;

  MaskData? mask;

  int? selectedX;
  int? selectedY;

  double tolerance = 20.0;
  double softness = 10.0;

  bool connectedOnly = false;

  // ============================================================
  // CMYK
  // ============================================================

  CmykCorrection correction =
      const CmykCorrection();

  // ============================================================
  // GLOBAL IMAGE ADJUSTMENTS
  // ============================================================

  double brightness = 0.0;
  double contrast = 0.0;
  double saturation = 0.0;

  // ============================================================
  // PREVIEW
  // ============================================================

  bool showBefore = false;
  bool showMask = true;

  // ============================================================
  // PROCESSING STATE
  // ============================================================

  bool processing = false;
  bool exporting = false;

  String statusMessage =
      'Откройте изображение для начала работы';

  Timer? _statusTimer;

  // ============================================================
  // HISTORY
  // ============================================================

  final List<_HistorySnapshot> history =
      <_HistorySnapshot>[];

  int historyIndex = -1;

  // ============================================================
  // OPEN IMAGE
  // ============================================================

  Future<void> _openImage() async {
    if (processing) {
      return;
    }

    try {
      final result =
          await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>[
          'png',
          'jpg',
          'jpeg',
          'webp',
          'bmp',
          'tif',
          'tiff',
        ],
        withData: true,
      );

      if (result == null ||
          result.files.isEmpty) {
        return;
      }

      final file = result.files.first;

      Uint8List? bytes = file.bytes;

      if (bytes == null &&
          file.path != null) {
        setState(() {
          statusMessage =
              'Не удалось получить данные файла';
        });
        return;
      }

      if (bytes == null) {
        return;
      }

      setState(() {
        processing = true;
        statusMessage =
            'Загрузка изображения...';
      });

      await Future<void>.delayed(
        const Duration(
          milliseconds: 50,
        ),
      );

      final decoded =
          img.decodeImage(bytes);

      if (decoded == null) {
        if (!mounted) {
          return;
        }

        setState(() {
          processing = false;
          statusMessage =
              'Не удалось открыть изображение';
        });

        return;
      }

      final image =
          decoded.clone();

      if (!mounted) {
        return;
      }

      setState(() {
        originalBytes =
            Uint8List.fromList(bytes);

        originalImage =
            image;

        processedImage =
            image.clone();

        openedFileName =
            file.name;

        openedFilePath =
            file.path;

        selectedColor = null;
        selectedX = null;
        selectedY = null;

        mask = null;

        tolerance = 20.0;
        softness = 10.0;

        connectedOnly = false;

        correction =
            const CmykCorrection();

        brightness = 0.0;
        contrast = 0.0;
        saturation = 0.0;

        showBefore = false;
        showMask = true;

        history.clear();
        historyIndex = -1;

        processing = false;

        statusMessage =
            'Изображение загружено';
      });

      await _addHistoryPoint(
        'Открытие изображения',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка открытия: $e';
      });
    }
  }

  // ============================================================
  // HISTORY
  // ============================================================

  Future<void> _addHistoryPoint(
    String label,
  ) async {
    final image =
        processedImage;

    if (image == null) {
      return;
    }

    final snapshot =
        _createSnapshot(label);

    if (historyIndex <
        history.length - 1) {
      history.removeRange(
        historyIndex + 1,
        history.length,
      );
    }

    history.add(snapshot);

    historyIndex =
        history.length - 1;

    if (history.length > 20) {
      history.removeAt(0);
      historyIndex =
          history.length - 1;
    }

    await Future<void>.delayed(
      Duration.zero,
    );
  }

  _HistorySnapshot _createSnapshot(
    String label,
  ) {
    return _HistorySnapshot(
      label: label,
      image: processedImage!.clone(),
      color: selectedColor,
      x: selectedX,
      y: selectedY,
      tolerance: tolerance,
      softness: softness,
      connectedOnly: connectedOnly,
      correction: correction,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      mask: mask?.copy(),
      time: _currentTime(),
    );
  }

  String _currentTime() {
    final now =
        DateTime.now();

    final hour =
        now.hour.toString().padLeft(2, '0');

    final minute =
        now.minute.toString().padLeft(2, '0');

    final second =
        now.second.toString().padLeft(2, '0');

    return '$hour:$minute:$second';
  }

  // ============================================================
  // UNDO
  // ============================================================

  Future<void> _undo() async {
    if (processing) {
      return;
    }

    if (historyIndex <= 0) {
      return;
    }

    await _restoreHistory(
      historyIndex - 1,
    );
  }

  // ============================================================
  // REDO
  // ============================================================

  Future<void> _redo() async {
    if (processing) {
      return;
    }

    if (historyIndex >=
        history.length - 1) {
      return;
    }

    await _restoreHistory(
      historyIndex + 1,
    );
  }

  // ============================================================
  // SMALL DELAY
  // ============================================================

  Future<void> _smallDelay() async {
    await Future<void>.delayed(
      const Duration(
        milliseconds: 10,
      ),
    );
  }

  // ============================================================
  // CLAMP
  // ============================================================

  double _clamp01(
    double value,
  ) {
    if (value < 0) {
      return 0;
    }

    if (value > 1) {
      return 1;
    }

    return value;
  }

  // ============================================================
  // STATUS
  // ============================================================

  void _setStatus(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    setState(() {
      statusMessage =
          message;
    });

    _statusTimer?.cancel();

    _statusTimer =
        Timer(
      const Duration(
        seconds: 5,
      ),
      () {
        if (!mounted) {
          return;
        }

        setState(() {
          if (originalImage == null) {
            statusMessage =
                'Откройте изображение для начала работы';
          } else {
            statusMessage =
                'Готово';
          }
        });
      },
    );
  }  // ============================================================
  // MASK GENERATION
  // ============================================================

  Future<void> _generateMask() async {
    final image = originalImage;
    final color = selectedColor;

    if (image == null || color == null) {
      if (mounted) {
        setState(() {
          mask = null;
          statusMessage =
              'Сначала выберите цвет на изображении';
        });
      }
      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Создание маски...';
    });

    await _smallDelay();

    try {
      final selection = ColorSelection(
        color: color,
        tolerance: tolerance,
        softness: softness,
        connectedOnly: connectedOnly,
      );

      final generatedMask =
          await compute(
        _generateMaskTask,
        _MaskTask(
          image: image.clone(),
          selection: selection,
          tapX: selectedX,
          tapY: selectedY,
        ),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        mask = generatedMask;
        processing = false;
        statusMessage =
            'Маска создана: '
            '${generatedMask.selectedPercentage.toStringAsFixed(2)}% изображения';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка создания маски: $e';
      });
    }
  }

  // ============================================================
  // REBUILD CURRENT MASK
  // ============================================================

  Future<void> _rebuildCurrentMask() async {
    if (originalImage == null ||
        selectedColor == null) {
      return;
    }

    await _generateMask();

    if (!mounted ||
        mask == null) {
      return;
    }

    await _processImage();
  }

  // ============================================================
  // PROCESS IMAGE
  // ============================================================

  Future<void> _processImage() async {
    final source = originalImage;
    final currentMask = mask;

    if (source == null) {
      return;
    }

    if (currentMask == null) {
      if (mounted) {
        setState(() {
          processedImage =
              source.clone();
        });
      }

      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Обработка изображения...';
    });

    await _smallDelay();

    try {
      final result =
          await compute(
        _processCmykTask,
        _CmykTask(
          image: source.clone(),
          mask: currentMask.copy(),
          correction: correction,
        ),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        processedImage = result;
        processing = false;
        statusMessage =
            'Обработка завершена';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка обработки: $e';
      });
    }
  }

  // ============================================================
  // REPROCESS CURRENT SETTINGS
  // ============================================================

  Future<void> _reprocessFromCurrentSettings() async {
    if (originalImage == null) {
      return;
    }

    if (selectedColor != null) {
      await _generateMask();

      if (mask != null) {
        await _processImage();
      }
    } else {
      await _applyGlobalAdjustments();
    }
  }

  // ============================================================
  // GLOBAL ADJUSTMENTS
  // ============================================================

  Future<void> _applyGlobalAdjustments() async {
    final source = originalImage;

    if (source == null) {
      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Применение общих настроек...';
    });

    await _smallDelay();

    try {
      final result =
          source.clone();

      for (var y = 0;
          y < result.height;
          y++) {
        for (var x = 0;
            x < result.width;
            x++) {
          final pixel =
              source.getPixel(x, y);

          var r =
              pixel.r.toDouble();

          var g =
              pixel.g.toDouble();

          var b =
              pixel.b.toDouble();

          // ------------------------------------------------------
          // BRIGHTNESS
          // ------------------------------------------------------

          final brightnessValue =
              brightness * 2.55;

          r += brightnessValue;
          g += brightnessValue;
          b += brightnessValue;

          // ------------------------------------------------------
          // CONTRAST
          // ------------------------------------------------------

          final contrastFactor =
              (259.0 *
                      (contrast + 255.0)) /
                  (255.0 *
                      (259.0 - contrast));

          r = contrastFactor *
                  (r - 128.0) +
              128.0;

          g = contrastFactor *
                  (g - 128.0) +
              128.0;

          b = contrastFactor *
                  (b - 128.0) +
              128.0;

          // ------------------------------------------------------
          // SATURATION
          // ------------------------------------------------------

          final gray =
              0.299 * r +
                  0.587 * g +
                  0.114 * b;

          final saturationFactor =
              1.0 +
                  saturation / 100.0;

          r = gray +
              (r - gray) *
                  saturationFactor;

          g = gray +
              (g - gray) *
                  saturationFactor;

          b = gray +
              (b - gray) *
                  saturationFactor;

          result.setPixelRgba(
            x,
            y,
            r.round().clamp(
              0,
              255,
            ),
            g.round().clamp(
              0,
              255,
            ),
            b.round().clamp(
              0,
              255,
            ),
            pixel.a
                .toInt()
                .clamp(
                  0,
                  255,
                ),
          );
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        processedImage =
            result;

        processing = false;

        statusMessage =
            'Общие настройки применены';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка обработки: $e';
      });
    }
  }

  // ============================================================
  // APPLY CMYK CHANGES
  // ============================================================

  Future<void> _applyCmykChanges() async {
    if (originalImage == null) {
      return;
    }

    if (mask == null) {
      if (mounted) {
        setState(() {
          statusMessage =
              'Сначала выберите область для коррекции';
        });
      }

      return;
    }

    await _processImage();

    if (!mounted) {
      return;
    }

    await _addHistoryPoint(
      'CMYK коррекция',
    );
  }

  // ============================================================
  // RESET CMYK
  // ============================================================

  Future<void> _resetCmyk() async {
    if (originalImage == null ||
        processing) {
      return;
    }

    setState(() {
      correction =
          const CmykCorrection();
    });

    await _processImage();

    if (!mounted) {
      return;
    }

    await _addHistoryPoint(
      'Сброс CMYK',
    );
  }

  // ============================================================
  // APPLY GLOBAL CHANGES
  // ============================================================

  Future<void> _applyGlobalChanges() async {
    if (originalImage == null ||
        processing) {
      return;
    }

    await _applyGlobalAdjustments();

    if (!mounted) {
      return;
    }

    await _addHistoryPoint(
      'Общая коррекция',
    );
  }

  // ============================================================
  // RESET GLOBAL
  // ============================================================

  Future<void> _resetGlobal() async {
    if (originalImage == null ||
        processing) {
      return;
    }

    setState(() {
      brightness = 0;
      contrast = 0;
      saturation = 0;
    });

    if (selectedColor != null &&
        mask != null) {
      await _processImage();
    } else {
      await _applyGlobalAdjustments();
    }

    if (!mounted) {
      return;
    }

    await _addHistoryPoint(
      'Сброс общих настроек',
    );
  }

  // ============================================================
  // PICK COLOR
  // ============================================================

  Future<void> _pickColorAt(
    int x,
    int y,
  ) async {
    final image =
        originalImage;

    if (image == null ||
        processing) {
      return;
    }

    final color =
        ColorDetector.pickColor(
      image,
      x,
      y,
    );

    if (color == null) {
      return;
    }

    setState(() {
      selectedColor = color;
      selectedX = x;
      selectedY = y;

      statusMessage =
          'Выбран цвет ${color.hex}';
    });

    await _generateMask();

    if (!mounted ||
        mask == null) {
      return;
    }

    await _processImage();

    if (!mounted) {
      return;
    }

    await _addHistoryPoint(
      'Выбор цвета ${color.hex}',
    );
  }

  // ============================================================
  // IMAGE COORDINATES
  // ============================================================

  Offset? _imagePointFromLocalPosition(
    Offset localPosition,
    Size displaySize,
  ) {
    final image =
        originalImage;

    if (image == null) {
      return null;
    }

    if (displaySize.width <= 0 ||
        displaySize.height <= 0) {
      return null;
    }

    final scaleX =
        image.width /
            displaySize.width;

    final scaleY =
        image.height /
            displaySize.height;

    final x =
        (localPosition.dx * scaleX)
            .floor();

    final y =
        (localPosition.dy * scaleY)
            .floor();

    if (x < 0 ||
        y < 0 ||
        x >= image.width ||
        y >= image.height) {
      return null;
    }

    return Offset(
      x.toDouble(),
      y.toDouble(),
    );
  }

  // ============================================================
  // EXPORT IMAGE
  // ============================================================

  Future<void> _exportImage() async {
    final image =
        processedImage;

    if (image == null ||
        exporting) {
      return;
    }

    setState(() {
      exporting = true;
      statusMessage =
          'Подготовка экспорта...';
    });

    try {
      final bytes =
          await compute(
        _encodePng,
        image.clone(),
      );

      final name =
          _baseName(
        openedFileName ??
            'corrected_image',
      );

      final fileName =
          '${name}_corrected.png';

      final path =
          await FilePicker.saveFile(
        dialogTitle:
            'Экспорт изображения',
        fileName:
            fileName,
        bytes:
            bytes,
        type:
            FileType.custom,
        allowedExtensions:
            <String>['png'],
      );

      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;

        if (path == null) {
          statusMessage =
              'Экспорт отменён';
        } else {
          statusMessage =
              'Изображение экспортировано';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;
        statusMessage =
            'Ошибка экспорта: $e';
      });
    }
  }

  // ============================================================
  // BASE NAME
  // ============================================================

  String _baseName(
    String name,
  ) {
    var result = name;

    final dot =
        result.lastIndexOf('.');

    if (dot > 0) {
      result =
          result.substring(
        0,
        dot,
      );
    }

    result = result.trim();

    if (result.isEmpty) {
      return 'image';
    }

    return result;
  }
    // ============================================================
  // PROJECT DATA
  // ============================================================

  Map<String, dynamic> _projectData() {
    final image = originalImage;

    return <String, dynamic>{
      'app': 'Print Color App',
      'version': 1,
      'file': openedFileName,
      'image': _imageInfo(image),
      'selection': <String, dynamic>{
        'color': selectedColor == null
            ? null
            : <String, dynamic>{
                'r': selectedColor!.r,
                'g': selectedColor!.g,
                'b': selectedColor!.b,
                'hex': selectedColor!.hex,
              },
        'x': selectedX,
        'y': selectedY,
        'tolerance': tolerance,
        'softness': softness,
        'connectedOnly': connectedOnly,
      },
      'cmyk': <String, dynamic>{
        'cyan': correction.cyan,
        'magenta': correction.magenta,
        'yellow': correction.yellow,
        'black': correction.black,
      },
      'global': <String, dynamic>{
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
      },
      'mask': mask == null
          ? null
          : <String, dynamic>{
              'width': mask!.width,
              'height': mask!.height,
              'selectedPixels':
                  mask!.selectedPixels,
              'selectedPercentage':
                  mask!.selectedPercentage,
            },
    };
  }

  String _projectJson() {
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(
      _projectData(),
    );
  }

  // ============================================================
  // PREVIEW PANEL
  // ============================================================

  Widget _buildPreviewPanel() {
    final image =
        showBefore
            ? originalImage
            : processedImage;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildPreviewToolbar(),

          Expanded(
            child: image == null
                ? _buildEmptyPreview()
                : _buildInteractiveImage(
                    image,
                  ),
          ),

          _buildPreviewStatus(),
        ],
      ),
    );
  }

  // ============================================================
  // EMPTY PREVIEW
  // ============================================================

  Widget _buildEmptyPreview() {
    return const Center(
      child: Column(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 64,
          ),
          SizedBox(
            height: 12,
          ),
          Text(
            'Изображение не загружено',
          ),
          SizedBox(
            height: 6,
          ),
          Text(
            'Нажмите «Открыть»',
          ),
        ],
      ),
    );
  }

  // ============================================================
  // PREVIEW TOOLBAR
  // ============================================================

  Widget _buildPreviewToolbar() {
    final image =
        showBefore
            ? originalImage
            : processedImage;

    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.preview,
            size: 20,
          ),
          const SizedBox(
            width: 8,
          ),
          Expanded(
            child: Text(
              showBefore
                  ? 'До коррекции'
                  : 'После коррекции',
              style: const TextStyle(
                fontWeight:
                    FontWeight.w600,
              ),
            ),
          ),
          if (image != null)
            Text(
              '${image.width} × ${image.height}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall,
            ),
        ],
      ),
    );
  }

  // ============================================================
  // INTERACTIVE IMAGE
  // ============================================================

  Widget _buildInteractiveImage(
    img.Image image,
  ) {
    final imageBytes =
        Uint8List.fromList(
      img.encodePng(image),
    );

    return LayoutBuilder(
      builder: (
        context,
        constraints,
      ) {
        final maxWidth =
            constraints.maxWidth;

        final maxHeight =
            constraints.maxHeight;

        if (maxWidth <= 0 ||
            maxHeight <= 0) {
          return const SizedBox();
        }

        final imageRatio =
            image.width /
                image.height;

        final containerRatio =
            maxWidth /
                maxHeight;

        late double displayWidth;
        late double displayHeight;

        if (imageRatio >
            containerRatio) {
          displayWidth =
              maxWidth;

          displayHeight =
              maxWidth /
                  imageRatio;
        } else {
          displayHeight =
              maxHeight;

          displayWidth =
              maxHeight *
                  imageRatio;
        }

        final displaySize =
            Size(
          displayWidth,
          displayHeight,
        );

        return Center(
          child: GestureDetector(
            behavior:
                HitTestBehavior.opaque,
            onTapUp: (details) async {
              if (showBefore ||
                  processing) {
                return;
              }

              final point =
                  _imagePointFromLocalPosition(
                details.localPosition,
                displaySize,
              );

              if (point == null) {
                return;
              }

              await _pickColorAt(
                point.dx.round(),
                point.dy.round(),
              );
            },
            child: SizedBox(
              width:
                  displayWidth,
              height:
                  displayHeight,
              child: Stack(
                fit:
                    StackFit.expand,
                children: [
                  Image.memory(
                    imageBytes,
                    fit:
                        BoxFit.fill,
                    filterQuality:
                        FilterQuality.high,
                  ),

                  if (showMask &&
                      !showBefore &&
                      mask != null)
                    _buildMaskOverlay(
                      displaySize,
                    ),

                  if (!showBefore &&
                      selectedX != null &&
                      selectedY != null)
                    _buildSelectionPoint(
                      displaySize,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // SELECTION POINT
  // ============================================================

  Widget _buildSelectionPoint(
    Size displaySize,
  ) {
    final image =
        originalImage;

    if (image == null ||
        selectedX == null ||
        selectedY == null) {
      return const SizedBox();
    }

    final x =
        selectedX! /
            image.width *
            displaySize.width;

    final y =
        selectedY! /
            image.height *
            displaySize.height;

    return Positioned(
      left:
          x - 10,
      top:
          y - 10,
      child: IgnorePointer(
        child: Container(
          width: 20,
          height: 20,
          decoration:
              BoxDecoration(
            shape:
                BoxShape.circle,
            border: Border.all(
              width: 2,
              color:
                  Colors.white,
            ),
            boxShadow: const [
              BoxShadow(
                blurRadius: 4,
                spreadRadius: 1,
                color:
                    Colors.black,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // MASK OVERLAY
  // ============================================================

  Widget _buildMaskOverlay(
    Size displaySize,
  ) {
    final currentMask =
        mask;

    if (currentMask == null) {
      return const SizedBox();
    }

    final width =
        currentMask.width;

    final height =
        currentMask.height;

    if (width <= 0 ||
        height <= 0) {
      return const SizedBox();
    }

    final bytes =
        Uint8List(
      width *
          height *
          4,
    );

    var offset = 0;

    for (var i = 0;
        i < currentMask.values.length;
        i++) {
      final value =
          currentMask.values[i];

      if (value == 0) {
        bytes[offset++] = 0;
        bytes[offset++] = 0;
        bytes[offset++] = 0;
        bytes[offset++] = 0;
        continue;
      }

      bytes[offset++] = 255;
      bytes[offset++] = 0;
      bytes[offset++] = 0;
      bytes[offset++] =
          (value * 0.35).round().clamp(
                0,
                255,
              );
    }

    final overlay =
        img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    final overlayBytes =
        Uint8List.fromList(
      img.encodePng(
        overlay,
      ),
    );

    return IgnorePointer(
      child: Image.memory(
        overlayBytes,
        width:
            displaySize.width,
        height:
            displaySize.height,
        fit:
            BoxFit.fill,
        filterQuality:
            FilterQuality.low,
      ),
    );
  }

  // ============================================================
  // PREVIEW STATUS
  // ============================================================

  Widget _buildPreviewStatus() {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 7,
      ),
      child: Row(
        children: [
          if (processing)
            const SizedBox(
              width: 16,
              height: 16,
              child:
                  CircularProgressIndicator(
                strokeWidth: 2,
              ),
            )
          else
            const Icon(
              Icons.check_circle_outline,
              size: 17,
            ),

          const SizedBox(
            width: 8,
          ),

          Expanded(
            child: Text(
              statusMessage,
              maxLines: 2,
              overflow:
                  TextOverflow.ellipsis,
            ),
          ),

          if (mask != null)
            Text(
              '${mask!.selectedPercentage.toStringAsFixed(1)}%',
              style: const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // BEFORE / AFTER BUTTON
  // ============================================================

  Widget _buildBeforeAfterButton() {
    return OutlinedButton.icon(
      onPressed:
          originalImage == null ||
                  processing
              ? null
              : () {
                  setState(() {
                    showBefore =
                        !showBefore;
                  });
                },
      icon: const Icon(
        Icons.compare,
      ),
      label: Text(
        showBefore
            ? 'Показать после'
            : 'Показать до',
      ),
    );
  }

  // ============================================================
  // EDITOR LAYOUT
  // ============================================================

  Widget _buildEditorLayout() {
    return LayoutBuilder(
      builder: (
        context,
        constraints,
      ) {
        if (constraints.maxWidth >=
            900) {
          return Row(
            children: [
              Expanded(
                child:
                    _buildPreviewPanel(),
              ),
              const SizedBox(
                width: 8,
              ),
              SizedBox(
                width: 390,
                child:
                    _buildControlsPanel(),
              ),
            ],
          );
        }

        return Column(
          children: [
            Expanded(
              flex: 5,
              child:
                  _buildPreviewPanel(),
            ),
            const SizedBox(
              height: 8,
            ),
            Expanded(
              flex: 6,
              child:
                  _buildControlsPanel(),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // EMPTY STATE
  // ============================================================

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding:
            const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.palette_outlined,
              size: 90,
            ),

            const SizedBox(
              height: 20,
            ),

            const Text(
              'Print Color App',
              style: TextStyle(
                fontSize: 28,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            const SizedBox(
              height: 10,
            ),

            const Text(
              'CMYK коррекция цветов '
              'для печатных изображений',
              textAlign:
                  TextAlign.center,
            ),

            const SizedBox(
              height: 24,
            ),

            FilledButton.icon(
              onPressed:
                  processing
                      ? null
                      : _openImage,
              icon: const Icon(
                Icons.folder_open,
              ),
              label: const Text(
                'Открыть изображение',
              ),
            ),

            const SizedBox(
              height: 12,
            ),

            OutlinedButton.icon(
              onPressed:
                  _showHelp,
              icon: const Icon(
                Icons.help_outline,
              ),
              label:
                  const Text('Как работать'),
            ),
          ],
        ),
      ),
    );
  }  // ============================================================
  // SELECTION SECTION
  // ============================================================

  Widget _buildSelectionSection() {
    final color = selectedColor;

    return ExpansionTile(
      initiallyExpanded: true,
      leading: const Icon(
        Icons.colorize,
      ),
      title: const Text(
        'Выбор цвета',
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16,
      ),
      children: [
        if (color == null)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius:
                  BorderRadius.circular(10),
              border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .outline,
              ),
            ),
            child: const Text(
              'Нажмите на нужный цвет '
              'непосредственно на изображении.',
            ),
          )
        else
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration:
                    BoxDecoration(
                  color: Color.fromARGB(
                    255,
                    color.r,
                    color.g,
                    color.b,
                  ),
                  borderRadius:
                      BorderRadius.circular(
                    8,
                  ),
                  border: Border.all(
                    color: Colors.white54,
                  ),
                ),
              ),
              const SizedBox(
                width: 12,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Выбранный цвет',
                      style: TextStyle(
                        fontWeight:
                            FontWeight.w600,
                      ),
                    ),
                    const SizedBox(
                      height: 3,
                    ),
                    Text(
                      color.hex,
                      style:
                          const TextStyle(
                        fontFamily:
                            'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip:
                    'Очистить выбор',
                onPressed:
                    processing
                        ? null
                        : _clearSelection,
                icon: const Icon(
                  Icons.clear,
                ),
              ),
            ],
          ),

        const SizedBox(
          height: 14,
        ),

        _buildRangeSlider(
          title: 'Диапазон',
          value: tolerance,
          min: 0,
          max: 100,
          divisions: 100,
          valueLabel:
              '${tolerance.round()}%',
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        tolerance =
                            value;
                      });
                    },
          onChangeEnd:
              processing
                  ? null
                  : (_) async {
                      await _selectionSettingsChanged();
                    },
        ),

        _buildRangeSlider(
          title: 'Мягкость края',
          value: softness,
          min: 0,
          max: 100,
          divisions: 100,
          valueLabel:
              '${softness.round()}%',
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        softness =
                            value;
                      });
                    },
          onChangeEnd:
              processing
                  ? null
                  : (_) async {
                      await _selectionSettingsChanged();
                    },
        ),

        SwitchListTile(
          contentPadding:
              EdgeInsets.zero,
          title: const Text(
            'Связанная область',
          ),
          subtitle: const Text(
            'Изменять только соседнюю '
            'область выбранного цвета',
          ),
          value: connectedOnly,
          onChanged:
              processing
                  ? null
                  : (value) async {
                      setState(() {
                        connectedOnly =
                            value;
                      });

                      await _selectionSettingsChanged();
                    },
        ),

        const SizedBox(
          height: 4,
        ),

        Row(
          children: [
            Expanded(
              child: _buildBeforeAfterButton(),
            ),
            const SizedBox(
              width: 8,
            ),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    processing ||
                            selectedColor ==
                                null
                        ? null
                        : _generateMask,
                icon: const Icon(
                  Icons.refresh,
                ),
                label: const Text(
                  'Обновить',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // CLEAR SELECTION
  // ============================================================

  Future<void> _clearSelection() async {
    if (processing) {
      return;
    }

    setState(() {
      selectedColor = null;
      selectedX = null;
      selectedY = null;
      mask = null;

      processedImage =
          originalImage?.clone();

      statusMessage =
          'Выделение очищено';
    });

    if (originalImage != null) {
      await _addHistoryPoint(
        'Очистка выделения',
      );
    }
  }

  // ============================================================
  // SELECTION SETTINGS CHANGED
  // ============================================================

  Future<void> _selectionSettingsChanged() async {
    if (originalImage == null ||
        selectedColor == null ||
        processing) {
      return;
    }

    await _generateMask();

    if (!mounted ||
        mask == null) {
      return;
    }

    await _processImage();

    if (!mounted) {
      return;
    }

    await _addHistoryPoint(
      'Изменение выделения',
    );
  }

  // ============================================================
  // RANGE SLIDER
  // ============================================================

  Widget _buildRangeSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double>?
        onChanged,
    required ValueChanged<double>?
        onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight:
                      FontWeight.w500,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .primary,
                fontWeight:
                    FontWeight.w600,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(
            min,
            max,
          ),
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  // ============================================================
  // CMYK SECTION
  // ============================================================

  Widget _buildCmykSection() {
    return ExpansionTile(
      initiallyExpanded: true,
      leading: const Icon(
        Icons.tune,
      ),
      title: const Text(
        'CMYK коррекция',
      ),
      subtitle: Text(
        _cmykSummary(),
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16,
      ),
      children: [
        _buildCmykSlider(
          label: 'Cyan',
          value: correction.cyan,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        correction =
                            correction.copyWith(
                          cyan: value,
                        );
                      });
                    },
        ),

        _buildCmykSlider(
          label: 'Magenta',
          value: correction.magenta,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        correction =
                            correction.copyWith(
                          magenta: value,
                        );
                      });
                    },
        ),

        _buildCmykSlider(
          label: 'Yellow',
          value: correction.yellow,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        correction =
                            correction.copyWith(
                          yellow: value,
                        );
                      });
                    },
        ),

        _buildCmykSlider(
          label: 'Black',
          value: correction.black,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        correction =
                            correction.copyWith(
                          black: value,
                        );
                      });
                    },
        ),

        const SizedBox(
          height: 8,
        ),

        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    processing ||
                            mask == null
                        ? null
                        : _applyCmykChanges,
                icon: const Icon(
                  Icons.check,
                ),
                label: const Text(
                  'Применить CMYK',
                ),
              ),
            ),
            const SizedBox(
              width: 8,
            ),
            OutlinedButton(
              onPressed:
                  processing
                      ? null
                      : _resetCmyk,
              child:
                  const Text('Сброс'),
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // CMYK SUMMARY
  // ============================================================

  String _cmykSummary() {
    return 'C ${correction.cyan.round()}  '
        'M ${correction.magenta.round()}  '
        'Y ${correction.yellow.round()}  '
        'K ${correction.black.round()}';
  }

  // ============================================================
  // CMYK SLIDER
  // ============================================================

  Widget _buildCmykSlider({
    required String label,
    required double value,
    required ValueChanged<double>?
        onChanged,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight:
                      FontWeight.w500,
                ),
              ),
            ),
            Text(
              '${value >= 0 ? '+' : ''}'
              '${value.round()}',
              style: const TextStyle(
                fontFamily:
                    'monospace',
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(
            -100.0,
            100.0,
          ),
          min: -100,
          max: 100,
          divisions: 200,
          label:
              value.round().toString(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  // ============================================================
  // GLOBAL SECTION
  // ============================================================

  Widget _buildGlobalSection() {
    return ExpansionTile(
      leading: const Icon(
        Icons.auto_fix_high,
      ),
      title: const Text(
        'Общая коррекция',
      ),
      subtitle: const Text(
        'Применяется ко всему изображению',
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16,
      ),
      children: [
        _buildGlobalSlider(
          label: 'Яркость',
          value: brightness,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        brightness =
                            value;
                      });
                    },
        ),

        _buildGlobalSlider(
          label: 'Контраст',
          value: contrast,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        contrast =
                            value;
                      });
                    },
        ),

        _buildGlobalSlider(
          label: 'Насыщенность',
          value: saturation,
          onChanged:
              processing
                  ? null
                  : (value) {
                      setState(() {
                        saturation =
                            value;
                      });
                    },
        ),

        const SizedBox(
          height: 8,
        ),

        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    processing
                        ? null
                        : _applyGlobalChanges,
                icon: const Icon(
                  Icons.check,
                ),
                label: const Text(
                  'Применить',
                ),
              ),
            ),
            const SizedBox(
              width: 8,
            ),
            OutlinedButton(
              onPressed:
                  processing
                      ? null
                      : _resetGlobal,
              child:
                  const Text('Сброс'),
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // GLOBAL SLIDER
  // ============================================================

  Widget _buildGlobalSlider({
    required String label,
    required double value,
    required ValueChanged<double>?
        onChanged,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
              ),
            ),
            Text(
              '${value >= 0 ? '+' : ''}'
              '${value.round()}',
              style: const TextStyle(
                fontFamily:
                    'monospace',
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(
            -100.0,
            100.0,
          ),
          min: -100,
          max: 100,
          divisions: 200,
          label:
              value.round().toString(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  // ============================================================
  // COMPARISON SECTION
  // ============================================================

  Widget _buildComparisonSection() {
    return ExpansionTile(
      leading: const Icon(
        Icons.compare,
      ),
      title: const Text(
        'Предпросмотр',
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child:
                  _buildBeforeAfterButton(),
            ),
            const SizedBox(
              width: 8,
            ),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    originalImage ==
                                null ||
                            processing
                        ? null
                        : () {
                            setState(() {
                              showMask =
                                  !showMask;
                            });
                          },
                icon: Icon(
                  showMask
                      ? Icons.visibility
                      : Icons.visibility_off,
                ),
                label: Text(
                  showMask
                      ? 'Маска'
                      : 'Без маски',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }  // ============================================================
  // HISTORY SECTION
  // ============================================================

  Widget _buildHistorySection() {
    return ExpansionTile(
      leading: const Icon(
        Icons.history,
      ),
      title: const Text(
        'История изменений',
      ),
      subtitle: Text(
        history.isEmpty
            ? 'Нет изменений'
            : '${history.length} записей',
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16,
      ),
      children: [
        if (history.isEmpty)
          const Padding(
            padding:
                EdgeInsets.symmetric(
              vertical: 12,
            ),
            child: Text(
              'История появится после '
              'изменения изображения.',
            ),
          )
        else
          Column(
            children: [
              ...List.generate(
                history.length,
                (index) {
                  final item =
                      history[index];

                  final active =
                      index ==
                          historyIndex;

                  return ListTile(
                    dense: true,
                    contentPadding:
                        EdgeInsets.zero,
                    selected: active,
                    leading: Icon(
                      active
                          ? Icons
                              .radio_button_checked
                          : Icons
                              .radio_button_unchecked,
                    ),
                    title: Text(
                      item.label,
                    ),
                    subtitle: Text(
                      item.time,
                    ),
                    onTap:
                        processing
                            ? null
                            : () =>
                                _restoreHistory(
                                  index,
                                ),
                  );
                },
              ),

              const SizedBox(
                height: 8,
              ),

              Row(
                children: [
                  Expanded(
                    child:
                        OutlinedButton.icon(
                      onPressed:
                          processing ||
                                  historyIndex <=
                                      0
                              ? null
                              : _undo,
                      icon: const Icon(
                        Icons.undo,
                      ),
                      label:
                          const Text(
                        'Назад',
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child:
                        OutlinedButton.icon(
                      onPressed:
                          processing ||
                                  historyIndex >=
                                      history.length -
                                          1
                              ? null
                              : _redo,
                      icon: const Icon(
                        Icons.redo,
                      ),
                      label:
                          const Text(
                        'Вперёд',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  // ============================================================
  // RESTORE HISTORY
  // ============================================================

  Future<void> _restoreHistory(
    int index,
  ) async {
    if (processing ||
        index < 0 ||
        index >= history.length) {
      return;
    }

    final snapshot =
        history[index];

    setState(() {
      processing = true;
      statusMessage =
          'Восстановление истории...';
    });

    await _smallDelay();

    try {
      final restoredImage =
          snapshot.image.clone();

      if (!mounted) {
        return;
      }

      setState(() {
        processedImage =
            restoredImage;

        selectedColor =
            snapshot.color;

        selectedX =
            snapshot.x;

        selectedY =
            snapshot.y;

        tolerance =
            snapshot.tolerance;

        softness =
            snapshot.softness;

        connectedOnly =
            snapshot.connectedOnly;

        correction =
            snapshot.correction;

        brightness =
            snapshot.brightness;

        contrast =
            snapshot.contrast;

        saturation =
            snapshot.saturation;

        mask =
            snapshot.mask?.copy();

        historyIndex =
            index;

        processing = false;

        statusMessage =
            'Восстановлено: '
            '${snapshot.label}';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка восстановления: $e';
      });
    }
  }

  // ============================================================
  // PROJECT SAVE
  // ============================================================

  Future<void> _saveProject() async {
    if (originalImage == null ||
        exporting) {
      return;
    }

    setState(() {
      exporting = true;
      statusMessage =
          'Сохранение проекта...';
    });

    try {
      final projectJson =
          _projectJson();

      final bytes =
          Uint8List.fromList(
        utf8.encode(
          projectJson,
        ),
      );

      final baseName =
          _baseName(
        openedFileName ??
            'print_project',
      );

      final fileName =
          '$baseName.printproject.json';

      final path =
          await FilePicker.saveFile(
        dialogTitle:
            'Сохранить проект',
        fileName:
            fileName,
        bytes:
            bytes,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;

        if (path == null) {
          statusMessage =
              'Сохранение отменено';
        } else {
          statusMessage =
              'Проект сохранён';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;
        statusMessage =
            'Ошибка сохранения проекта: $e';
      });
    }
  }

  // ============================================================
  // PROJECT INFORMATION
  // ============================================================

  Future<void> _showProjectInfo() async {
    if (originalImage == null) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Информация проекта',
          ),
          content:
              SingleChildScrollView(
            child: SelectableText(
              _projectSummary(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context)
                    .pop();
              },
              child:
                  const Text('Закрыть'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.of(context)
                    .pop();

                await _saveProject();
              },
              icon: const Icon(
                Icons.save,
              ),
              label:
                  const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  String _projectSummary() {
    final buffer =
        StringBuffer();

    buffer.writeln(
      'Print Color App',
    );

    buffer.writeln(
      'Версия проекта: 1',
    );

    if (openedFileName != null) {
      buffer.writeln(
        'Файл: $openedFileName',
      );
    }

    final image =
        originalImage;

    if (image != null) {
      buffer.writeln(
        'Размер: '
        '${image.width} × '
        '${image.height}',
      );
    }

    if (selectedColor != null) {
      buffer.writeln(
        'Выбранный цвет: '
        '${selectedColor!.hex}',
      );
    }

    buffer.writeln(
      'Диапазон: '
      '${tolerance.round()}%',
    );

    buffer.writeln(
      'Мягкость: '
      '${softness.round()}%',
    );

    buffer.writeln(
      'Связанная область: '
      '${connectedOnly ? 'Да' : 'Нет'}',
    );

    buffer.writeln(
      'C: ${correction.cyan.round()}',
    );

    buffer.writeln(
      'M: ${correction.magenta.round()}',
    );

    buffer.writeln(
      'Y: ${correction.yellow.round()}',
    );

    buffer.writeln(
      'K: ${correction.black.round()}',
    );

    buffer.writeln(
      'Яркость: '
      '${brightness.round()}',
    );

    buffer.writeln(
      'Контраст: '
      '${contrast.round()}',
    );

    buffer.writeln(
      'Насыщенность: '
      '${saturation.round()}',
    );

    if (mask != null) {
      buffer.writeln(
        'Выделено: '
        '${mask!.selectedPercentage.toStringAsFixed(2)}%',
      );
    }

    return buffer.toString();
  }

  // ============================================================
  // RESET ALL
  // ============================================================

  Future<void> _resetAll() async {
    final image =
        originalImage;

    if (image == null ||
        processing) {
      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Сброс изменений...';

      selectedColor = null;
      selectedX = null;
      selectedY = null;

      mask = null;

      correction =
          const CmykCorrection();

      brightness = 0;
      contrast = 0;
      saturation = 0;

      tolerance = 20;
      softness = 10;

      connectedOnly = false;

      processedImage =
          image.clone();
    });

    await _smallDelay();

    if (!mounted) {
      return;
    }

    setState(() {
      processing = false;
      statusMessage =
          'Все изменения сброшены';
    });

    await _addHistoryPoint(
      'Полный сброс',
    );
  }

  // ============================================================
  // CLEAR IMAGE
  // ============================================================

  Future<void> _clearImage() async {
    if (processing) {
      return;
    }

    final confirmed =
        await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Закрыть изображение?',
          ),
          content: const Text(
            'Несохранённые изменения '
            'будут удалены.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context)
                    .pop(false);
              },
              child:
                  const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context)
                    .pop(true);
              },
              child:
                  const Text('Закрыть'),
            ),
          ],
        );
      },
    );

    if (confirmed != true ||
        !mounted) {
      return;
    }

    setState(() {
      originalImage = null;
      processedImage = null;
      originalBytes = null;

      openedFileName = null;
      openedFilePath = null;

      selectedColor = null;
      selectedX = null;
      selectedY = null;

      mask = null;

      correction =
          const CmykCorrection();

      tolerance = 20;
      softness = 10;

      connectedOnly = false;

      brightness = 0;
      contrast = 0;
      saturation = 0;

      showBefore = false;
      showMask = true;

      history.clear();
      historyIndex = -1;

      statusMessage =
          'Откройте изображение для начала работы';
    });
  }

  // ============================================================
  // HELP
  // ============================================================

  Future<void> _showHelp() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Как работать',
          ),
          content:
              const SingleChildScrollView(
            child: Text(
              '1. Откройте изображение.\n\n'
              '2. Нажмите на нужный цвет '
              'на изображении.\n\n'
              '3. Настройте диапазон, '
              'чтобы выбрать похожие оттенки.\n\n'
              '4. Настройте мягкость края '
              'для плавного перехода.\n\n'
              '5. Включите «Связанная область», '
              'если нужно выбрать только '
              'соприкасающуюся область.\n\n'
              '6. Настройте C, M, Y и K.\n\n'
              '7. Используйте «До / После» '
              'для проверки результата.\n\n'
              '8. Сохраните проект или '
              'экспортируйте PNG.\n\n'
              'Проект сохраняет настройки '
              'коррекции. Исходное изображение '
              'не встраивается в JSON-файл.\n\n'
              'Важно: закрытый формат '
              'DPCS G5i / RIIN здесь '
              'автоматически не создаётся.',
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(context)
                    .pop();
              },
              child:
                  const Text('Понятно'),
            ),
          ],
        );
      },
    );
  }  // ============================================================
  // CONTROLS PANEL
  // ============================================================

  Widget _buildControlsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context)
                .dividerColor,
          ),
        ),
      ),
      child: SingleChildScrollView(
        padding:
            const EdgeInsets.only(
          bottom: 24,
        ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
          children: [
            _buildSelectionSection(),
            _buildCmykSection(),
            _buildGlobalSection(),
            _buildComparisonSection(),
            _buildHistorySection(),

            const SizedBox(
              height: 8,
            ),

            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton
                        .icon(
                      onPressed:
                          processing
                              ? null
                              : _resetAll,
                      icon: const Icon(
                        Icons.restart_alt,
                      ),
                      label: const Text(
                        'Сбросить всё',
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          originalImage ==
                                      null ||
                                  processing
                              ? null
                              : _exportImage,
                      icon: const Icon(
                        Icons.download,
                      ),
                      label: const Text(
                        'Экспорт',
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(
              height: 8,
            ),

            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton
                        .icon(
                      onPressed:
                          originalImage ==
                                      null ||
                                  exporting
                              ? null
                              : _saveProject,
                      icon: const Icon(
                        Icons.save_outlined,
                      ),
                      label: const Text(
                        'Проект',
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child: OutlinedButton
                        .icon(
                      onPressed:
                          originalImage ==
                                      null ||
                                  processing
                              ? null
                              : _showProjectInfo,
                      icon: const Icon(
                        Icons.info_outline,
                      ),
                      label: const Text(
                        'Инфо',
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(
              height: 8,
            ),

            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
              ),
              child: OutlinedButton.icon(
                onPressed:
                    processing
                        ? null
                        : _showHelp,
                icon: const Icon(
                  Icons.help_outline,
                ),
                label: const Text(
                  'Инструкция',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // IMAGE INFORMATION
  // ============================================================

  Widget _buildImageInfo() {
    final image =
        processedImage ?? originalImage;

    if (image == null) {
      return const SizedBox
          .shrink();
    }

    final selectionText =
        selectedColor == null
            ? 'Цвет не выбран'
            : selectedColor!.hex;

    final maskText =
        mask == null
            ? 'Маска не создана'
            : '${mask!.selectedPercentage.toStringAsFixed(2)}%';

    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 10,
      ),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest,
      child: Wrap(
        spacing: 18,
        runSpacing: 6,
        alignment:
            WrapAlignment.center,
        children: [
          _infoItem(
            Icons.photo_size_select_large,
            '${image.width} × ${image.height}',
          ),
          _infoItem(
            Icons.palette_outlined,
            selectionText,
          ),
          _infoItem(
            Icons.layers_outlined,
            maskText,
          ),
          if (selectedX != null &&
              selectedY != null)
            _infoItem(
              Icons.gps_fixed,
              'X $selectedX  Y $selectedY',
            ),
        ],
      ),
    );
  }

  Widget _infoItem(
    IconData icon,
    String text,
  ) {
    return Row(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
        ),
        const SizedBox(
          width: 5,
        ),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // STATUS BAR
  // ============================================================

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 9,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: Theme.of(context)
                .dividerColor,
          ),
        ),
      ),
      child: Row(
        children: [
          if (processing)
            const SizedBox(
              width: 15,
              height: 15,
              child:
                  CircularProgressIndicator(
                strokeWidth: 2,
              ),
            )
          else
            Icon(
              statusMessage
                      .toLowerCase()
                      .contains('ошиб')
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              size: 16,
            ),

          const SizedBox(
            width: 8,
          ),

          Expanded(
            child: Text(
              statusMessage,
              maxLines: 2,
              overflow:
                  TextOverflow.ellipsis,
              style:
                  const TextStyle(
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // TOOLBAR
  // ============================================================

  PreferredSizeWidget _buildToolbar() {
    return AppBar(
      title: const Text(
        'Print Color App',
      ),
      centerTitle: false,
      actions: [
        IconButton(
          tooltip:
              'Открыть изображение',
          onPressed:
              processing
                  ? null
                  : _openImage,
          icon: const Icon(
            Icons.folder_open,
          ),
        ),

        IconButton(
          tooltip:
              'Сохранить проект',
          onPressed:
              originalImage == null ||
                      exporting
                  ? null
                  : _saveProject,
          icon: const Icon(
            Icons.save,
          ),
        ),

        PopupMenuButton<String>(
          enabled:
              !processing,
          onSelected:
              (value) async {
            switch (value) {
              case 'info':
                await _showProjectInfo();
                break;

              case 'help':
                await _showHelp();
                break;

              case 'clear':
                await _clearImage();
                break;
            }
          },
          itemBuilder:
              (context) => const [
            PopupMenuItem<String>(
              value: 'info',
              child: ListTile(
                leading: Icon(
                  Icons.info_outline,
                ),
                title: Text(
                  'Информация',
                ),
              ),
            ),
            PopupMenuItem<String>(
              value: 'help',
              child: ListTile(
                leading: Icon(
                  Icons.help_outline,
                ),
                title: Text(
                  'Инструкция',
                ),
              ),
            ),
            PopupMenuItem<String>(
              value: 'clear',
              child: ListTile(
                leading: Icon(
                  Icons.close,
                ),
                title: Text(
                  'Закрыть изображение',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // EMPTY STATE
  // ============================================================

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding:
            const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            Icon(
              Icons.image_search,
              size: 82,
              color: Theme.of(context)
                  .colorScheme
                  .primary,
            ),

            const SizedBox(
              height: 20,
            ),

            const Text(
              'Print Color App',
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            const SizedBox(
              height: 10,
            ),

            const Text(
              'Профессиональная коррекция '
              'цвета для печатных изображений',
              textAlign:
                  TextAlign.center,
            ),

            const SizedBox(
              height: 28,
            ),

            FilledButton.icon(
              onPressed:
                  processing
                      ? null
                      : _openImage,
              icon: const Icon(
                Icons.folder_open,
              ),
              label: const Padding(
                padding:
                    EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                child: Text(
                  'Открыть изображение',
                ),
              ),
            ),

            const SizedBox(
              height: 14,
            ),

            OutlinedButton.icon(
              onPressed:
                  processing
                      ? null
                      : _showHelp,
              icon: const Icon(
                Icons.help_outline,
              ),
              label: const Text(
                'Как это работает',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // MAIN BODY
  // ============================================================

  Widget _buildBody() {
    if (originalImage == null) {
      return _buildEmptyState();
    }

    return LayoutBuilder(
      builder:
          (context, constraints) {
        final wide =
            constraints.maxWidth >=
                900;

        if (wide) {
          return Row(
            crossAxisAlignment:
                CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child:
                    _buildPreviewArea(),
              ),
              SizedBox(
                width: 390,
                child:
                    _buildControlsPanel(),
              ),
            ],
          );
        }

        return Column(
          children: [
            Expanded(
              child:
                  _buildPreviewArea(),
            ),
            _buildControlsPanel(),
          ],
        );
      },
    );
  }

  // ============================================================
  // PREVIEW AREA
  // ============================================================

  Widget _buildPreviewArea() {
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: Colors.black,
            child:
                _buildInteractiveImage(),
          ),
        ),

        _buildImageInfo(),

        _buildStatusBar(),
      ],
    );
  }

  // ============================================================
  // KEYBOARD SHORTCUTS
  // ============================================================

  Widget _buildKeyboardShortcuts(
    Widget child,
  ) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator,
          VoidCallback>{
        const SingleActivator(
          LogicalKeyboardKey.keyO,
          control: true,
        ): _openImage,

        const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
        ): () {
          if (originalImage != null) {
            _saveProject();
          }
        },

        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
        ): _undo,

        const SingleActivator(
          LogicalKeyboardKey.keyY,
          control: true,
        ): _redo,

        const SingleActivator(
          LogicalKeyboardKey.escape,
        ): _clearSelection,
      },
      child: Focus(
        autofocus: true,
        child: child,
      ),
    );
  }  // ============================================================
  // HISTORY
  // ============================================================

  Future<void> _addHistoryPoint(
    String label,
  ) async {
    final image =
        processedImage;

    if (image == null) {
      return;
    }

    final snapshot =
        HistorySnapshot(
      label: label,
      image: image.clone(),
      color: selectedColor,
      x: selectedX,
      y: selectedY,
      tolerance: tolerance,
      softness: softness,
      connectedOnly: connectedOnly,
      correction: correction,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      mask: mask?.copy(),
      time: _formatTime(
        DateTime.now(),
      ),
    );

    if (historyIndex <
        history.length - 1) {
      history.removeRange(
        historyIndex + 1,
        history.length,
      );
    }

    history.add(snapshot);

    if (history.length > 30) {
      history.removeAt(0);
    }

    historyIndex =
        history.length - 1;
  }

  void _undo() {
    if (processing ||
        historyIndex <= 0 ||
        history.isEmpty) {
      return;
    }

    _restoreHistory(
      historyIndex - 1,
    );
  }

  void _redo() {
    if (processing ||
        historyIndex >=
            history.length - 1 ||
        history.isEmpty) {
      return;
    }

    _restoreHistory(
      historyIndex + 1,
    );
  }

  // ============================================================
  // PROJECT JSON
  // ============================================================

  String _projectJson() {
    final image =
        originalImage;

    final data =
        <String, dynamic>{
      'format':
          'print_color_app_project',
      'version': 1,
      'fileName':
          openedFileName,
      'filePath':
          openedFilePath,
      'image': image == null
          ? null
          : {
              'width': image.width,
              'height': image.height,
            },
      'selection':
          selectedColor == null
              ? null
              : {
                  'r': selectedColor!.r,
                  'g': selectedColor!.g,
                  'b': selectedColor!.b,
                  'hex':
                      selectedColor!.hex,
                  'x': selectedX,
                  'y': selectedY,
                  'tolerance':
                      tolerance,
                  'softness':
                      softness,
                  'connectedOnly':
                      connectedOnly,
                },
      'cmyk': {
        'cyan':
            correction.cyan,
        'magenta':
            correction.magenta,
        'yellow':
            correction.yellow,
        'black':
            correction.black,
      },
      'global': {
        'brightness':
            brightness,
        'contrast':
            contrast,
        'saturation':
            saturation,
      },
      'mask': mask == null
          ? null
          : {
              'width':
                  mask!.width,
              'height':
                  mask!.height,
              'selectedPixels':
                  mask!.selectedPixels,
              'selectedPercentage':
                  mask!.selectedPercentage,
            },
      'historyLength':
          history.length,
      'historyIndex':
          historyIndex,
      'createdAt':
          DateTime.now()
              .toIso8601String(),
    };

    return const JsonEncoder.withIndent(
      '  ',
    ).convert(data);
  }

  // ============================================================
  // EXPORT
  // ============================================================

  Future<void> _exportImage() async {
    final image =
        processedImage;

    if (image == null ||
        exporting) {
      return;
    }

    setState(() {
      exporting = true;
      statusMessage =
          'Подготовка изображения...';
    });

    try {
      final pngBytes =
          await compute(
        _encodePngTask,
        image,
      );

      final baseName =
          _baseName(
        openedFileName ??
            'corrected_image',
      );

      final path =
          await FilePicker.saveFile(
        dialogTitle:
            'Экспортировать изображение',
        fileName:
            '${baseName}_corrected.png',
        bytes:
            pngBytes,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;

        if (path == null) {
          statusMessage =
              'Экспорт отменён';
        } else {
          statusMessage =
              'Изображение экспортировано';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;
        statusMessage =
            'Ошибка экспорта: $e';
      });
    }
  }

  // ============================================================
  // UTILITIES
  // ============================================================

  String _baseName(
    String name,
  ) {
    final normalized =
        name.replaceAll(
      '\\',
      '/',
    );

    final lastSlash =
        normalized.lastIndexOf('/');

    final fileName =
        lastSlash >= 0
            ? normalized.substring(
                lastSlash + 1,
              )
            : normalized;

    final dot =
        fileName.lastIndexOf('.');

    if (dot <= 0) {
      return fileName;
    }

    return fileName.substring(
      0,
      dot,
    );
  }

  String _formatTime(
    DateTime value,
  ) {
    final hour =
        value.hour
            .toString()
            .padLeft(2, '0');

    final minute =
        value.minute
            .toString()
            .padLeft(2, '0');

    final second =
        value.second
            .toString()
            .padLeft(2, '0');

    return '$hour:$minute:$second';
  }

  Future<void> _smallDelay() async {
    await Future<void>.delayed(
      const Duration(
        milliseconds: 20,
      ),
    );
  }

  // ============================================================
  // LIFECYCLE
  // ============================================================

  @override
  void dispose() {
    super.dispose();
  }
}

// ================================================================
// HISTORY SNAPSHOT
// ================================================================

class HistorySnapshot {
  final String label;
  final img.Image image;

  final RgbColor? color;

  final int? x;
  final int? y;

  final double tolerance;
  final double softness;

  final bool connectedOnly;

  final CmykCorrection correction;

  final double brightness;
  final double contrast;
  final double saturation;

  final MaskData? mask;

  final String time;

  const HistorySnapshot({
    required this.label,
    required this.image,
    required this.color,
    required this.x,
    required this.y,
    required this.tolerance,
    required this.softness,
    required this.connectedOnly,
    required this.correction,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.mask,
    required this.time,
  });
}

// ================================================================
// ISOLATE TASKS
// ================================================================

class _MaskTask {
  final img.Image image;
  final ColorSelection selection;
  final int? tapX;
  final int? tapY;

  const _MaskTask({
    required this.image,
    required this.selection,
    required this.tapX,
    required this.tapY,
  });
}

MaskData _generateMaskTask(
  _MaskTask task,
) {
  return MaskGenerator.generate(
    image: task.image,
    selection: task.selection,
    tapX: task.tapX,
    tapY: task.tapY,
  );
}

// ================================================================
// CMYK TASK
// ================================================================

class _CmykTask {
  final img.Image image;
  final MaskData mask;
  final CmykCorrection correction;

  const _CmykTask({
    required this.image,
    required this.mask,
    required this.correction,
  });
}

img.Image _processCmykTask(
  _CmykTask task,
) {
  return CmykProcessor.applyCorrection(
    source: task.image,
    mask: task.mask,
    correction: task.correction,
  );
}

// ================================================================
// PNG TASK
// ================================================================

Uint8List _encodePngTask(
  img.Image image,
) {
  return Uint8List.fromList(
    img.encodePng(
      image,
    ),
  );
}
