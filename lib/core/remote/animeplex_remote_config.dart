import 'dart:convert';
import 'package:dio/dio.dart';

/// Read-only AnimePlex Admin Studio remote configuration.
/// No admin credentials or privileged Supabase keys are stored in the app.
class AnimeplexRemoteConfig {
  AnimeplexRemoteConfig({Dio? dio}) : _dio = dio ?? Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );

  static const endpoint =
      'https://animeplex-admin-control.vercel.app/api/app/config';

  final Dio _dio;
  Map<String, dynamic> _settings = const {};
  Map<String, dynamic> get settings => Map.unmodifiable(_settings);

  Future<Map<String, dynamic>> refresh() async {
    try {
      final response = await _dio.get<dynamic>(endpoint);
      final payload = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (payload is! Map || payload['schema_version'] != 1 ||
          payload['settings'] is! Map) {
        throw const FormatException('Invalid AnimePlex config payload');
      }
      final next = <String, dynamic>{};
      for (final entry in (payload['settings'] as Map).entries) {
        if (entry.key is String) next[entry.key as String] = entry.value;
      }
      _settings = Map.unmodifiable(next);
    } catch (_) {
      // Keep last known settings and preserve offline app startup.
    }
    return settings;
  }
}
