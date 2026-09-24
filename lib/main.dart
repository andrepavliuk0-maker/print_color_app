import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

void main() {
  runApp(const PrintColorStudio());
}

class PrintColorStudio extends StatelessWidget {
  const PrintColorStudio({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Color Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
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
  img.Image? originalImage;
  img.Image? editedImage;

  Uint8List? originalBytes;
  Uint8List? editedBytes;
  Uint8List? referenceBytes;

  String fileName = 'No image loaded';
  String status = 'Ready';

  double cyan = 0;
  double magenta = 0;
  double yellow = 0;
  double black = 0;

  double brightness = 0;
  double contrast = 0;
  double saturation = 0;

  bool showBefore = false;
  bool showReference = false;
  bool processing = false;

  double zoom = 1.0;
  int rotation = 0;

  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> openImage() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.image,
      );

      if (file == null) return;

      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        setState(() {
          status = 'Could not decode image';
        });
        return;
      }

      setState(() {
        originalBytes = bytes;
        originalImage = decoded;
        editedImage = decoded.clone();
        editedBytes = bytes;
        fileName = file.name;
        status = 'Image loaded';
        showBefore = false;
        showReference = false;
        zoom = 1.0;
        rotation = 0;
      });

      _processImage();
    } catch (e) {
      setState(() {
        status = 'Open error: $e';
      });
    }
  }

  Future<void> openReference() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.image,
      );

      if (file == null) return;

      final bytes = await file.readAsBytes();

      setState(() {
        referenceBytes = bytes;
        showReference = true;
        status = 'Reference image loaded';
      });
    } catch (e) {
      setState(() {
        status = 'Reference error: $e';
      });
    }
  }

  Future<void> exportImage() async {
    if (editedImage == null) {
      setState(() {
        status = 'Nothing to export';
      });
      return;
    }

    try {
      setState(() {
        status = 'Preparing export...';
      });

      final output = img.encodePng(editedImage!);

      final baseName = fileName.contains('.')
          ? fileName.substring(0, fileName.lastIndexOf('.'))
          : fileName;

      final uri = await FilePicker.saveFile(
        dialogTitle: 'Export corrected image',
        fileName: '${baseName}_corrected.png',
        bytes: Uint8List.fromList(output),
        mimeType: 'image/png',
      );

      if (!mounted) return;

      setState(() {
        status = uri == null ? 'Export cancelled' : 'Export completed';
      });
    } catch (e) {
      setState(() {
        status = 'Export error: $e';
      });
    }
  }

  void scheduleProcessing() {
    _timer?.cancel();

    _timer = Timer(
      const Duration(milliseconds: 120),
      _processImage,
    );
  }

  Future<void> _processImage() async {
    if (originalImage == null || processing) return;

    setState(() {
      processing = true;
      status = 'Processing...';
    });

    await Future<void>.delayed(Duration.zero);

    final source = originalImage!;
    final result = source.clone();

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = source.getPixel(x, y);

        double r = pixel.r.toDouble() / 255.0;
        double g = pixel.g.toDouble() / 255.0;
        double b = pixel.b.toDouble() / 255.0;

        double k = 1.0 - math.max(r, math.max(g, b));

        double c;
        double m;
        double yValue;

        if (k >= 0.999999) {
          c = 0;
          m = 0;
          yValue = 0;
        } else {
          c = (1 - r - k) / (1 - k);
          m = (1 - g - k) / (1 - k);
          yValue = (1 - b - k) / (1 - k);
        }

        c = _clamp01(c + cyan / 100.0);
        m = _clamp01(m + magenta / 100.0);
        yValue = _clamp01(yValue + yellow / 100.0);
        k = _clamp01(k + black / 100.0);

        r = (1 - c) * (1 - k);
        g = (1 - m) * (1 - k);
        b = (1 - yValue) * (1 - k);

        final brightnessOffset = brightness / 100.0;

        r += brightnessOffset;
        g += brightnessOffset;
        b += brightnessOffset;

        final contrastFactor =
            (259.0 * (contrast + 255.0)) /
            (255.0 * (259.0 - contrast));

        r = contrastFactor * (r - 0.5) + 0.5;
        g = contrastFactor * (g - 0.5) + 0.5;
        b = contrastFactor * (b - 0.5) + 0.5;

        final gray =
            0.299 * r +
            0.587 * g +
            0.114 * b;

        final saturationFactor =
            1.0 + saturation / 100.0;

        r = gray + (r - gray) * saturationFactor;
        g = gray + (g - gray) * saturationFactor;
        b = gray + (b - gray) * saturationFactor;

        final rr = (_clamp01(r) * 255).round();
        final gg = (_clamp01(g) * 255).round();
        final bb = (_clamp01(b) * 255).round();

        result.setPixelRgb(x, y, rr, gg, bb);
      }
    }

    if (!mounted) return;

    setState(() {
      editedImage = result;
      editedBytes =
          Uint8List.fromList(img.encodePng(result));
      processing = false;
      status = 'Ready';
    });
  }

  double _clamp01(double value) {
    return value.clamp(0.0, 1.0);
  }

  void resetAdjustments() {
    setState(() {
      cyan = 0;
      magenta = 0;
      yellow = 0;
      black = 0;
      brightness = 0;
      contrast = 0;
      saturation = 0;
      zoom = 1.0;
      rotation = 0;
      showBefore = false;
    });

    _processImage();
  }

  void applyPreset(String preset) {
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
        cyan = -5;
        magenta = 2;
        yellow = 8;
        black = 0;
        brightness = 2;
        contrast = 0;
        saturation = 4;
        break;

      case 'Cool':
        cyan = 8;
        magenta = 0;
        yellow = -8;
        black = 0;
        brightness = 1;
        contrast = 0;
        saturation = 3;
        break;

      case 'More Ink':
        cyan = 5;
        magenta = 5;
        yellow = 5;
        black = 8;
        brightness = -2;
        contrast = 3;
        saturation = 0;
        break;

      case 'Less Ink':
        cyan = -5;
        magenta = -5;
        yellow = -5;
        black = -8;
        brightness = 2;
        contrast = 0;
        saturation = 0;
        break;
    }

    setState(() {});
    _processImage();
  }

  void rotateLeft() {
    if (originalImage == null) return;

    setState(() {
      rotation = (rotation - 90) % 360;
    });
  }

  void rotateRight() {
    if (originalImage == null) return;

    setState(() {
      rotation = (rotation + 90) % 360;
    });
  }

  void zoomIn() {
    setState(() {
      zoom = math.min(zoom + 0.25, 4.0);
    });
  }

  void zoomOut() {
    setState(() {
      zoom = math.max(zoom - 0.25, 0.25);
    });
  }

  String _formatValue(double value) {
    if (value > -0.01 && value < 0.01) {
      return '0';
    }

    return value.toStringAsFixed(0);
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.white70,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Divider(height: 1),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                _formatValue(value),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: -100,
          max: 100,
          divisions: 200,
          onChanged: (newValue) {
            onChanged(newValue);
            scheduleProcessing();
          },
        ),
      ],
    );
  }

  Widget _smallButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null
          ? const SizedBox.shrink()
          : Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
      ),
    );
  }
    Widget _buildLeftPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('COLOR CORRECTION'),

          _slider(
            label: 'Cyan',
            value: cyan,
            color: Colors.cyan,
            onChanged: (value) => setState(() => cyan = value),
          ),

          _slider(
            label: 'Magenta',
            value: magenta,
            color: Colors.pink,
            onChanged: (value) => setState(() => magenta = value),
          ),

          _slider(
            label: 'Yellow',
            value: yellow,
            color: Colors.yellow,
            onChanged: (value) => setState(() => yellow = value),
          ),

          _slider(
            label: 'Black',
            value: black,
            color: Colors.grey,
            onChanged: (value) => setState(() => black = value),
          ),

          _divider(),

          _sectionTitle('IMAGE'),

          _slider(
            label: 'Brightness',
            value: brightness,
            color: Colors.orange,
            onChanged: (value) => setState(() => brightness = value),
          ),

          _slider(
            label: 'Contrast',
            value: contrast,
            color: Colors.blueGrey,
            onChanged: (value) => setState(() => contrast = value),
          ),

          _slider(
            label: 'Saturation',
            value: saturation,
            color: Colors.purple,
            onChanged: (value) => setState(() => saturation = value),
          ),

          _divider(),

          _sectionTitle('VIEW'),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _smallButton(
                label: 'Before',
                icon: Icons.compare,
                onPressed: () {
                  setState(() {
                    showBefore = !showBefore;
                  });
                },
              ),
              _smallButton(
                label: 'Reference',
                icon: Icons.image,
                onPressed: () {
                  if (referenceBytes == null) {
                    openReference();
                  } else {
                    setState(() {
                      showReference = !showReference;
                    });
                  }
                },
              ),
              _smallButton(
                label: 'Reset',
                icon: Icons.restart_alt,
                onPressed: resetAdjustments,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRightPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('PRESETS'),

          SizedBox(
            width: double.infinity,
            child: Column(
              children: [
                _presetButton('Neutral'),
                const SizedBox(height: 6),
                _presetButton('Warm'),
                const SizedBox(height: 6),
                _presetButton('Cool'),
                const SizedBox(height: 6),
                _presetButton('More Ink'),
                const SizedBox(height: 6),
                _presetButton('Less Ink'),
              ],
            ),
          ),

          _divider(),

          _sectionTitle('CURRENT VALUES'),

          _valueRow('C', cyan),
          _valueRow('M', magenta),
          _valueRow('Y', yellow),
          _valueRow('K', black),

          const SizedBox(height: 16),

          _valueRow('Brightness', brightness),
          _valueRow('Contrast', contrast),
          _valueRow('Saturation', saturation),

          _divider(),

          _sectionTitle('REFERENCE'),

          if (referenceBytes == null)
            const Text(
              'No reference image loaded.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                referenceBytes!,
                width: double.infinity,
                height: 160,
                fit: BoxFit.contain,
              ),
            ),
        ],
      ),
    );
  }

  Widget _presetButton(String name) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: () => applyPreset(name),
        child: Text(name),
      ),
    );
  }

  Widget _valueRow(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
              ),
            ),
          ),
          Text(
            _formatValue(value),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    final bytes = showBefore ? originalBytes : editedBytes;

    if (bytes == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: 72,
              color: Colors.white24,
            ),
            SizedBox(height: 16),
            Text(
              'Open an image to begin',
              style: TextStyle(
                fontSize: 18,
                color: Colors.white70,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'PNG, JPG and other supported image formats',
              style: TextStyle(
                color: Colors.white38,
              ),
            ),
          ],
        ),
      );
    }

    Widget image = Image.memory(
      bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );

    if (rotation != 0) {
      image = RotatedBox(
        quarterTurns: rotation ~/ 90,
        child: image,
      );
    }

    final displayedImage = InteractiveViewer(
      minScale: 0.25,
      maxScale: 4.0,
      child: Transform.scale(
        scale: zoom,
        child: image,
      ),
    );

    if (showReference && referenceBytes != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: displayedImage,
          ),
          Positioned(
            right: 16,
            top: 16,
            child: Container(
              width: 180,
              height: 180,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.white24,
                ),
              ),
              child: Image.memory(
                referenceBytes!,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: displayedImage,
    );
  }

  Widget _buildStatusBar() {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest,
        border: const Border(
          top: BorderSide(
            color: Colors.white12,
          ),
        ),
      ),
      child: Row(
        children: [
          if (processing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
              ),
            ),

          if (processing)
            const SizedBox(width: 8),

          Expanded(
            child: Text(
              status,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white60,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          Text(
            fileName,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white38,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: const Border(
          bottom: BorderSide(
            color: Colors.white12,
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.colorize,
            color: Colors.blue,
          ),

          const SizedBox(width: 10),

          const Text(
            'PRINT COLOR STUDIO',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),

          const SizedBox(width: 20),

          FilledButton.icon(
            onPressed: openImage,
            icon: const Icon(Icons.folder_open),
            label: const Text('OPEN'),
          ),

          const SizedBox(width: 8),

          OutlinedButton.icon(
            onPressed: openReference,
            icon: const Icon(Icons.photo),
            label: const Text('REFERENCE'),
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

          IconButton(
            tooltip: 'Zoom out',
            onPressed: zoomOut,
            icon: const Icon(Icons.zoom_out),
          ),

          Text(
            '${(zoom * 100).round()}%',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white60,
            ),
          ),

          IconButton(
            tooltip: 'Zoom in',
            onPressed: zoomIn,
            icon: const Icon(Icons.zoom_in),
          ),

          const SizedBox(width: 8),

          FilledButton.icon(
            onPressed: exportImage,
            icon: const Icon(Icons.save_alt),
            label: const Text('EXPORT'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 900;

            if (compact) {
              return Column(
                children: [
                  _buildToolbar(),

                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Container(
                            color: const Color(0xFF151515),
                            child: _buildCanvas(),
                          ),
                        ),

                        Expanded(
                          flex: 5,
                          child: DefaultTabController(
                            length: 2,
                            child: Column(
                              children: [
                                const TabBar(
                                  tabs: [
                                    Tab(text: 'CORRECTION'),
                                    Tab(text: 'PRESETS'),
                                  ],
                                ),

                                Expanded(
                                  child: TabBarView(
                                    children: [
                                      _buildLeftPanel(),
                                      _buildRightPanel(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  _buildStatusBar(),
                ],
              );
            }

            return Column(
              children: [
                _buildToolbar(),

                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 290,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surface,
                            border: const Border(
                              right: BorderSide(
                                color: Colors.white12,
                              ),
                            ),
                          ),
                          child: _buildLeftPanel(),
                        ),
                      ),

                      Expanded(
                        child: Container(
                          color: const Color(0xFF151515),
                          child: _buildCanvas(),
                        ),
                      ),

                      SizedBox(
                        width: 260,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surface,
                            border: const Border(
                              left: BorderSide(
                                color: Colors.white12,
                              ),
                            ),
                          ),
                          child: _buildRightPanel(),
                        ),
                      ),
                    ],
                  ),
                ),

                _buildStatusBar(),
              ],
            );
          },
        ),
      ),
    );
  }
}
