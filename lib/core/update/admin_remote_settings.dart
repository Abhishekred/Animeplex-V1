import 'package:dio/dio.dart';

/// Public admin settings. A failed request never disables existing features.
class AdminRemoteSettings {
  AdminRemoteSettings._();
  static final AdminRemoteSettings instance = AdminRemoteSettings._();
  static const url = 'https://animeplex-admin-control.vercel.app/api/app/config';

  Map<String, dynamic> _settings = {};
  DateTime? _lastFetch;
  Future<void>? _pending;

  Future<void> refresh() async {
    if (_lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < const Duration(minutes: 5)) {
      return;
    }
    if (_pending != null) return _pending!;
    final task = _fetch();
    _pending = task;
    try {
      await task;
    } finally {
      _pending = null;
    }
  }

  Future<void> _fetch() async {
    try {
      final response = await Dio().get<Map<String, dynamic>>(
        url,
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      final settings = response.data?['settings'];
      if (settings is Map) {
        _settings = Map<String, dynamic>.from(settings);
        _lastFetch = DateTime.now();
      }
    } catch (_) {
      // Keep last known settings and existing local behavior.
    }
  }

  bool enabled(String key) => _settings[key] != false;

  String text(String key, {String fallback = ''}) {
    final value = _settings[key];
    return value is String ? value : fallback;
  }
}
