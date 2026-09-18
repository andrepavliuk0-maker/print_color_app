import 'dart:async';
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
      title: 'Print Color App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF101216),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
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
  Uint8List? originalBytes;
  Uint8List? previewBytes;
  Uint8List? referenceBytes;

  String? fileName;
  String? referenceName;

  int imageWidth = 0;
  int imageHeight = 0;

  double cyan = 0;
  double magenta = 0;
  double yellow = 0;
  double black = 0;

  double brightness = 0;
  double contrast = 0;
  double saturation = 0;

  double zoom = 1.0;
  double rotation = 0;

  bool showBefore = false;
  bool processing = false;
  bool showReference = false;

  Timer? _processingTimer;

  Future<void> openImage() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Open print image',
      type: FileType.custom,
      allowedExtensions: [
        'png',
        'jpg',
        'jpeg',
        'webp',
      ],
    );

    if (file == null) return;

    try {
      final bytes = await file.readAsBytes();

      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        _showMessage('Could not decode the image.');
        return;
      }

      setState(() {
        originalBytes = bytes;
        previewBytes = bytes;
        fileName = file.name;
        imageWidth = decoded.width;
        imageHeight = decoded.height;

        cyan = 0;
        magenta = 0;
        yellow = 0;
        black = 0;
        brightness = 0;
        contrast = 0;
        saturation = 0;
        zoom = 1;
        rotation = 0;
        showBefore = false;
      });
    } catch (e) {
      _showMessage('Error opening image: $e');
    }
  }

  Future<void> openReference() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Open reference image',
      type: FileType.custom,
      allowedExtensions: [
        'png',
        'jpg',
        'jpeg',
        'webp',
      ],
    );

    if (file == null) return;

    try {
      final bytes = await file.readAsBytes();

      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        _showMessage('Could not decode the reference image.');
        return;
      }

      setState(() {
        referenceBytes = bytes;
        referenceName = file.name;
        showReference = true;
      });
    } catch (e) {
      _showMessage('Error opening reference: $e');
    }
  }

  void scheduleProcessing() {
    _processingTimer?.cancel();

    _processingTimer = Timer(
      const Duration(milliseconds: 120),
      processImage,
    );
  }

  Future<void> processImage() async {
    if (originalBytes == null) return;

    setState(() {
      processing = true;
    });

    try {
      final source = img.decodeImage(originalBytes!);

      if (source == null) {
        setState(() {
          processing = false;
        });
        return;
      }

      final result = source.clone();

      for (int y = 0; y < result.height; y++) {
        for (int x = 0; x < result.width; x++) {
          final pixel = result.getPixel(x, y);

          double r = pixel.r.toDouble() / 255.0;
          double g = pixel.g.toDouble() / 255.0;
          double b = pixel.b.toDouble() / 255.0;

          final kBase = 1.0 - _max3(r, g, b);

          double c = kBase >= 0.999
              ? 0
              : (1 - r - kBase) / (1 - kBase);

          double m = kBase >= 0.999
              ? 0
              : (1 - g - kBase) / (1 - kBase);

          double yValue = kBase >= 0.999
              ? 0
              : (1 - b - kBase) / (1 - kBase);

          double k = kBase;

          c = _adjustChannel(c, cyan);
          m = _adjustChannel(m, magenta);
          yValue = _adjustChannel(yValue, yellow);
          k = _adjustChannel(k, black);

          r = (1 - c) * (1 - k);
          g = (1 - m) * (1 - k);
          b = (1 - yValue) * (1 - k);

          final brightnessFactor = 1 + brightness / 100;
          r *= brightnessFactor;
          g *= brightnessFactor;
          b *= brightnessFactor;

          r = _contrast(r, contrast);
          g = _contrast(g, contrast);
          b = _contrast(b, contrast);

          final gray = (r + g + b) / 3;

          final saturationFactor = 1 + saturation / 100;

          r = gray + (r - gray) * saturationFactor;
          g = gray + (g - gray) * saturationFactor;
          b = gray + (b - gray) * saturationFactor;

          result.setPixelRgba(
            x,
            y,
            _clamp255(r * 255),
            _clamp255(g * 255),
            _clamp255(b * 255),
            pixel.a.toInt(),
          );
        }
      }

      final encoded = img.encodePng(result);

      if (!mounted) return;

      setState(() {
        previewBytes = Uint8List.fromList(encoded);
        processing = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        processing = false;
      });

      _showMessage('Image processing error: $e');
    }
  }

  double _adjustChannel(double value, double correction) {
    final normalized = correction / 100;

    if (normalized >= 0) {
      return (value + (1 - value) * normalized).clamp(0.0, 1.0);
    }

    return (value * (1 + normalized)).clamp(0.0, 1.0);
  }

  double _contrast(double value, double amount) {
    final factor = (259 * (amount + 255)) / (255 * (259 - amount));

    return ((factor * (value * 255 - 128) + 128) / 255)
        .clamp(0.0, 1.0);
  }

  double _max3(double a, double b, double c) {
    return [a, b, c].reduce((x, y) => x > y ? x : y);
  }

  int _clamp255(double value) {
    return value.round().clamp(0, 255);
  }

  Future<void> exportImage() async {
    if (previewBytes == null) {
      _showMessage('There is no image to export.');
      return;
    }

    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Export corrected image',
        fileName: _exportFileName(),
        bytes: previewBytes!,
        mimeType: 'image/png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );

      if (uri != null) {
        _showMessage('Image exported successfully.');
      }
    } catch (e) {
      _showMessage('Export error: $e');
    }
  }

  String _exportFileName() {
    final base = fileName ?? 'print_image';

    final dot = base.lastIndexOf('.');

    if (dot == -1) {
      return '${base}_corrected.png';
    }

    return '${base.substring(0, dot)}_corrected.png';
  }

  void resetCorrections() {
    setState(() {
      cyan = 0;
      magenta = 0;
      yellow = 0;
      black = 0;

      brightness = 0;
      contrast = 0;
      saturation = 0;

      zoom = 1;
      rotation = 0;
    });

    processImage();
  }

  void applyPreset(String preset) {
    setState(() {
      switch (preset) {
        case 'Neutral':
          cyan = 0;
          magenta = 0;
          yellow = 0;
          black = 0;
          brightness = 0;
          contrast = 0;
          saturation = 0;
          break;

        case 'Warm':
          cyan = -8;
          magenta = 4;
          yellow = 12;
          black = 0;
          brightness = 2;
          contrast = 3;
          saturation = 5;
          break;

        case 'Cool':
          cyan = 10;
          magenta = 0;
          yellow = -10;
          black = 0;
          brightness = 1;
          contrast = 3;
          saturation = 4;
          break;

        case 'More Ink':
          cyan = 8;
          magenta = 8;
          yellow = 8;
          black = 12;
          brightness = -2;
          contrast = 2;
          saturation = 0;
          break;

        case 'Less Ink':
          cyan = -10;
          magenta = -10;
          yellow = -10;
          black = -12;
          brightness = 3;
          contrast = 0;
          saturation = 0;
          break;
      }
    });

    processImage();
  }

  void rotateLeft() {
    setState(() {
      rotation -= 90;
    });
  }

  void rotateRight() {
    setState(() {
      rotation += 90;
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _processingTimer?.cancel();
    super.dispose();
  }

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
                  _buildLeftPanel(),
                  Expanded(child: _buildPreviewArea()),
                  _buildRightPanel(),
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
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF181B21),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withOpacity(0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.print, size: 28),
          const SizedBox(width: 12),
          const Text(
            'PRINT COLOR APP',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 28),
          FilledButton.icon(
            onPressed: openImage,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: openReference,
            icon: const Icon(Icons.image_search),
            label: const Text('Reference'),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Rotate left',
            onPressed: rotateLeft,
            icon: const Icon(Icons.rotate_left),
          ),
          IconButton(
            tooltip: 'Rotate right',
            onPressed: rotateRight,
            icon: const Icon(Icons.rotate_right),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: previewBytes == null ? null : exportImage,
            icon: const Icon(Icons.download),
            label: const Text('Export'),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    return Container(
      width: 280,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF15181D),
        border: Border(
          right: BorderSide(
            color: Colors.white.withOpacity(0.08),
          ),
        ),
      ),
      child: ListView(
        children: [
          const Text(
            'CORRECTION',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 18),

          _slider(
            'Cyan',
            cyan,
            (v) {
              setState(() => cyan = v);
              scheduleProcessing();
            },
          ),

          _slider(
            'Magenta',
            magenta,
            (v) {
              setState(() => magenta = v);
              scheduleProcessing();
            },
          ),

          _slider(
            'Yellow',
            yellow,
            (v) {
              setState(() => yellow = v);
              scheduleProcessing();
            },
          ),

          _slider(
            'Black',
            black,
            (v) {
              setState(() => black = v);
              scheduleProcessing();
            },
          ),

          const Divider(height: 30),

          const Text(
            'IMAGE',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),

          const SizedBox(height: 12),

          _slider(
            'Brightness',
            brightness,
            (v) {
              setState(() => brightness = v);
              scheduleProcessing();
            },
          ),

          _slider(
            'Contrast',
            contrast,
            (v) {
              setState(() => contrast = v);
              scheduleProcessing();
            },
          ),

          _slider(
            'Saturation',
            saturation,
            (v) {
              setState(() => saturation = v);
              scheduleProcessing();
            },
          ),

          const SizedBox(height: 10),

          OutlinedButton.icon(
            onPressed: resetCorrections,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset all'),
          ),
        ],
      ),
    );
  }

  Widget _buildRightPanel() {
    return Container(
      width: 260,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF15181D),
        border: Border(
          left: BorderSide(
            color: Colors.white.withOpacity(0.08),
          ),
        ),
      ),
      child: ListView(
        children: [
          const Text(
            'PRESETS',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),

          _presetButton('Neutral'),
          _presetButton('Warm'),
          _presetButton('Cool'),
          _presetButton('More Ink'),
          _presetButton('Less Ink'),

          const Divider(height: 32),

          const Text(
            'VIEW',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),

          const SizedBox(height: 10),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Before / Original'),
            value: showBefore,
            onChanged: originalBytes == null
                ? null
                : (value) {
                    setState(() => showBefore = value);
                  },
          ),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Reference'),
            value: showReference,
            onChanged: referenceBytes == null
                ? null
                : (value) {
                    setState(() => showReference = value);
                  },
          ),

          const SizedBox(height: 10),

          Row(
            children: [
              IconButton(
                onPressed: () {
                  setState(() {
                    zoom = (zoom - 0.1).clamp(0.2, 4.0);
                  });
                },
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: Text(
                  '${(zoom * 100).round()}%',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                onPressed: () {
                  setState(() {
                    zoom = (zoom + 0.1).clamp(0.2, 4.0);
                  });
                },
                icon: const Icon(Icons.add),
              ),
            ],
          ),

          const Divider(height: 32),

          const Text(
            'REFERENCE',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),

          const SizedBox(height: 12),

          if (referenceBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                referenceBytes!,
                height: 130,
                fit: BoxFit.contain,
              ),
            )
          else
            Container(
              height: 130,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.white.withOpacity(0.04),
              ),
              child: const Center(
                child: Text(
                  'No reference loaded',
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          const SizedBox(height: 8),

          if (referenceName != null)
            Text(
              referenceName!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea() {
    Widget content;

    if (previewBytes == null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.image_outlined,
            size: 90,
            color: Colors.white.withOpacity(0.18),
          ),
          const SizedBox(height: 20),
          const Text(
            'No image loaded',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Open a print file to begin',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: openImage,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open image'),
          ),
        ],
      );
    } else {
      final bytes = showBefore && originalBytes != null
          ? originalBytes!
          : previewBytes!;

      content = InteractiveViewer(
        minScale: 0.2,
        maxScale: 5,
        child: Transform.rotate(
          angle: rotation * 3.1415926535 / 180,
          child: Transform.scale(
            scale: zoom,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF0D0F12),
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: content,
            ),
          ),

          if (processing)
            const Positioned(
              top: 16,
              right: 16,
              child: Card(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                      SizedBox(width: 10),
                      Text('Processing...'),
                    ],
                  ),
      
