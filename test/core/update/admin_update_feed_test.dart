import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/update/update_service.dart';

void main() {
  group('Admin update APK validation', () {
    test('accepts a signed-APK shaped direct public asset link', () {
      expect(
        UpdateService.validUpdatePackage(
          'https://github.com/Abhishekred/Animeplex-V1/releases/download/v2.3.8/AnimePlex.apk',
          0,
        ),
        isTrue,
      );
      expect(
        UpdateService.validUpdatePackage(
          'https://cdn.example.com/releases/animeplex.apk?token=public',
          112000000,
        ),
        isTrue,
      );
    });
    test('accepts HTTPS download endpoints without an .apk suffix', () {
      expect(
        UpdateService.validUpdatePackage(
          'https://d.apkpure.com/b/APK/com.Animeplex.music?version=latest',
          0,
        ),
        isTrue,
      );
      expect(
        UpdateService.validUpdatePackage('https://example.com/get?id=2', 0),
        isTrue,
      );
      expect(
        UpdateService.validUpdatePackage('https://example.com/download', 120000000),
        isTrue,
      );
    });
    test('rejects HTTP, credentials, whitespace and sizes typed in MB', () {
      expect(
        UpdateService.validUpdatePackage(
          'https://d.apkpure.com/b/APK/com.Animeplex.music?version=latest',
          24,
        ),
        isFalse,
      );
      expect(
        UpdateService.validUpdatePackage('https://example.com/update.apk', 24),
        isFalse,
      );
      expect(
        UpdateService.validUpdatePackage('http://example.com/update.apk', 0),
        isFalse,
      );
      expect(
        UpdateService.validUpdatePackage(
          'https://someone:secret@example.com/download', 0,
        ),
        isFalse,
      );
      expect(
        UpdateService.validUpdatePackage(
          'https://example.com/bad url', 0,
        ),
        isFalse,
      );
    });
  });
  test('MB estimates do not reject a valid downloaded link but multipart stays exact', () {
    expect(UpdateService.validDownloadedSize(
      24123456, 24000000, multipart: false,
    ), isTrue);
    expect(UpdateService.validDownloadedSize(
      24123456, 24000000, multipart: true,
    ), isFalse);
    expect(UpdateService.validDownloadedSize(
      24000000, 24000000, multipart: true,
    ), isTrue);
    expect(UpdateService.validDownloadedSize(
      24000000, 0, multipart: false,
    ), isTrue);
    expect(UpdateService.validDownloadedSize(
      24, 24000000, multipart: false,
    ), isFalse);
  });
  test('multipart APK manifest validates sizes, ordering and safe paths', () {
    const owner = '12345678-1234-1234-1234-123456789abc';
    const build = '12345678-1234-1234-1234-123456789def';
    final parts = [
      {'path': 'releases/$owner/$build/part-001.bin',
       'size': 32 * 1024 * 1024},
      {'path': 'releases/$owner/$build/part-002.bin',
       'size': 16000000},
    ];
    expect(
      MultipartUpdate.validManifest(parts, 32 * 1024 * 1024 + 16000000),
      isTrue,
    );
    expect(MultipartUpdate.validManifest(parts, 24), isFalse);
    expect(
      MultipartUpdate.validManifest([
        {'path': 'releases/../../other/part-001.bin', 'size': 2000000},
      ], 2000000),
      isFalse,
    );
  });

}
