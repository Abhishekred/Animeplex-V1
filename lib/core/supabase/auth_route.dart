import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../environment.dart';

/// AnimePlex is permanently bound to its own Supabase Auth project.
/// Old VPS authority manifests and stored routes are never trusted.
class AuthRoute {
  const AuthRoute._();

  static AuthRoute active = cloud;
  static const AuthRoute cloud = AuthRoute._();

  String get authority => 'cloud';
  int get generation => 0;
  String get anonKey => Environment.supabaseAnonKey;
  String get url => Environment.supabaseUrl;
}

class AuthRouteDecision {
  const AuthRouteDecision(this.route, {required this.changed});
  final AuthRoute route;
  final bool changed;
}

/// Compatibility wrapper for older callers. Never requests a remote manifest;
/// any saved VPS routing configuration is discarded on launch.
class AuthRouteResolver {
  AuthRouteResolver({
    required this.preferences,
    required this.client,
    this.timeout = const Duration(milliseconds: 1200),
  });

  static const cacheKey = 'auth_route_v1';
  final SharedPreferences preferences;
  final http.Client client;
  final Duration timeout;

  Future<AuthRouteDecision> resolve() async {
    await preferences.remove(cacheKey);
    return const AuthRouteDecision(AuthRoute.cloud, changed: false);
  }
}
