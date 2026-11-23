import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no application source points to any legacy VPS hostname', () {
    final leaked = <String>[];
    final legacyHost = RegExp(
      r'(?i)(?:https?://)?(?:[a-z0-9-]+\.)?zangetsu\.online',
    );
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = entity.readAsStringSync();
      if (legacyHost.hasMatch(content)) {
        leaked.add(entity.path);
      }
    }
    expect(
      leaked,
      isEmpty,
      reason: 'App files must never call the old VPS, even as a fallback.',
    );
  });

  test('signed-in sync cannot be redirected by the old build flag', () {
    final environment = File('lib/core/environment.dart').readAsStringSync();
    expect(
      RegExp(r'String\.fromEnvironment\(\s*[\x27\x22]VPS_SYNC_URL')
          .hasMatch(environment),
      isFalse,
    );
  });

  test('app no longer requests remote auth-routing manifests', () {
    final route = File('lib/core/supabase/auth_route.dart').readAsStringSync();
    expect(route.contains('/auth-routing/v1.json'), isFalse);
    expect(route.contains('sb.zangetsu.online'), isFalse);
  });
}
