import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_config.dart';
import '../update/admin_remote_settings.dart';
import 'announcement.dart';

/// Fetches the public announcements feed managed by AnimePlex Admin
/// and records any not-yet-seen announcements that target the running version.
///
/// Read-only and fail-safe: offline, API unavailable, or malformed JSON all resolve
/// to "nothing new" — it never throws and never blocks launch.
class AnnouncementService {
  AnnouncementService(this._dio, this._store);

  final Dio _dio;
  final AnnouncementStore _store;

  /// Fetch + store new announcements. Returns the freshly-arrived ones (newest
  /// first) so the caller can pop the launch sheet; the history list reads from
  /// the store. Returns `[]` on any error.
  Future<List<Announcement>> check() async {
    try {
      await AdminRemoteSettings.instance.refresh();
      if (!AdminRemoteSettings.instance.enabled('announcements_enabled')) return const [];
      final res = await _dio.get<String>(
        kAnnouncementsUrl,
        options: Options(
          // Decode the raw JSON body independently of the response content type.
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
        ),
      );
      final list = _extractList(res.data);
      if (list == null) return const [];

      final current = _normalize((await PackageInfo.fromPlatform()).version);
      final fresh = <Announcement>[];
      final active = <Announcement>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final a = Announcement.fromJson(raw);
        if (a == null) continue;
        active.add(a);
        if (!_store.has(a.id) && _targetsVersion(raw, current)) {
          fresh.add(a);
        }
      }
      // A valid empty feed means all admin announcements were unpublished
      // or deleted. Never purge cached history on a network/parse failure.
      await _store.syncAdminFeed(active);
      return fresh;
    } catch (_) {
      return const [];
    }
  }

  List? _extractList(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    dynamic data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (data is Map && data['announcements'] is List) {
      return data['announcements'] as List;
    }
    if (data is List) return data;
    return null;
  }

  /// A version-targeted announcement shows only when the running version is
  /// within [minVersion, maxVersion] (either bound optional).
  bool _targetsVersion(Map raw, String current) {
    final min = _normalize((raw['minVersion'] ?? '').toString());
    final max = _normalize((raw['maxVersion'] ?? '').toString());
    if (min.isNotEmpty && _cmp(current, min) < 0) return false;
    if (max.isNotEmpty && _cmp(current, max) > 0) return false;
    return true;
  }

  /// "v1.6.0+12" → "1.6.0" (digits and dots only).
  static String _normalize(String raw) {
    final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(raw.trim());
    return m?.group(1) ?? '';
  }

  /// -1 / 0 / 1 comparison of dotted-int versions.
  static int _cmp(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }
}
