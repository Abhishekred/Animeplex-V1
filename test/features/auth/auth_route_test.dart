import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/supabase/auth_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  var requests = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    requests = 0;
  });

  AuthRouteResolver resolver() => AuthRouteResolver(
    preferences: preferences,
    client: MockClient((_) async {
      requests++;
      return http.Response(
        '{"schema":1,"generation":100,"authority":"vps","anonKey":"old-key"}',
        200,
      );
    }),
  );

  test('pins login to new Supabase project without routing network requests', () async {
    final decision = await resolver().resolve();
    expect(decision.route.authority, 'cloud');
    expect(decision.route.url, Environment.supabaseUrl);
    expect(decision.route.anonKey, Environment.supabaseAnonKey);
    expect(decision.changed, isFalse);
    expect(requests, 0);
  });

  test('discards saved VPS routing even when it is malformed', () async {
    for (final cached in [
      '{"schema":1,"generation":42,"authority":"vps","anonKey":"old"}',
      '{bad JSON',
      'x' * 18000,
    ]) {
      await preferences.setString(AuthRouteResolver.cacheKey, cached);
      final result = await resolver().resolve();
      expect(result.route.authority, 'cloud');
      expect(result.route.url, Environment.supabaseUrl);
      expect(preferences.getString(AuthRouteResolver.cacheKey), isNull);
    }
    expect(requests, 0);
  });

  test('network failures cannot re-enable the old login authority', () async {
    await preferences.setString(AuthRouteResolver.cacheKey, 'vps');
    final offline = AuthRouteResolver(
      preferences: preferences,
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    final result = await offline.resolve();
    expect(result.route.authority, 'cloud');
    expect(result.changed, isFalse);
    expect(preferences.getString(AuthRouteResolver.cacheKey), isNull);
  });
}
