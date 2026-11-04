import 'dart:convert';
import 'dart:typed_data';

/// Формат файла проекта `.pcproj`.
///
/// Структура:
///   6 байт  — сигнатура "PCPROJ"
///   1 байт  — версия формата (1 или 2)
///   блоки   — каждый: 4 байта длины (big-endian) + данные
///
/// Блоки:
///   1. JSON с настройками
///   2. PNG исходного изображения
///   3. PNG текущего результата (только версия 2)
class ProjectFile {
  static const List<int> _signature = <int>[
    0x50, // P
    0x43, // C
    0x50, // P
    0x52, // R
    0x4F, // O
    0x4A, // J
  ];

  static const int currentVersion = 2;

  final Map<String, dynamic> settings;
  final Uint8List originalPng;

  /// В проектах версии 1 результата нет.
  final Uint8List? processedPng;

  const ProjectFile({
    required this.settings,
    required this.originalPng,
    this.processedPng,
  });

  static Uint8List encode({
    required Map<String, dynamic> settings,
    required Uint8List originalPng,
    required Uint8List processedPng,
  }) {
    final builder = BytesBuilder(copy: false);

    builder.add(_signature);
    builder.addByte(currentVersion);

    _addBlock(
      builder,
      Uint8List.fromList(utf8.encode(jsonEncode(settings))),
    );
    _addBlock(builder, originalPng);
    _addBlock(builder, processedPng);

    return builder.toBytes();
  }

  static ProjectFile decode(Uint8List bytes) {
    final headerLength = _signature.length + 1;

    if (bytes.length < headerLength) {
      throw const FormatException('Файл проекта повреждён или слишком короткий.');
    }

    for (var i = 0; i < _signature.length; i++) {
      if (bytes[i] != _signature[i]) {
        throw const FormatException('Это не файл проекта Print Color App.');
      }
    }

    final version = bytes[_signature.length];

    if (version != 1 && version != 2) {
      throw FormatException('Неизвестная версия проекта: $version.');
    }

    final blockCount = version == 1 ? 2 : 3;
    final data = ByteData.sublistView(bytes);

    final blocks = <Uint8List>[];
    var offset = headerLength;

    for (var i = 0; i < blockCount; i++) {
      if (offset + 4 > bytes.length) {
        throw const FormatException('Файл проекта повреждён.');
      }

      final length = data.getUint32(offset, Endian.big);
      offset += 4;

      if (length > bytes.length - offset) {
        throw const FormatException('Файл проекта повреждён.');
      }

      blocks.add(Uint8List.sublistView(bytes, offset, offset + length));
      offset += length;
    }

    final decoded = jsonDecode(utf8.decode(blocks[0]));

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Настройки проекта повреждены.');
    }

    return ProjectFile(
      settings: decoded,
      originalPng: blocks[1],
      processedPng: blockCount > 2 ? blocks[2] : null,
    );
  }

  static void _addBlock(BytesBuilder builder, Uint8List data) {
    final length = ByteData(4)..setUint32(0, data.length, Endian.big);

    builder.add(length.buffer.asUint8List());
    builder.add(data);
  }
}

// ============================================================
// SAFE JSON READERS
// ============================================================

Map<String, dynamic> jsonMapOf(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }

  return const <String, dynamic>{};
}

double jsonDouble(Object? value, double fallback) {
  if (value is num) {
    return value.toDouble();
  }

  return fallback;
}

int? jsonInt(Object? value) {
  if (value is num) {
    return value.toInt();
  }

  return null;
}

bool jsonBool(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }

  return fallback;
}

String? jsonString(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }

  return null;
}
