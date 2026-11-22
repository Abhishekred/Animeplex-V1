import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:watch_app/core/environment.dart';

// Store AnimePlex sessions under the new project's own key. Old-project
// access/refresh tokens must never be restored against the new Auth issuer.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pinned session storage key', () {
    test('matches the SDK derivation for the current Cloud URL', () {
      final derived =
          'sb-${Uri.parse('https://iwiujqjipotwvigvaaid.supabase.co').host.split('.').first}-auth-token';
      expect(Environment.supabaseSessionStorageKey, derived);
    });

    test('differs from the previous auth project session key', () {
      // A previous Zangetsu login must not be adopted by AnimePlex Auth.
      const oldSessionKey = 'sb-eogwzrlfoercfwcfwlmv-auth-token';
      expect(Environment.supabaseSessionStorageKey, isNot(oldSessionKey));
    });
  });

  group('SharedPreferencesLocalStorage round-trip', () {
    test('persists and restores a session under the pinned key', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = SharedPreferencesLocalStorage(
        persistSessionKey: Environment.supabaseSessionStorageKey,
      );
      await storage.initialize();

      expect(await storage.hasAccessToken(), isFalse);
      const sessionJson = '{"access_token":"a.b.c","user":{"id":"u1"}}';
      await storage.persistSession(sessionJson);

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), sessionJson);

      // A second storage instance (simulating the retry-init path / next
      // launch) must read the same persisted session from the same key.
      final second = SharedPreferencesLocalStorage(
        persistSessionKey: Environment.supabaseSessionStorageKey,
      );
      await second.initialize();
      expect(await second.accessToken(), sessionJson);
    });

    test('removePersistedSession clears the pinned key', () async {
      SharedPreferences.setMockInitialValues({
        Environment.supabaseSessionStorageKey: '{"access_token":"x"}',
      });
      final storage = SharedPreferencesLocalStorage(
        persistSessionKey: Environment.supabaseSessionStorageKey,
      );
      await storage.initialize();
      expect(await storage.hasAccessToken(), isTrue);
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
    });
  });

  group('both Supabase.initialize paths pin the key', () {
    test('boot and retry initializers both pass the pinned localStorage', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final occurrences =
          'persistSessionKey: Environment.supabaseSessionStorageKey'
              .allMatches(mainSource)
              .length;
      expect(
        occurrences,
        2,
        reason:
            'Both Supabase.initialize calls (boot + _retrySupabaseInit) '
            'must override the session storage key; if an initializer '
            'loses the override, a URL switch would silently strand the '
            'new project session.',
      );
    });
  });
}
