import 'dart:io';

import 'package:dio/dio.dart';

/// One immutable piece of an admin-uploaded release APK.
class UpdatePart {
  const UpdatePart({required this.url, required this.size});
  final String url;
  final int size;
}

/// 32 MiB pieces let APKs larger than the Supabase Free 50 MB upload cap
/// travel through public Storage without proxying them via Vercel.
class MultipartUpdate {
  static const int maxPartSize = 32 * 1024 * 1024;
  static const int maxApkSize = 800 * 1024 * 1024;
  static const String publicBucketUrl =
      'https://iwiujqjipotwvigvaaid.supabase.co'
      '/storage/v1/object/public/animeplex-releases';

  static bool validManifest(List<dynamic> raw, int expectedSize) {
    if (raw.isEmpty || raw.length > 100 ||
        expectedSize < 1000000 || expectedSize > maxApkSize) {
      return false;
    }
    final validPath = RegExp(
      r'^releases/[0-9a-f-]{36}/[0-9a-f-]{36}/part-[0-9]{3}\.bin$',
    );
    final seen = <String>{};
    var sum = 0;
    for (var index = 0; index < raw.length; index++) {
      final item = raw[index];
      if (item is! Map) return false;
      final path = item['path'];
      final size = item['size'];
      final suffix =
          'part-' + (index + 1).toString().padLeft(3, '0') + '.bin';
      if (path is! String || !validPath.hasMatch(path) ||
          !path.endsWith(suffix) || !seen.add(path) ||
          size is! num || size.toInt() != size ||
          size < 1 || size > maxPartSize) {
        return false;
      }
      sum += size.toInt();
    }
    return sum == expectedSize;
  }

  static List<UpdatePart> parse(List<dynamic> raw) {
    return raw.map((item) {
      final part = item as Map;
      final path = part['path'] as String;
      final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
      return UpdatePart(
        url: publicBucketUrl + '/' + encodedPath,
        size: (part['size'] as num).toInt(),
      );
    }).toList(growable: false);
  }

  /// Streams each verified part to disk; never loads the full APK into RAM.
  static Future<void> download({
    required Dio dio,
    required List<UpdatePart> parts,
    required File destination,
    required int expectedSize,
    void Function(double)? onProgress,
  }) async {
    final sink = destination.openWrite();
    var completed = 0;
    try {
      for (var index = 0; index < parts.length; index++) {
        final part = parts[index];
        final temp = File(destination.path + '.part-' + index.toString());
        if (await temp.exists()) await temp.delete();
        try {
          await dio.download(
            part.url,
            temp.path,
            onReceiveProgress: (received, total) {
              if (expectedSize > 0) {
                final value = (completed + received) / expectedSize;
                onProgress?.call(value.clamp(0.0, 1.0).toDouble());
              }
            },
          );
          final length = await temp.length();
          if (length != part.size) {
            throw StateError('APK part ' + (index + 1).toString() +
                ' is incomplete.');
          }
          await sink.addStream(temp.openRead());
          completed += length;
          if (expectedSize > 0) {
            onProgress?.call(
              (completed / expectedSize).clamp(0.0, 1.0).toDouble(),
            );
          }
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}
