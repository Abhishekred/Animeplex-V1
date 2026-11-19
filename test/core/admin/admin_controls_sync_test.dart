import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/admin/admin_controls_sync.dart';

void main() {
  test('accepts a valid published layout, leaving More accessible', () {
    final result = AdminControlsSync.validatedLayout({
      'top': ['cast', 'info'],
      'left': ['speed', 'tracks', 'sources'],
      'right': ['episodes', 'rotate', 'fit'],
    });
    expect(result, isNotNull);
    expect(result!.left, contains('more'));
  });

  test('rejects malformed layouts and overfull top bar', () {
    expect(AdminControlsSync.validatedLayout({'top': [], 'left': []}), isNull);
    expect(AdminControlsSync.validatedLayout({
      'top': ['cast', 'info', 'quality', 'tracks', 'sources', 'speed'],
      'left': ['more'], 'right': [],
    }), isNull);
  });

  test('unknown controls are ignored and duplicates removed', () {
    final result = AdminControlsSync.validatedLayout({
      'top': ['cast', 'cast', 'unknown'],
      'left': ['more'],
      'right': ['episodes'],
    })!;
    expect(result.top, ['cast']);
    expect(result.hidden, isNot(contains('cast')));
    expect(result.left, contains('more'));
  });
}
