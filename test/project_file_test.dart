import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:print_color_app/services/project_file.dart';

void main() {
  group('ProjectFile', () {
    test('encode/decode round trip keeps settings and both images', () {
      final original = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final processed = Uint8List.fromList(<int>[9, 8, 7]);

      final bytes = ProjectFile.encode(
        settings: <String, dynamic>{
          'version': ProjectFile.currentVersion,
          'selection': <String, dynamic>{'tolerance': 20.0},
        },
        originalPng: original,
        processedPng: processed,
      );

      final decoded = ProjectFile.decode(bytes);

      expect(decoded.settings['version'], ProjectFile.currentVersion);
      expect(
        jsonDouble(jsonMapOf(decoded.settings['selection'])['tolerance'], 0),
        20.0,
      );
      expect(decoded.originalPng, original);
      expect(decoded.processedPng, processed);
    });

    test('rejects files with a wrong signature', () {
      expect(
        () => ProjectFile.decode(Uint8List.fromList(List<int>.filled(32, 0))),
        throwsFormatException,
      );
    });

    test('rejects truncated files', () {
      final bytes = ProjectFile.encode(
        settings: <String, dynamic>{},
        originalPng: Uint8List.fromList(<int>[1, 2, 3]),
        processedPng: Uint8List.fromList(<int>[4, 5, 6]),
      );

      expect(
        () => ProjectFile.decode(Uint8List.sublistView(bytes, 0, bytes.length - 2)),
        throwsFormatException,
      );
    });
  });
}
