import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// `watch_region` codes TMDB accepts, common markets first. A short fixed list
/// rather than a fetch: it changes about once a year, and a picker that needs
/// the network to open is a picker that fails offline.
const List<String> kStreamingRegions = [
  'IN', 'US', 'GB', 'CA', 'AU', 'DE', 'FR', 'ES', 'IT', 'BR', //
  'MX', 'JP', 'KR', 'SG', 'AE', 'ZA', 'NL', 'SE', 'PL', 'ID',
];

/// Which country's streaming catalogue to show.
///
/// Deliberately dumb storage, same shape as `HomeRowsPrefs`: every read is
/// synchronous and tolerant, because `TmdbCatalogue.rowTitles()` is called
/// during widget build and cannot await anything.
class StreamingPrefs {
  const StreamingPrefs._();

  static const String boxName = 'streaming_prefs';
  static const String _regionKey = 'region';
  /// Bumped on every write so Home reloads without resetting its scroll — same
  /// contract as `HomeRowsPrefs.revision`.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Overridable so tests never depend on the host machine's locale.
  @visibleForTesting
  static String Function() deviceRegion = _deviceRegion;

  @visibleForTesting
  static void resetDeviceRegionForTest() => deviceRegion = _deviceRegion;

  static String _deviceRegion() {
    final c = PlatformDispatcher.instance.locale.countryCode;
    return _valid(c) ? c!.toUpperCase() : 'US';
  }

  static bool _valid(String? v) =>
      v != null && v.length == 2 && RegExp(r'^[A-Za-z]{2}$').hasMatch(v);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Admin defaults are cached in this Hive box, with offline fallback.
  /// A locked admin region always wins; otherwise a viewer's own choice wins.
  static bool get adminRegionEnabled =>
      _boxOrNull?.get('adminRegionEnabled', defaultValue: false) == true;
  static bool get allowRegionCustomization =>
      _boxOrNull?.get('adminAllowRegionCustomization', defaultValue: true) != false;
  static bool get regionLocked =>
      adminRegionEnabled && !allowRegionCustomization;

  static String get region {
    final stored = _boxOrNull?.get(_regionKey);
    final personal = stored is String && _valid(stored)
        ? stored.toUpperCase()
        : null;
    final remote = _boxOrNull?.get('adminStreamingRegion');
    final admin = remote is String && _valid(remote)
        ? remote.toUpperCase()
        : null;
    if (adminRegionEnabled && admin != null && (regionLocked || personal == null)) {
      return admin;
    }
    return personal ?? deviceRegion();
  }

  static Future<void> applyAdminRegion({
    required bool enabled,
    required String regionCode,
    required bool allowCustomization,
  }) async {
    final box = _boxOrNull;
    if (box == null || !_valid(regionCode)) return;
    final before = region;
    await box.putAll({
      'adminRegionEnabled': enabled,
      'adminStreamingRegion': regionCode.toUpperCase(),
      'adminAllowRegionCustomization': allowCustomization,
    });
    if (before != region) revision.value++;
  }

  static Future<void> setRegion(String r) async {
    final box = _boxOrNull;
    if (box == null || !_valid(r) || regionLocked) return;
    final before = region;
    await box.put(_regionKey, r.toUpperCase());
    if (before != region) revision.value++;
  }
}
