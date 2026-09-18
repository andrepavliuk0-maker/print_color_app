import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

void main() {
  runApp(const PrintColorApp());
}

class PrintColorApp extends StatelessWidget {
  const PrintColorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Print Color Studio',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0D11),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C5CFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const EditorPage(),
    );
  }
}

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  Uint8List? _originalBytes;
  Uint8List? _processedBytes;
  Uint8List? _referenceBytes;

  img.Image? _originalImage;
  img.Image? _processedImage;

  String _fileName = 'No image loaded';
  String _status = 'Ready';

  bool _showBefore = false;
  bool _showReference = false;
  bool _processing = false;

  double _cyan = 0;
  double _magenta = 0;
  double _yellow = 0;
  double _black = 0;

  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;

  double _zoom = 1.0;
  int _rotation = 0;

  Timer? _processingTimer;

  @override
  void dispose() {
    _processingTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // FILES
  // ---------------------------------------------------------------------------

  Future<void> _loadImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;
      final bytes = file.bytes;

      if (bytes == null || bytes.isEmpty) {
        _setStatus('Could not read image');
        return;
      }

      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        _setStatus('Unsupported image format');
        return;
      }

      setState(() {
        _originalBytes = bytes;
        _originalImage = decoded;
        _processedImage = decoded.clone();
        _processedBytes = Uint8List.fromList(img.encodePng(decoded));
        _fileName = file.name;
        _rotation = 0;
        _zoom = 1.0;
      });

      _setStatus('Loaded ${file.name}');
    } catch (e) {
      _setStatus('Load error: $e');
    }
  }

  Future<void> _loadReference() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final bytes = result.files.first.bytes;

      if (bytes == null || bytes.isEmpty) {
        _setStatus('Could not read reference');
        return;
      }

      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        _setStatus('Unsupported reference image');
        return;
      }

      setState(() {
        _referenceBytes = Uint8List.fromList(bytes);
        _showReference = true;
      });

      _setStatus('Reference image loaded');
    } catch (e) {
      _setStatus('Reference error: $e');
    }
  }

  Future<void> _exportImage() async {
    if (_processedImage == null) {
      _setStatus('Load an image first');
      return;
    }

    try {
      final bytes = Uint8List.fromList(
        img.encodePng(_processedImage!),
      );

      final baseName = _fileName.contains('.')
          ? _fileName.substring(0, _fileName.lastIndexOf('.'))
          : _fileName;

      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export corrected image',
        fileName: '${baseName}_corrected.png',
        type: FileType.image,
        bytes: bytes,
      );

      if (path != null) {
        _setStatus('Exported successfully');
      }
    } catch (e) {
      _setStatus('Export error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // PROCESSING
  // ---------------------------------------------------------------------------

  void _scheduleProcessing() {
    _processingTimer?.cancel();

    _processingTimer = Timer(
      const Duration(milliseconds: 120),
      _processImage,
    );
  }

  Future<void> _processImage() async {
    final source = _originalImage;

    if (source == null) {
      return;
    }

    setState(() {
      _processing = true;
    });

    await Future<void>.delayed(Duration.zero);

    final result = source.clone();

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final p = result.getPixel(x, y);

        double r = p.r.toDouble();
        double g = p.g.toDouble();
        double b = p.b.toDouble();

        // RGB -> CMY
        double c = 1.0 - r / 255.0;
        double m = 1.0 - g / 255.0;
        double yv = 1.0 - b / 255.0;

        // CMYK separation
        final k = math.min(c, math.min(m, yv));

        double cc = k >= 0.999
            ? 0
            : (c - k) / (1.0 - k);

        double mm = k >= 0.999
            ? 0
            : (m - k) / (1.0 - k);

        double yy = k >= 0.999
            ? 0
            : (yv - k) / (1.0 - k);

        // Apply user CMYK corrections.
        cc = _clamp01(cc + _cyan / 100.0);
        mm = _clamp01(mm + _magenta / 100.0);
        yy = _clamp01(yy + _yellow / 100.0);

        double kk = _clamp01(k + _black / 100.0);

        // CMYK -> RGB
        r = 255.0 * (1.0 - cc) * (1.0 - kk);
        g = 255.0 * (1.0 - mm) * (1.0 - kk);
        b = 255.0 * (1.0 - yy) * (1.0 - kk);

        // Brightness
        r += _brightness * 2.55;
        g += _brightness * 2.55;
        b += _brightness * 2.55;

        // Contrast
        final contrastFactor =
            (259.0 * (_contrast + 255.0)) /
            (255.0 * (259.0 - _contrast));

        r = contrastFactor * (r - 128.0) + 128.0;
        g = contrastFactor * (g - 128.0) + 128.0;
        b = contrastFactor * (b - 128.0) + 128.0;

        // Saturation
        final gray = 0.299 * r + 0.587 * g + 0.114 * b;
        final saturationFactor = 1.0 + _saturation / 100.0;

        r = gray + (r - gray) * saturationFactor;
        g = gray + (g - gray) * saturationFactor;
        b = gray + (b - gray) * saturationFactor;

        result.setPixelRgb(
          x,
          y,
          _clamp255(r).toInt(),
          _clamp255(g).toInt(),
          _clamp255(b).toInt(),
        );
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _processedImage = result;
      _processedBytes = Uint8List.fromList(
        img.encodePng(result),
      );
      _processing = false;
    });

    _setStatus('Preview updated');
  }

  double _clamp01(double value) {
    return value.clamp(0.0, 1.0).toDouble();
  }

  double _clamp255(double value) {
    return value.clamp(0.0, 255.0).toDouble();
  }

  // ---------------------------------------------------------------------------
  // RESET / PRESETS
  // ---------------------------------------------------------------------------

  void _reset() {
    setState(() {
      _cyan = 0;
      _magenta = 0;
      _yellow = 0;
      _black = 0;
      _brightness = 0;
      _contrast = 0;
      _saturation = 0;
      _rotation = 0;
      _zoom = 1.0;
    });

    _scheduleProcessing();
    _setStatus('Settings reset');
  }

  void _applyPreset(
    String name, {
    double cyan = 0,
    double magenta = 0,
    double yellow = 0,
    double black = 0,
    double brightness = 0,
    double contrast = 0,
    double saturation = 0,
  }) {
    setState(() {
      _cyan = cyan;
      _magenta = magenta;
      _yellow = yellow;
      _black = black;
      _brightness = brightness;
      _contrast = contrast;
      _saturation = saturation;
    });

    _scheduleProcessing();
    _setStatus('Preset: $name');
  }

  // ---------------------------------------------------------------------------
  // ROTATION / ZOOM
  // ---------------------------------------------------------------------------

  void _rotateLeft() {
    setState(() {
      _rotation = (_rotation - 90) % 360;
    });
  }

  void _rotateRight() {
    setState(() {
      _rotation = (_rotation + 90) % 360;
    });
  }

  void _zoomIn() {
    setState(() {
      _zoom = (_zoom + 0.1).clamp(0.25, 4.0);
    });
  }

  void _zoomOut() {
    setState(() {
      _zoom = (_zoom - 0.1).clamp(0.25, 4.0);
    });
  }

  void _setStatus(String text) {
    if (!mounted) {
      return;
    }

    setState(() {
      _status = text;
    });
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 290,
                    child: _buildLeftPanel(),
                  ),
                  Expanded(
                    child: _buildPreviewArea(),
                  ),
                  SizedBox(
                    width: 270,
                    child: _buildRightPanel(),
                  ),
                ],
              ),
            ),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF11141A),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withOpacity(0.07),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF7C5CFF),
                  Color(0xFF4C9AFF),
                ],
              ),
            ),
            child: const Icon(
              Icons.colorize,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PRINT COLOR STUDIO',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  letterSpacing: 1.2,
                ),
              ),
              Text(
                'CMYK COLOR CORRECTION',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const Spacer(),
          _topButton(
            icon: Icons.folder_open,
            label: 'OPEN',
            onPressed: _loadImage,
          ),
          const SizedBox(width: 8),
          _topButton(
            icon: Icons.image_outlined,
            label: 'REFERENCE',
            onPressed: _loadReference,
          ),
          const SizedBox(width: 8),
          _topButton(
            icon: Icons.download_outlined,
            label: 'EXPORT',
            onPressed: _exportImage,
            primary: true,
          ),
        ],
      ),
    );
  }

  Widget _topButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool primary = false,
  }) {
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: primary
            ? const Color(0xFF6D4AFF)
            : const Color(0xFF1A1E26),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 12,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
        ),
      ),
      icon: Icon(icon, size: 17),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildLeftPanel() {
    return Container(
      color: const Color(0xFF101319),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('COLOR CORRECTION'),
            const SizedBox(height: 10),

            _slider(
              label: 'CYAN',
              value: _cyan,
              onChanged: (v) {
                setState(() => _cyan = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_cyan),
              icon: Icons.water_drop_outlined,
            ),

            _slider(
              label: 'MAGENTA',
              value: _magenta,
              onChanged: (v) {
                setState(() => _magenta = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_magenta),
              icon: Icons.circle_outlined,
            ),

            _slider(
              label: 'YELLOW',
              value: _yellow,
              onChanged: (v) {
                setState(() => _yellow = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_yellow),
              icon: Icons.wb_sunny_outlined,
            ),

            _slider(
              label: 'BLACK',
              value: _black,
              onChanged: (v) {
                setState(() => _black = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_black),
              icon: Icons.contrast,
            ),

            const SizedBox(height: 14),
            _divider(),
            const SizedBox(height: 14),

            _sectionTitle('IMAGE'),

            _slider(
              label: 'BRIGHTNESS',
              value: _brightness,
              onChanged: (v) {
                setState(() => _brightness = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_brightness),
              icon: Icons.brightness_6_outlined,
            ),

            _slider(
              label: 'CONTRAST',
              value: _contrast,
              onChanged: (v) {
                setState(() => _contrast = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_contrast),
              icon: Icons.tonality_outlined,
            ),

            _slider(
              label: 'SATURATION',
              value: _saturation,
              onChanged: (v) {
                setState(() => _saturation = v);
                _scheduleProcessing();
              },
              valueText: _formatValue(_saturation),
              icon: Icons.palette_outlined,
            ),

            const SizedBox(height: 14),
            _divider(),
            const SizedBox(height: 14),

            _sectionTitle('VIEW'),

            Row(
              children: [
                Expanded(
                  child: _smallButton(
                    icon: Icons.rotate_left,
                    label: 'LEFT',
                    onPressed: _rotateLeft,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _smallButton(
                    icon: Icons.rotate_right,
                    label: 'RIGHT',
                    onPressed: _rotateRight,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: _smallButton(
                    icon: Icons.remove,
                    label: 'ZOOM',
                    onPressed: _zoomOut,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _smallButton(
                    icon: Icons.add,
                    label: '${(_zoom * 100).round()}%',
                    onPressed: _zoomIn,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('RESET ALL'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewArea() {
    return Container(
      color: const Color(0xFF0B0D11),
      child: Column(
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1116),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withOpacity(0.05),
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.preview_outlined,
                  size: 18,
                  color: Colors.white54,
                ),
                const SizedBox(width: 8),
                Text(
                  _showBefore ? 'ORIGINAL' : 'CORRECTED PREVIEW',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                Switch(
                  value: _showBefore,
                  onChanged: (value) {
                    setState(() {
                      _showBefore = value;
                    });
                  },
                ),
                const Text(
                  'BEFORE',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildCanvas(),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    Uint8List? bytes;

    if (_showReference && _referenceBytes != null) {
      bytes = _referenceBytes;
    } else if (_showBefore) {
      bytes = _originalBytes;
    } else {
      bytes = _processedBytes;
    }

    if (bytes == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: const Color(0xFF141820),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.image_search_outlined,
                size: 42,
                color: Colors.white24,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No image loaded',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.
