import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/environment.dart';

void main() {
  test('cloud sync defaults to the AnimePlex Cloudflare Worker', () {
    expect(Environment.vpsSyncUrl, 'https://animeplex-sync.ttest.workers.dev');
  });
}
