import 'package:dio/dio.dart';

import '../di/injector.dart';
import '../playback/playback_prefs.dart';
import '../ui/streaming_prefs.dart';
import '../../features/player/player_controls_config.dart';

/// Public, guest-safe configuration feed. This is deliberately separate from
/// login Supabase, which can point to a different auth project or an offline VPS.
class AdminControlsSync {
  static const _base =
      'https://iwiujqjipotwvigvaaid.supabase.co/rest/v1/animeplex_update_config';
  // Publishable (not service-role) key; RLS exposes SELECT only to guests.
  static const _publicKey =
      'sb_publishable_A436wPL9-Bfc6mg4dtUkQQ_2WLkfY9t';

  static DateTime? _checkedAt;
  static bool _fetching = false;
  static final Dio _client = Dio();

  /// Refresh after startup and on foreground resume, at most every minute.
  /// Failed requests leave the last verified config cached in local Hive.
  static Future<void> refresh({bool force = false}) async {
    if (_fetching || !sl.isRegistered<PlaybackPrefs>()) return;
    final now = DateTime.now();
    if (!force && _checkedAt != null &&
        now.difference(_checkedAt!) < const Duration(minutes: 1)) return;
    _fetching = true;
    try {
      final response = await _client.get<List<dynamic>>(
        _base,
        queryParameters: {
          'id': 'eq.true',
          'select': 'player_controls_enabled,player_controls,allow_player_customization,'
              'streaming_region_enabled,streaming_region,allow_region_customization',
        },
        options: Options(
          headers: const {
            'apikey': _publicKey,
            'Accept': 'application/json',
          },
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
        ),
      );
      final rows = response.data;
      if (rows == null || rows.isEmpty || rows.first is! Map) return;
      final row = Map<String, dynamic>.from(rows.first as Map);
      await applyPublicConfig(row);
      _checkedAt = DateTime.now();
    } catch (_) {
      // Offline, old app schema or Supabase outage: preserve the cached config.
    } finally {
      _fetching = false;
    }
  }

  /// Reject malformed/unknown control IDs before they can reach native Android.
  /// The app's sanitiser also guarantees that pinned More stays accessible.
  static PlayerControlsConfig? validatedLayout(Object? raw) {
    if (raw is! Map) return null;
    List<String>? ids(String key) {
      final value = raw[key];
      if (value is! List || value.any((id) => id is! String)) return null;
      return value.cast<String>();
    }
    final top = ids('top');
    final left = ids('left');
    final right = ids('right');
    if (top == null || left == null || right == null) return null;
    if (top.length > PlayerControlsConfig.maxTop) return null;
    return PlayerControlsConfig(top: top, left: left, right: right).sanitised();
  }

  static Future<void> applyPublicConfig(Map<String, dynamic> row) async {
    final prefs = sl<PlaybackPrefs>();
    final enabled = row['player_controls_enabled'] == true;
    final layout = validatedLayout(row['player_controls']);
    // A corrupt remote layout never overrides working local player controls.
    if (!enabled || layout != null) {
      final safe = layout ?? PlayerControlsConfig.defaults;
      await prefs.applyAdminPlayerControls(
        enabled: enabled,
        allowCustomization: row['allow_player_customization'] != false,
        top: safe.top,
        left: safe.left,
        right: safe.right,
      );
    }
    final region = row['streaming_region'];
    final regionEnabled = row['streaming_region_enabled'] == true;
    if (region is String && kStreamingRegions.contains(region.toUpperCase())) {
      await StreamingPrefs.applyAdminRegion(
        enabled: regionEnabled,
        regionCode: region.toUpperCase(),
        allowCustomization: row['allow_region_customization'] != false,
      );
    }
  }
}
