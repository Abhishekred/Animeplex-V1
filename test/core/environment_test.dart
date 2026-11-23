import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/environment.dart';

void main() {
  test('all app sync and login endpoints are pinned to AnimePlex services', () {
    expect(Environment.supabaseUrl,
        'https://iwiujqjipotwvigvaaid.supabase.co');
    expect(Environment.vpsSyncUrl,
        'https://animeplex-sync.ttest.workers.dev');
    expect(Environment.siteBaseUrl, 'https://abhishek.dpdns.org');
    expect(Environment.passwordResetUrl, isNot(contains('zangetsu.online')));
  });
}
