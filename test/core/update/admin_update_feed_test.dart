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
    test('rejects store redirects and values entered in MB instead of bytes', () {
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
        UpdateService.validUpdatePackage('https://example.com/get?id=2', 0),
        isFalse,
      );
    });
  });
}
