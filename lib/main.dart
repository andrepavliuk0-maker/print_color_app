import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'models/color_selection.dart';
import 'models/mask_data.dart';
import 'services/background_tasks.dart';
import 'services/color_detector.dart';
import 'services/project_file.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const PrintColorApp(),
  );
}

// ============================================================
// APPLICATION
// ============================================================

class PrintColorApp extends StatelessWidget {
  const PrintColorApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Print Color App',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
      ),
      home: const EditorPage(),
    );
  }
}

// ============================================================
// EDITOR PAGE
// ============================================================

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
  });

  @override
  State<EditorPage> createState() =>
      _EditorPageState();
}

// ============================================================
// EDITOR STATE
// ============================================================

class _EditorPageState
    extends State<EditorPage> {
  // ----------------------------------------------------------
  // IMAGES
  // ----------------------------------------------------------

  img.Image? originalImage;
  img.Image? processedImage;

  Uint8List? originalBytes;

  String? openedFileName;
  String? openedFilePath;

  // ----------------------------------------------------------
  // COLOR SELECTION
  // ----------------------------------------------------------

  RgbColor? selectedColor;

  int? selectedX;
  int? selectedY;

  double tolerance = 20.0;
  double softness = 10.0;

  bool connectedOnly = false;

  MaskData? mask;

  // ----------------------------------------------------------
  // PREVIEW CACHES
  // ----------------------------------------------------------

  /// PNG-версия изображения для показа на экране.
  /// Ключ — сам объект изображения, поэтому запись исчезает
  /// вместе с изображением.
  final Expando<Uint8List> _pngCache =
      Expando<Uint8List>();

  /// Готовая картинка предпросмотра маски.
  final Expando<Uint8List> _overlayCache =
      Expando<Uint8List>();

  /// Зум и сдвиг изображения (нужен для точного выбора цвета).
  final TransformationController _viewController =
      TransformationController();

  // ----------------------------------------------------------
  // CMYK
  // ----------------------------------------------------------

  CmykCorrection correction =
      const CmykCorrection();

  // ----------------------------------------------------------
  // GLOBAL IMAGE CORRECTION
  // ----------------------------------------------------------

  double brightness = 0.0;
  double contrast = 0.0;
  double saturation = 0.0;

  // ----------------------------------------------------------
  // PREVIEW
  // ----------------------------------------------------------

  bool showBefore = false;
  bool showMask = false;

  // ----------------------------------------------------------
  // UI STATE
  // ----------------------------------------------------------

  bool processing = false;
  bool exporting = false;

  String statusMessage =
      'Откройте изображение для начала работы';

  // ----------------------------------------------------------
  // HISTORY
  // ----------------------------------------------------------

  static const int _maxHistory = 10;

  final List<_HistorySnapshot> history =
      <_HistorySnapshot>[];

  int historyIndex = -1;

  // ----------------------------------------------------------
  // OPEN IMAGE
  // ----------------------------------------------------------

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
          'gif',
          'tif',
          'tiff',
        ],
      );

      if (result == null ||
          result.isEmpty) {
        return;
      }

      final picked =
          result.first;

      final path =
          picked.path;

      if (path == null ||
          path.isEmpty) {
        _showMessage(
          'Не удалось получить путь к файлу.',
        );
        return;
      }

      setState(() {
        processing = true;
        statusMessage =
            'Загрузка изображения...';
      });

      final bytes =
          await File(path).readAsBytes();

      // Декодирование идёт в фоне и приводит изображение
      // к 8 бит на канал (RGBA).
      final normalized =
          await decodeImageAsync(bytes);

      if (normalized == null) {
        throw Exception(
          'Формат изображения не поддерживается.',
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        originalBytes =
            bytes;

        originalImage =
            normalized;

        processedImage =
            normalized.clone();

        openedFileName =
            picked.name;

        openedFilePath =
            path;

        selectedColor = null;
        selectedX = null;
        selectedY = null;

        tolerance = 20.0;
        softness = 10.0;
        connectedOnly = false;

        correction =
            const CmykCorrection();

        brightness = 0.0;
        contrast = 0.0;
        saturation = 0.0;

        mask = null;

        showBefore = false;
        showMask = false;

        history.clear();
        historyIndex = -1;

        _viewController.value =
            Matrix4.identity();

        processing = false;

        statusMessage =
            'Изображение загружено';
      });

      await _addHistoryPoint(
        'Исходное изображение',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка загрузки: $e';
      });
    }
  }

  // ----------------------------------------------------------
  // COLOR PICK
  // ----------------------------------------------------------

  Future<void> _pickColor(
    int x,
    int y,
  ) async {
    final image =
        originalImage;

    if (image == null ||
        processing) {
      return;
    }

    if (x < 0 ||
        y < 0 ||
        x >= image.width ||
        y >= image.height) {
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
      showMask = true;

      statusMessage =
          'Выбран цвет ${color.hex}';
    });

    await _generateSelection();
  }

  // ----------------------------------------------------------
  // GENERATE SELECTION
  // ----------------------------------------------------------

  Future<void> _generateSelection() async {
    final image =
        originalImage;

    final color =
        selectedColor;

    if (image == null ||
        color == null) {
      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Создание цветовой маски...';
    });

    try {
      final selection =
          ColorSelection(
        color: color,
        tolerance: tolerance,
        softness: softness,
        connectedOnly:
            connectedOnly,
      );

      // Маска и её предпросмотр считаются в фоне.
      final selectionResult =
          await computeSelectionAsync(
        image: image,
        selection: selection,
        tapX: selectedX,
        tapY: selectedY,
      );

      if (!mounted) {
        return;
      }

      final generated =
          selectionResult.mask;

      _overlayCache[generated] =
          selectionResult.overlayPng;

      setState(() {
        mask = generated;
        processing = false;

        statusMessage =
            'Выбрано '
            '${generated.selectedPercentage.toStringAsFixed(2)}% '
            'изображения';
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

  // ----------------------------------------------------------
  // APPLY CMYK
  // ----------------------------------------------------------

  Future<void> _applyCmyk() async {
    final image =
        originalImage;

    final currentMask =
        mask;

    if (image == null ||
        currentMask == null) {
      _showMessage(
        'Сначала выберите цвет.',
      );
      return;
    }

    if (correction.isNeutral) {
      _showMessage(
        'CMYK-коррекция не изменена.',
      );
      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Применение CMYK-коррекции...';
    });

    try {
      final result =
          await applyCmykAsync(
        source:
            processedImage ??
                image,
        mask: currentMask,
        correction: correction,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        processedImage = result;
        processing = false;

        // Коррекция уже записана в изображение. Ползунки
        // сбрасываются, чтобы повторное нажатие «Применить»
        // не накапливало изменение незаметно.
        correction =
            const CmykCorrection();

        statusMessage =
            'CMYK-коррекция применена';
      });

      await _addHistoryPoint(
        'CMYK-коррекция',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка CMYK: $e';
      });
    }
  }

  // ----------------------------------------------------------
  // APPLY GLOBAL CORRECTIONS
  // ----------------------------------------------------------

  Future<void> _applyGlobalCorrections() async {
    final image =
        processedImage ??
            originalImage;

    if (image == null) {
      return;
    }

    if (brightness == 0 &&
        contrast == 0 &&
        saturation == 0) {
      _showMessage(
        'Глобальная коррекция не изменена.',
      );
      return;
    }

    setState(() {
      processing = true;
      statusMessage =
          'Применение общей коррекции...';
    });

    await Future<void>.delayed(
      const Duration(
        milliseconds: 10,
      ),
    );

    try {
      final result =
          await applyGlobalAsync(
        source: image,
        brightness: brightness,
        contrast: contrast,
        saturation: saturation,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        processedImage = result;
        processing = false;

        // Как и в CMYK: после применения ползунки сбрасываются.
        brightness = 0.0;
        contrast = 0.0;
        saturation = 0.0;

        statusMessage =
            'Общая коррекция применена';
      });

      await _addHistoryPoint(
        'Общая коррекция',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка коррекции: $e';
      });
    }
  }

  // ----------------------------------------------------------
  // MESSAGE
  // ----------------------------------------------------------

  void _showMessage(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).hideCurrentSnackBar();

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content:
            Text(message),
      ),
    );
  }  // ============================================================
  // SELECTION SETTINGS
  // ============================================================

  Future<void> _selectionSettingsChanged() async {
    if (selectedColor == null) {
      return;
    }

    await _generateSelection();
  }

  void _clearSelection() {
    if (processing) {
      return;
    }

    setState(() {
      selectedColor = null;
      selectedX = null;
      selectedY = null;
      mask = null;
      showMask = false;

      statusMessage =
          'Выделение очищено';
    });
  }

  // ============================================================
  // CMYK RESET
  // ============================================================

  void _resetCmyk() {
    if (processing) {
      return;
    }

    setState(() {
      correction =
          const CmykCorrection();

      statusMessage =
          'CMYK-настройки сброшены';
    });
  }

  // ============================================================
  // GLOBAL RESET
  // ============================================================

  void _resetGlobal() {
    if (processing) {
      return;
    }

    setState(() {
      brightness = 0.0;
      contrast = 0.0;
      saturation = 0.0;

      statusMessage =
          'Общие настройки сброшены';
    });
  }

  // ============================================================
  // CMYK SLIDER UPDATE
  // ============================================================

  void _setCyan(
    double value,
  ) {
    setState(() {
      correction =
          correction.copyWith(
        cyan: value,
      );
    });
  }

  void _setMagenta(
    double value,
  ) {
    setState(() {
      correction =
          correction.copyWith(
        magenta: value,
      );
    });
  }

  void _setYellow(
    double value,
  ) {
    setState(() {
      correction =
          correction.copyWith(
        yellow: value,
      );
    });
  }

  void _setBlack(
    double value,
  ) {
    setState(() {
      correction =
          correction.copyWith(
        black: value,
      );
    });
  }

  // ============================================================
  // GLOBAL SLIDER UPDATE
  // ============================================================

  void _setBrightness(
    double value,
  ) {
    setState(() {
      brightness = value;
    });
  }

  void _setContrast(
    double value,
  ) {
    setState(() {
      contrast = value;
    });
  }

  void _setSaturation(
    double value,
  ) {
    setState(() {
      saturation = value;
    });
  }

  // ============================================================
  // COLOR CHIP
  // ============================================================

  Widget _buildColorChip() {
    final color =
        selectedColor;

    if (color == null) {
      return Container(
        width: 54,
        height: 54,
        decoration:
            BoxDecoration(
          borderRadius:
              BorderRadius.circular(
            10,
          ),
          border: Border.all(
            color:
                Theme.of(context)
                    .dividerColor,
          ),
        ),
        child: const Icon(
          Icons.colorize,
        ),
      );
    }

    final materialColor =
        Color.fromARGB(
      255,
      color.r,
      color.g,
      color.b,
    );

    return Container(
      width: 54,
      height: 54,
      decoration:
          BoxDecoration(
        color: materialColor,
        borderRadius:
            BorderRadius.circular(
          10,
        ),
        border: Border.all(
          color: Colors.white,
          width: 2,
        ),
        boxShadow: const [
          BoxShadow(
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  // ============================================================
  // RANGE LABEL
  // ============================================================

  String _rangeDescription() {
    if (tolerance <= 5) {
      return 'Очень узкий';
    }

    if (tolerance <= 15) {
      return 'Узкий';
    }

    if (tolerance <= 30) {
      return 'Средний';
    }

    if (tolerance <= 50) {
      return 'Широкий';
    }

    return 'Очень широкий';
  }

  // ============================================================
  // MASK INFORMATION
  // ============================================================

  String _maskDescription() {
    final currentMask =
        mask;

    if (currentMask == null) {
      return 'Маска отсутствует';
    }

    if (currentMask.values.isEmpty) {
      return 'Маска пустая';
    }

    final percentage =
        currentMask
            .selectedPercentage;

    return 'Выбрано '
        '${percentage.toStringAsFixed(2)}%';
  }

  // ============================================================
  // BEFORE / AFTER STATE
  // ============================================================

  void _toggleBeforeAfter() {
    if (originalImage == null ||
        processedImage == null) {
      return;
    }

    setState(() {
      showBefore = !showBefore;

      statusMessage =
          showBefore
              ? 'Показано исходное изображение'
              : 'Показан результат';
    });
  }

  // ============================================================
  // MASK VISIBILITY
  // ============================================================

  void _toggleMask() {
    if (mask == null) {
      _showMessage(
        'Сначала выберите цвет.',
      );
      return;
    }

    setState(() {
      showMask = !showMask;

      statusMessage =
          showMask
              ? 'Предпросмотр маски включён'
              : 'Предпросмотр маски выключен';
    });
  }

  // ============================================================
  // IMAGE COORDINATE CONVERSION
  // ============================================================

  Offset _screenToImage(
    Offset localPosition,
    Size displaySize,
    img.Image image,
  ) {
    final imageRatio =
        image.width /
            image.height;

    final displayRatio =
        displaySize.width /
            displaySize.height;

    double renderedWidth;
    double renderedHeight;

    if (imageRatio >
        displayRatio) {
      renderedWidth =
          displaySize.width;

      renderedHeight =
          renderedWidth /
              imageRatio;
    } else {
      renderedHeight =
          displaySize.height;

      renderedWidth =
          renderedHeight *
              imageRatio;
    }

    final offsetX =
        (displaySize.width -
                renderedWidth) /
            2.0;

    final offsetY =
        (displaySize.height -
                renderedHeight) /
            2.0;

    final x =
        (localPosition.dx -
                offsetX) *
            image.width /
            renderedWidth;

    final y =
        (localPosition.dy -
                offsetY) *
            image.height /
            renderedHeight;

    return Offset(
      x,
      y,
    );
  }

  // ============================================================
  // SAFE IMAGE COORDINATES
  // ============================================================

  Offset? _validImagePoint(
    Offset point,
    img.Image image,
  ) {
    final x =
        point.dx.floor();

    final y =
        point.dy.floor();

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
  // SELECTION STATUS
  // ============================================================

  String _selectionStatus() {
    if (selectedColor == null) {
      return 'Нажмите на цвет изображения';
    }

    return '${selectedColor!.hex} '
        '• диапазон ${tolerance.round()}%';
  }

  // ============================================================
  // SAFE PROCESSING GUARD
  // ============================================================

  bool _canEdit() {
    return originalImage != null &&
        !processing;
  }

  // ============================================================
  // KEYBOARD FOCUS
  // ============================================================

  final FocusNode _editorFocus =
      FocusNode();

  // ============================================================
  // DISPOSE FOCUS NODE
  // ============================================================
    // ============================================================
  // SELECTION PANEL
  // ============================================================

  Widget _buildSelectionPanel() {
    final color = selectedColor;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.colorize,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Выбор цвета',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
                if (color != null)
                  IconButton(
                    tooltip:
                        'Очистить выделение',
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

            const SizedBox(height: 10),

            Row(
              children: [
                _buildColorChip(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        color == null
                            ? 'Цвет не выбран'
                            : color.hex,
                        style:
                            const TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                      const SizedBox(
                        height: 4,
                      ),
                      Text(
                        _selectionStatus(),
                        style:
                            Theme.of(context)
                                .textTheme
                                .bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            _buildRangeSlider(
              title: 'Диапазон оттенков',
              value: tolerance,
              min: 0,
              max: 100,
              divisions: 100,
              suffix:
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
                  processing ||
                          selectedColor ==
                              null
                      ? null
                      : (_) {
                          _selectionSettingsChanged();
                        },
            ),

            Text(
              _rangeDescription(),
              style:
                  Theme.of(context)
                      .textTheme
                      .bodySmall,
            ),

            const SizedBox(height: 10),

            _buildRangeSlider(
              title: 'Мягкость края',
              value: softness,
              min: 0,
              max: 100,
              divisions: 100,
              suffix:
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
                  processing ||
                          selectedColor ==
                              null
                      ? null
                      : (_) {
                          _selectionSettingsChanged();
                        },
            ),

            const SizedBox(height: 6),

            SwitchListTile(
              contentPadding:
                  EdgeInsets.zero,
              title: const Text(
                'Только связанная область',
              ),
              subtitle: const Text(
                'Выбирает область, связанную '
                'с точкой нажатия',
              ),
              value: connectedOnly,
              onChanged:
                  processing ||
                          selectedColor ==
                              null
                      ? null
                      : (value) {
                          setState(() {
                            connectedOnly =
                                value;
                          });

                          _selectionSettingsChanged();
                        },
            ),

            const SizedBox(height: 4),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        mask == null
                            ? null
                            : _toggleMask,
                    icon: Icon(
                      showMask
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    label: Text(
                      showMask
                          ? 'Скрыть маску'
                          : 'Показать маску',
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Text(
              _maskDescription(),
              style:
                  Theme.of(context)
                      .textTheme
                      .bodySmall,
            ),
          ],
        ),
      ),
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
    required String suffix,
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
                style:
                    const TextStyle(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
            ),
            Text(
              suffix,
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  // ============================================================
  // CMYK PANEL
  // ============================================================

  Widget _buildCmykPanel() {
    return Card(
      margin:
          const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 6,
      ),
      child: Padding(
        padding:
            const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.palette,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'CMYK-коррекция',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed:
                      processing
                          ? null
                          : _resetCmyk,
                  child:
                      const Text('Сброс'),
                ),
              ],
            ),

            const SizedBox(height: 6),

            _buildCmykSlider(
              label: 'C',
              value:
                  correction.cyan,
              onChanged:
                  processing
                      ? null
                      : _setCyan,
            ),

            _buildCmykSlider(
              label: 'M',
              value:
                  correction.magenta,
              onChanged:
                  processing
                      ? null
                      : _setMagenta,
            ),

            _buildCmykSlider(
              label: 'Y',
              value:
                  correction.yellow,
              onChanged:
                  processing
                      ? null
                      : _setYellow,
            ),

            _buildCmykSlider(
              label: 'K',
              value:
                  correction.black,
              onChanged:
                  processing
                      ? null
                      : _setBlack,
            ),

            const SizedBox(height: 8),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    !_canEdit() ||
                            mask == null
                        ? null
                        : _applyCmyk,
                icon: const Icon(
                  Icons.check,
                ),
                label: const Text(
                  'Применить CMYK',
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            label,
            style:
                const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(-100.0, 100.0).toDouble(),
            min: -100,
            max: 100,
            divisions: 200,
            label:
                value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            value.round().toString(),
            textAlign:
                TextAlign.end,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // GLOBAL CORRECTION PANEL
  // ============================================================

  Widget _buildGlobalPanel() {
    return Card(
      margin:
          const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 6,
      ),
      child: Padding(
        padding:
            const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.tune,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Общая коррекция',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed:
                      processing
                          ? null
                          : _resetGlobal,
                  child:
                      const Text('Сброс'),
                ),
              ],
            ),

            const SizedBox(height: 6),

            _buildGlobalSlider(
              label: 'Яркость',
              value:
                  brightness,
              onChanged:
                  processing
                      ? null
                      : _setBrightness,
            ),

            _buildGlobalSlider(
              label: 'Контраст',
              value:
                  contrast,
              onChanged:
                  processing
                      ? null
                      : _setContrast,
            ),

            _buildGlobalSlider(
              label: 'Насыщенность',
              value:
                  saturation,
              onChanged:
                  processing
                      ? null
                      : _setSaturation,
            ),

            const SizedBox(height: 8),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    !_canEdit()
                        ? null
                        : _applyGlobalCorrections,
                icon: const Icon(
                  Icons.auto_fix_high,
                ),
                label: const Text(
                  'Применить общую коррекцию',
                ),
              ),
            ),
          ],
        ),
      ),
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
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(label),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(-100.0, 100.0).toDouble(),
            min: -100,
            max: 100,
            divisions: 200,
            label:
                value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            value.round().toString(),
            textAlign:
                TextAlign.end,
          ),
        ),
      ],
    );
  }
    // ============================================================
  // PREVIEW CONTROLS
  // ============================================================

  Widget _buildPreviewControls() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.compare,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Предпросмотр',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        originalImage == null ||
                                processedImage == null
                            ? null
                            : _toggleBeforeAfter,
                    icon: Icon(
                      showBefore
                          ? Icons.visibility
                          : Icons.compare_arrows,
                    ),
                    label: Text(
                      showBefore
                          ? 'Показать результат'
                          : 'Показать До',
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        mask == null
                            ? null
                            : _toggleMask,
                    icon: Icon(
                      showMask
                          ? Icons.layers_clear
                          : Icons.layers,
                    ),
                    label: Text(
                      showMask
                          ? 'Скрыть маску'
                          : 'Показать маску',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // IMAGE PREVIEW
  // ============================================================

  Widget _buildImagePreview() {
    final original = originalImage;
    final processed = processedImage;

    if (original == null || processed == null) {
      return const Center(
        child: Text(
          'Изображение отсутствует',
        ),
      );
    }

    final displayImage = showBefore ? original : processed;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,

          // onTapUp срабатывает только на настоящее касание:
          // сдвиг и масштабирование изображения цвет не выбирают.
          onTapUp: processing
              ? null
              : (details) {
                  // Учитываем зум и сдвиг InteractiveViewer.
                  final scenePoint = _viewController.toScene(
                    details.localPosition,
                  );

                  final point = _screenToImage(
                    scenePoint,
                    viewportSize,
                    displayImage,
                  );

                  final valid = _validImagePoint(
                    point,
                    displayImage,
                  );

                  if (valid == null) {
                    return;
                  }

                  _pickColor(
                    valid.dx.floor(),
                    valid.dy.floor(),
                  );
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                transformationController: _viewController,
                minScale: 0.25,
                maxScale: 8.0,
                boundaryMargin: const EdgeInsets.all(40),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: displayImage.width / displayImage.height,
                    child: _buildImageWithMask(displayImage),
                  ),
                ),
              ),

              Positioned(
                left: 12,
                top: 12,
                child: _buildPreviewBadge(
                  showBefore ? 'ДО' : 'ПОСЛЕ',
                ),
              ),

              if (processing)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // IMAGE + MASK
  // ============================================================

  Widget _buildImageWithMask(
    img.Image image,
  ) {
    // PNG кодируется один раз для каждого изображения,
    // а не при каждой перерисовке интерфейса.
    final png = _pngCache[image] ??=
        Uint8List.fromList(img.encodePng(image));

    final currentMask = mask;

    final overlay =
        currentMask == null ? null : _overlayCache[currentMask];

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          png,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        ),

        if (showMask && !showBefore && overlay != null)
          IgnorePointer(
            child: Image.memory(
              overlay,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
            ),
          ),

        if (!showBefore) _buildSelectionMarker(image),
      ],
    );
  }

  // ============================================================
  // SELECTION MARKER
  // ============================================================

  /// Маркер рисуется внутри изображения, поэтому он
  /// двигается и масштабируется вместе с ним.
  Widget _buildSelectionMarker(
    img.Image image,
  ) {
    final markerX = selectedX;
    final markerY = selectedY;

    if (markerX == null || markerY == null) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final centerX =
                (markerX + 0.5) * constraints.maxWidth / image.width;

            final centerY =
                (markerY + 0.5) * constraints.maxHeight / image.height;

            return Stack(
              children: [
                Positioned(
                  left: centerX - 9,
                  top: centerY - 9,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: 2,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ============================================================
  // PREVIEW BADGE
  // ============================================================

  Widget _buildPreviewBadge(
    String text,
  ) {
    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
      decoration:
          BoxDecoration(
        color: Colors.black87,
        borderRadius:
            BorderRadius.circular(
          8,
        ),
      ),
      child: Text(
        text,
        style:
            const TextStyle(
          fontWeight:
              FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  // ============================================================
  // MAIN IMAGE AREA
  // ============================================================

  Widget _buildImageArea() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: _buildImagePreview(),
    );
  }

  // ============================================================
  // EDITOR INFORMATION
  // ============================================================

  Widget _buildEditorInfo() {
    final image =
        processedImage ??
            originalImage;

    if (image == null) {
      return const SizedBox
          .shrink();
    }

    final color =
        selectedColor;

    final currentMask =
        mask;

    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      decoration:
          const BoxDecoration(
        color: Colors.black87,
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 5,
        children: [
          _infoItem(
            Icons.photo_size_select_large,
            '${image.width} × ${image.height}',
          ),
          _infoItem(
            Icons.palette_outlined,
            color == null
                ? 'Цвет не выбран'
                : color.hex,
          ),
          _infoItem(
            Icons.select_all,
            currentMask == null
                ? 'Маска: —'
                : 'Маска: '
                    '${currentMask.selectedPercentage.toStringAsFixed(2)}%',
          ),
          if (openedFileName != null)
            _infoItem(
              Icons.insert_drive_file,
              openedFileName!,
            ),
        ],
      ),
    );
  }

  // ============================================================
  // INFO ITEM
  // ============================================================

  Widget _infoItem(
    IconData icon,
    String value,
  ) {
    return Row(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
        ),
        const SizedBox(width: 5),
        Text(
          value,
          style:
              const TextStyle(
            fontSize: 12,
          ),
        ),
      ],
    );
  }
    // ============================================================
  // TOOLBAR
  // ============================================================

  Widget _buildToolbar() {
    return Material(
      elevation: 4,
      child: SafeArea(
        bottom: false,
        child: Container(
          padding:
              const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Открыть изображение',
                onPressed:
                    processing
                        ? null
                        : _openImage,
                icon: const Icon(
                  Icons.folder_open,
                ),
              ),

              IconButton(
                tooltip: 'Сохранить проект',
                onPressed:
                    originalImage == null ||
                            processing ||
                            exporting
                        ? null
                        : _saveProject,
                icon: const Icon(
                  Icons.save,
                ),
              ),

              IconButton(
                tooltip: 'Экспорт изображения',
                onPressed:
                    processedImage == null ||
                            processing ||
                            exporting
                        ? null
                        : _exportImage,
                icon: const Icon(
                  Icons.download,
                ),
              ),

              const SizedBox(
                width: 4,
              ),

              Container(
                width: 1,
                height: 28,
                color:
                    Theme.of(context)
                        .dividerColor,
              ),

              const SizedBox(
                width: 4,
              ),

              IconButton(
                tooltip: 'Отменить',
                onPressed:
                    historyIndex > 0 &&
                            !processing
                        ? _undo
                        : null,
                icon: const Icon(
                  Icons.undo,
                ),
              ),

              IconButton(
                tooltip: 'Повторить',
                onPressed:
                    historyIndex >= 0 &&
                            historyIndex <
                                history.length - 1 &&
                            !processing
                        ? _redo
                        : null,
                icon: const Icon(
                  Icons.redo,
                ),
              ),

              const Spacer(),

              // Информация, справка, закрытие изображения.
              _buildExtraActions(),

              IconButton(
                tooltip: 'Сбросить редактор',
                onPressed:
                    originalImage == null ||
                            processing
                        ? null
                        : _resetAll,
                icon: const Icon(
                  Icons.restart_alt,
                ),
              ),
            ],
          ),
        ),
      ),
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
            Icon(
              Icons.palette_outlined,
              size: 82,
              color:
                  Theme.of(context)
                      .colorScheme
                      .primary,
            ),

            const SizedBox(
              height: 18,
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
              height: 8,
            ),

            Text(
              'Профессиональная коррекция '
              'цвета для печатного процесса',
              textAlign:
                  TextAlign.center,
              style:
                  Theme.of(context)
                      .textTheme
                      .bodyLarge,
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
              height: 20,
            ),

            const Text(
              'Поддерживаются PNG, JPG, JPEG, '
              'WEBP, BMP, GIF, TIFF.',
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
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
        horizontal: 12,
        vertical: 8,
      ),
      decoration:
          BoxDecoration(
        color:
            Theme.of(context)
                .colorScheme
                .surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color:
                Theme.of(context)
                    .dividerColor,
          ),
        ),
      ),
      child: Row(
        children: [
          if (processing)
            const SizedBox(
              width: 14,
              height: 14,
              child:
                  CircularProgressIndicator(
                strokeWidth: 2,
              ),
            ),

          if (processing)
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
                  Theme.of(context)
                      .textTheme
                      .bodySmall,
            ),
          ),

          if (selectedColor != null)
            Container(
              width: 12,
              height: 12,
              decoration:
                  BoxDecoration(
                color:
                    Color.fromARGB(
                  255,
                  selectedColor!.r,
                  selectedColor!.g,
                  selectedColor!.b,
                ),
                shape:
                    BoxShape.circle,
                border:
                    Border.all(
                  color:
                      Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // CONTROLS PANEL
  // ============================================================

  Widget _buildControlsPanel() {
    return SingleChildScrollView(
      padding:
          const EdgeInsets.only(
        top: 4,
        bottom: 16,
      ),
      child: Column(
        children: [
          _buildSelectionPanel(),
          _buildCmykPanel(),
          _buildGlobalPanel(),
          _buildPreviewControls(),
        ],
      ),
    );
  }

  // ============================================================
  // DESKTOP LAYOUT
  // ============================================================

  Widget _buildDesktopLayout(
    BoxConstraints constraints,
  ) {
    final panelWidth =
        math.min(
      430.0,
      math.max(
        340.0,
        constraints.maxWidth *
            0.30,
      ),
    );

    return Column(
      children: [
        _buildToolbar(),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child:
                          _buildWorkspace(),
                    ),
                    _buildEditorInfo(),
                  ],
                ),
              ),

              Container(
                width: 1,
                color:
                    Theme.of(context)
                        .dividerColor,
              ),

              SizedBox(
                width: panelWidth,
                child:
                    _buildControlsPanel(),
              ),
            ],
          ),
        ),
        _buildStatusBar(),
      ],
    );
  }

  // ============================================================
  // MOBILE LAYOUT
  // ============================================================

  Widget _buildMobileLayout(
    BoxConstraints constraints,
  ) {
    return Column(
      children: [
        _buildToolbar(),

        Expanded(
          child: Column(
            children: [
              Expanded(
                flex: 6,
                child: _buildWorkspace(),
              ),

              _buildEditorInfo(),

              Expanded(
                flex: 5,
                child:
                    _buildControlsPanel(),
              ),
            ],
          ),
        ),

        _buildStatusBar(),
      ],
    );
  }

  // ============================================================
  // RESPONSIVE EDITOR
  // ============================================================

  Widget _buildEditor(
    BoxConstraints constraints,
  ) {
    final isDesktop =
        constraints.maxWidth >= 900;

    if (isDesktop) {
      return _buildDesktopLayout(
        constraints,
      );
    }

    return _buildMobileLayout(
      constraints,
    );
  }

  // ============================================================
  // MAIN BUILD
  // ============================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      body: SafeArea(
        child: Focus(
          focusNode: _editorFocus,
          autofocus: true,
          child: LayoutBuilder(
            builder:
                (
              context,
              constraints,
            ) {
              if (originalImage == null) {
                return Column(
                  children: [
                    _buildToolbar(),
                    Expanded(
                      child:
                          _buildEmptyState(),
                    ),
                    _buildStatusBar(),
                  ],
                );
              }

              return _buildEditor(
                constraints,
              );
            },
          ),
        ),
      ),
    );
  }
    // ============================================================
  // HISTORY
  // ============================================================

  Future<void> _addHistoryPoint(
    String description,
  ) async {
    final image =
        processedImage ??
            originalImage;

    if (image == null) {
      return;
    }

    final snapshot =
        _HistorySnapshot(
      image: image.clone(),
      description: description,
      selectedColor:
          selectedColor,
      selectedX: selectedX,
      selectedY: selectedY,
      tolerance: tolerance,
      softness: softness,
      connectedOnly:
          connectedOnly,
      correction: correction,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
    );

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

    // Каждый шаг хранит полную копию изображения,
    // поэтому глубина истории ограничена.
    if (history.length > _maxHistory) {
      history.removeAt(0);
      historyIndex--;
    }

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // UNDO
  // ============================================================

  Future<void> _undo() async {
    if (processing ||
        historyIndex <= 0 ||
        history.isEmpty) {
      return;
    }

    final targetIndex =
        historyIndex - 1;

    await _restoreHistory(
      targetIndex,
    );
  }

  // ============================================================
  // REDO
  // ============================================================

  Future<void> _redo() async {
    if (processing ||
        historyIndex < 0 ||
        historyIndex >=
            history.length - 1) {
      return;
    }

    final targetIndex =
        historyIndex + 1;

    await _restoreHistory(
      targetIndex,
    );
  }

  // ============================================================
  // RESTORE HISTORY
  // ============================================================

  Future<void> _restoreHistory(
    int index,
  ) async {
    if (index < 0 ||
        index >= history.length) {
      return;
    }

    final snapshot =
        history[index];

    setState(() {
      processing = true;
      statusMessage =
          'Восстановление изменения...';
    });

    await Future<void>.delayed(
      const Duration(
        milliseconds: 10,
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      processedImage =
          snapshot.image.clone();

      selectedColor =
          snapshot.selectedColor;

      selectedX =
          snapshot.selectedX;

      selectedY =
          snapshot.selectedY;

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

      historyIndex =
          index;

      processing = false;

      showBefore = false;

      statusMessage =
          'Восстановлено: '
          '${snapshot.description}';
    });

    if (selectedColor != null &&
        originalImage != null) {
      await _generateSelection();
    } else if (mounted) {
      setState(() {
        mask = null;
      });
    }
  }

  // ============================================================
  // PROJECT DATA
  // ============================================================

  Map<String, dynamic> _projectJson() {
    final color =
        selectedColor;

    return <String, dynamic>{
      'format':
          'print_color_app_project',
      'version': ProjectFile.currentVersion,
      'createdBy':
          'Print Color App',

      'source': <String, dynamic>{
        'fileName':
            openedFileName,
        'filePath':
            openedFilePath,
      },

      'selection':
          <String, dynamic>{
        'r': color?.r,
        'g': color?.g,
        'b': color?.b,
        'x': selectedX,
        'y': selectedY,
        'tolerance':
            tolerance,
        'softness':
            softness,
        'connectedOnly':
            connectedOnly,
      },

      'correction':
          <String, dynamic>{
        'cyan':
            correction.cyan,
        'magenta':
            correction.magenta,
        'yellow':
            correction.yellow,
        'black':
            correction.black,
      },

      'global':
          <String, dynamic>{
        'brightness':
            brightness,
        'contrast':
            contrast,
        'saturation':
            saturation,
      },

      'view':
          <String, dynamic>{
        'showBefore':
            showBefore,
        'showMask':
            showMask,
      },

      'history':
          <String, dynamic>{
        'index':
            historyIndex,
        'length':
            history.length,
      },
    };
  }

  // ============================================================
  // SAVE BYTES
  // ============================================================

  /// Показывает диалог сохранения и гарантирует, что файл записан.
  ///
  /// На Android/iOS файл записывает сам плагин, на компьютерах
  /// при необходимости файл дописывается здесь.
  Future<Uri?> _saveBytes({
    required String dialogTitle,
    required String fileName,
    required String extension,
    required Uint8List bytes,
  }) async {
    final path = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: <String>[
        extension,
      ],
      bytes: bytes,
    );

    if (path == null) {
      return null;
    }

    if (Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS) {
      // saveFile возвращает Uri, а не строку.
      final file = File(path.toFilePath());

      if (!await file.exists() ||
          await file.length() != bytes.length) {
        await file.writeAsBytes(
          bytes,
          flush: true,
        );
      }
    }

    return path;
  }

  // ============================================================
  // SAVE PROJECT
  // ============================================================

  Future<void> _saveProject() async {
    final original = originalImage;
    final processed = processedImage ?? originalImage;

    if (original == null ||
        processed == null ||
        processing ||
        exporting) {
      return;
    }

    setState(() {
      exporting = true;
      statusMessage =
          'Подготовка проекта...';
    });

    try {
      final bytes = await encodeProjectAsync(
        settings: _projectJson(),
        original: original,
        processed: processed,
      );

      final fileName =
          '${_baseName(openedFileName ?? 'project')}'
          '.pcproj';

      final path = await _saveBytes(
        dialogTitle: 'Сохранить проект',
        fileName: fileName,
        extension: 'pcproj',
        bytes: bytes,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;
        statusMessage =
            path == null
                ? 'Сохранение отменено'
                : 'Проект сохранён';
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
  // OPEN PROJECT
  // ============================================================

  Future<void> _openProject() async {
    if (processing || exporting) {
      return;
    }

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>[
          'pcproj',
        ],
      );

      if (result == null || result.isEmpty) {
        return;
      }

      final picked = result.first;
      final path = picked.path;

      if (path == null || path.isEmpty) {
        _showMessage(
          'Не удалось получить путь к файлу.',
        );
        return;
      }

      setState(() {
        processing = true;
        statusMessage =
            'Загрузка проекта...';
      });

      final bytes = await File(path).readAsBytes();
      final project = await decodeProjectAsync(bytes);

      if (!mounted) {
        return;
      }

      final settings = project.settings;
      final source = jsonMapOf(settings['source']);
      final selection = jsonMapOf(settings['selection']);
      final cmyk = jsonMapOf(settings['correction']);
      final global = jsonMapOf(settings['global']);

      final width = project.original.width;
      final height = project.original.height;

      final r = jsonInt(selection['r']);
      final g = jsonInt(selection['g']);
      final b = jsonInt(selection['b']);

      final RgbColor? color =
          (r != null && g != null && b != null)
              ? RgbColor(
                  r: r.clamp(0, 255).toInt(),
                  g: g.clamp(0, 255).toInt(),
                  b: b.clamp(0, 255).toInt(),
                )
              : null;

      final rawX = jsonInt(selection['x']);
      final rawY = jsonInt(selection['y']);

      final hasPoint = color != null &&
          rawX != null &&
          rawY != null &&
          rawX >= 0 &&
          rawY >= 0 &&
          rawX < width &&
          rawY < height;

      final int? tapX = hasPoint ? rawX : null;
      final int? tapY = hasPoint ? rawY : null;

      setState(() {
        originalImage = project.original;
        processedImage = project.processed;
        originalBytes = null;

        openedFileName =
            jsonString(source['fileName']) ?? picked.name;

        openedFilePath =
            jsonString(source['filePath']) ?? path;

        selectedColor = color;
        selectedX = tapX;
        selectedY = tapY;

        tolerance =
            jsonDouble(selection['tolerance'], 20.0)
                .clamp(0.0, 100.0)
                .toDouble();

        softness =
            jsonDouble(selection['softness'], 10.0)
                .clamp(0.0, 100.0)
                .toDouble();

        connectedOnly =
            jsonBool(selection['connectedOnly'], false);

        correction = CmykCorrection(
          cyan: _correctionValue(cmyk['cyan']),
          magenta: _correctionValue(cmyk['magenta']),
          yellow: _correctionValue(cmyk['yellow']),
          black: _correctionValue(cmyk['black']),
        );

        brightness = _correctionValue(global['brightness']);
        contrast = _correctionValue(global['contrast']);
        saturation = _correctionValue(global['saturation']);

        mask = null;

        showBefore = false;
        showMask = color != null;

        history.clear();
        historyIndex = -1;

        _viewController.value = Matrix4.identity();

        processing = false;

        statusMessage =
            'Проект загружен';
      });

      await _addHistoryPoint(
        'Загруженный проект',
      );

      if (selectedColor != null) {
        await _generateSelection();
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        processing = false;
        statusMessage =
            'Ошибка загрузки проекта: $e';
      });
    }
  }

  /// Значение коррекции из файла проекта, ограниченное -100...+100.
  double _correctionValue(
    Object? value,
  ) {
    return jsonDouble(value, 0.0)
        .clamp(-100.0, 100.0)
        .toDouble();
  }

  // ============================================================
  // BASE FILE NAME
  // ============================================================

  String _baseName(
    String name,
  ) {
    final dot =
        name.lastIndexOf('.');

    if (dot <= 0) {
      return name;
    }

    return name.substring(
      0,
      dot,
    );
  }

  // ============================================================
  // EXPORT IMAGE
  // ============================================================

  Future<void> _exportImage() async {
    final image =
        processedImage;

    if (image == null ||
        processing ||
        exporting) {
      return;
    }

    setState(() {
      exporting = true;
      statusMessage =
          'Подготовка изображения...';
    });

    try {
      final bytes = await encodePngAsync(image);

      final fileName =
          '${_baseName(openedFileName ?? 'corrected')}'
          '_corrected.png';

      final path = await _saveBytes(
        dialogTitle: 'Экспортировать изображение',
        fileName: fileName,
        extension: 'png',
        bytes: bytes,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        exporting = false;
        statusMessage =
            path == null
                ? 'Экспорт отменён'
                : 'Изображение экспортировано';
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
  // RESET ALL
  // ============================================================

  void _resetAll() {
    if (processing ||
        originalImage == null) {
      return;
    }

    setState(() {
      processedImage =
          originalImage!.clone();

      selectedColor = null;
      selectedX = null;
      selectedY = null;

      tolerance = 20.0;
      softness = 10.0;
      connectedOnly = false;

      mask = null;

      correction =
          const CmykCorrection();

      brightness = 0.0;
      contrast = 0.0;
      saturation = 0.0;

      showBefore = false;
      showMask = false;

      history.clear();
      historyIndex = -1;

      _viewController.value =
          Matrix4.identity();

      statusMessage =
          'Редактор сброшен';
    });

    _addHistoryPoint(
      'Исходное изображение',
    );
  }

  // ============================================================
  // CLEAR IMAGE
  // ============================================================

  void _clearImage() {
    if (processing) {
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

      tolerance = 20.0;
      softness = 10.0;
      connectedOnly = false;

      mask = null;

      correction =
          const CmykCorrection();

      brightness = 0.0;
      contrast = 0.0;
      saturation = 0.0;

      showBefore = false;
      showMask = false;

      history.clear();
      historyIndex = -1;

      _viewController.value =
          Matrix4.identity();

      statusMessage =
          'Откройте изображение для начала работы';
    });
  }
    // ============================================================
  // HELP
  // ============================================================

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.help_outline),
              SizedBox(width: 8),
              Text('Как работать'),
            ],
          ),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                Text(
                  '1. Откройте изображение.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Нажмите непосредственно на нужный '
                  'цвет изображения.',
                ),
                SizedBox(height: 14),

                Text(
                  '2. Настройте диапазон.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Диапазон определяет, насколько похожие '
                  'оттенки будут включены в выделение.',
                ),
                SizedBox(height: 14),

                Text(
                  '3. Настройте мягкость.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Мягкость создаёт плавный переход '
                  'по краям выбранной области.',
                ),
                SizedBox(height: 14),

                Text(
                  '4. Проверьте маску.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Голубая область показывает пиксели, '
                  'к которым будет применена коррекция.',
                ),
                SizedBox(height: 14),

                Text(
                  '5. Измените CMYK.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Коррекция применяется только к выбранной '
                  'маске, остальные области не изменяются.',
                ),
                SizedBox(height: 14),

                Text(
                  '6. Используйте До/После.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Так можно визуально сравнить исходное '
                  'изображение и результат.',
                ),
                SizedBox(height: 14),

                Text(
                  '7. Сохраните результат.',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'PNG сохраняет готовое исправленное '
                  'изображение. Проект .pcproj сохраняет '
                  'исходник, результат и настройки; открыть '
                  'его можно через меню ⋮ → «Открыть проект».',
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed:
                  () => Navigator.of(
                context,
              ).pop(),
              child:
                  const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // FILE INFORMATION DIALOG
  // ============================================================

  void _showFileInformation() {
    final image =
        originalImage;

    if (image == null) {
      return;
    }

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title:
              const Text(
            'Информация',
          ),
          content:
              SingleChildScrollView(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                _dialogInfo(
                  'Файл',
                  openedFileName ??
                      '—',
                ),
                _dialogInfo(
                  'Размер',
                  '${image.width} × ${image.height}',
                ),
                _dialogInfo(
                  'Путь',
                  openedFilePath ??
                      '—',
                ),
                _dialogInfo(
                  'Выбранный цвет',
                  selectedColor?.hex ??
                      '—',
                ),
                _dialogInfo(
                  'Диапазон',
                  '${tolerance.round()}%',
                ),
                _dialogInfo(
                  'Мягкость',
                  '${softness.round()}%',
                ),
                _dialogInfo(
                  'Связанная область',
                  connectedOnly
                      ? 'Да'
                      : 'Нет',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  () => Navigator.of(
                context,
              ).pop(),
              child:
                  const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // DIALOG INFO
  // ============================================================

  Widget _dialogInfo(
    String title,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.only(
        bottom: 10,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style:
                const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          const SizedBox(
            height: 2,
          ),
          SelectableText(
            value,
          ),
        ],
      ),
    );
  }

  // ============================================================
  // APPBAR ACTIONS
  // ============================================================

  Widget _buildExtraActions() {
    return PopupMenuButton<String>(
      tooltip:
          'Дополнительные действия',
      onSelected:
          (value) {
        switch (value) {
          case 'project':
            _openProject();
            break;

          case 'info':
            _showFileInformation();
            break;

          case 'clear':
            _clearImage();
            break;

          case 'help':
            _showHelp();
            break;
        }
      },
      itemBuilder:
          (context) {
        return const [
          PopupMenuItem<String>(
            value: 'project',
            child: ListTile(
              leading:
                  Icon(Icons.folder_special),
              title:
                  Text('Открыть проект'),
              contentPadding:
                  EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<String>(
            value: 'info',
            child: ListTile(
              leading:
                  Icon(Icons.info_outline),
              title:
                  Text('Информация'),
              contentPadding:
                  EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<String>(
            value: 'help',
            child: ListTile(
              leading:
                  Icon(Icons.help_outline),
              title:
                  Text('Справка'),
              contentPadding:
                  EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<String>(
            value: 'clear',
            child: ListTile(
              leading:
                  Icon(Icons.close),
              title:
                  Text('Закрыть изображение'),
              contentPadding:
                  EdgeInsets.zero,
            ),
          ),
        ];
      },
    );
  }

  // ============================================================
  // EXPORT PROGRESS
  // ============================================================

  Widget _buildExportIndicator() {
    if (!exporting) {
      return const SizedBox
          .shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Card(
            child: Padding(
              padding:
                  const EdgeInsets.all(20),
              child: Column(
                mainAxisSize:
                    MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(
                    height: 14,
                  ),
                  Text(
                    'Сохранение...',
                    style:
                        Theme.of(context)
                            .textTheme
                            .titleMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // IMAGE WORKSPACE
  // ============================================================

  Widget _buildWorkspace() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildImageArea(),
        _buildExportIndicator(),
      ],
    );
  }

    // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _editorFocus.dispose();
    _viewController.dispose();
    super.dispose();
  }
}

// ============================================================
// HISTORY SNAPSHOT
// ============================================================

class _HistorySnapshot {
  final img.Image image;

  final String description;

  final RgbColor? selectedColor;

  final int? selectedX;
  final int? selectedY;

  final double tolerance;
  final double softness;

  final bool connectedOnly;

  final CmykCorrection correction;

  final double brightness;
  final double contrast;
  final double saturation;

  const _HistorySnapshot({
    required this.image,
    required this.description,
    required this.selectedColor,
    required this.selectedX,
    required this.selectedY,
    required this.tolerance,
    required this.softness,
    required this.connectedOnly,
    required this.correction,
    required this.brightness,
    required this.contrast,
    required this.saturation,
  });
}
