import 'dart:io';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A newer release explicitly published from the AnimePlex Admin dashboard.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.assetName,
    required this.apkSize,
    this.isPrerelease = false,
    this.isMandatory = false,
  });

  /// Normalised version, e.g. "1.3.0".
  final String version;

  /// Release notes set by the AnimePlex release manager.
  final String notes;

  /// Direct download URL of the chosen .apk asset.
  final String apkUrl;

  /// File name of the chosen asset (shown while downloading).
  final String assetName;

  /// Expected byte size entered by the admin, used to verify the
  /// download completed intact. 0 when unknown.
  final int apkSize;

  /// True when the admin published this release on the beta channel.
  final bool isPrerelease;

  /// Admin-marked required release; hide the optional version-skip action.
  final bool isMandatory;
}

/// Update feed controlled exclusively through the AnimePlex Admin dashboard.
/// No GitHub Releases are checked or announced automatically. Draft and paused
/// releases are invisible via Supabase row-level security.
class UpdateService {
  static const String fallbackRepositoryUrl =
      'https://github.com/Abhishekred/Animeplex-V1';
  static const String _boxName = 'updates';
  static const String _skipKey = 'skippedVersion';
  static const String _betaKey = 'betaOptIn';

  final Dio _dio = Dio();

  /// Non-null if a check failed, so manual checks don't claim "latest" on
  /// network or authentication errors. Auto checks intentionally stay silent.
  String? lastCheckError;

  /// About → GitHub is also admin-controlled; fall back to this app's own repo
  /// when offline, never to the upstream Zangetsu repository.
  Future<String> repositoryUrl() async {
    try {
      final result = await Supabase.instance.client
          .from('animeplex_update_config')
          .select('repository_url')
          .eq('id', true)
          .maybeSingle();
      final url = (result?['repository_url'] as String?)?.trim() ?? '';
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        return url;
      }
    } catch (_) {}
    return fallbackRepositoryUrl;
  }

  /// A release is eligible only if an authorized admin clicked Publish and
  /// the global update switch is enabled. A beta release also needs both the
  /// admin beta switch and the device's explicit beta opt-in.
  Future<UpdateInfo?> checkForUpdate({
    bool respectSkip = false,
    bool automatic = false,
  }) async {
    lastCheckError = null;
    try {
      final client = Supabase.instance.client;
      final settings = await client
          .from('animeplex_update_config')
          .select('enabled,auto_check,beta_enabled')
          .eq('id', true)
          .maybeSingle();
      if (settings == null || settings['enabled'] != true) return null;
      if (automatic && settings['auto_check'] != true) return null;

      final allowBeta =
          settings['beta_enabled'] == true && await betaOptIn();
      final current = (await PackageInfo.fromPlatform()).version;
      final skipped = respectSkip ? await _skippedVersion() : null;

      final releases = await client
          .from('animeplex_update_releases')
          .select('version,channel,release_notes,apk_url,apk_size,mandatory')
          .eq('status', 'published')
          .limit(100);

      Map<String, dynamic>? best;
      String bestVersion = '';
      for (final r in releases) {
        final channel = (r['channel'] as String?) ?? '';
        if (channel != 'stable' && !(allowBeta && channel == 'beta')) {
          continue;
        }
        final version = ((r['version'] as String?) ?? '').trim();
        if (version.isEmpty || compareVersions(version, current) <= 0) {
          continue;
        }
        if (skipped == version && r['mandatory'] != true) continue;
        final url = ((r['apk_url'] as String?) ?? '').trim();
        final parsed = Uri.tryParse(url);
        if (parsed == null || parsed.scheme != 'https' ||
            parsed.host.isEmpty || parsed.userInfo.isNotEmpty) {
          continue;
        }
        if (best == null || compareVersions(version, bestVersion) > 0) {
          best = r;
          bestVersion = version;
        }
      }
      if (best == null) return null;

      final apkUrl = (best['apk_url'] as String).trim();
      final uri = Uri.parse(apkUrl);
      final asset = uri.pathSegments.isEmpty
          ? 'AnimePlex-update.apk'
          : Uri.decodeComponent(uri.pathSegments.last);
      return UpdateInfo(
        version: bestVersion,
        notes: ((best['release_notes'] as String?) ?? '').trim(),
        apkUrl: apkUrl,
        assetName: asset.isEmpty ? 'AnimePlex-update.apk' : asset,
        apkSize: (best['apk_size'] as num?)?.toInt() ?? 0,
        isPrerelease: best['channel'] == 'beta',
        isMandatory: best['mandatory'] == true,
      );
    } catch (_) {
      lastCheckError = 'Unable to check AnimePlex updates. Check your connection.';
      return null;
    }
  }

  /// The installed version string (e.g. "1.2.0"), for display.
  Future<String> currentVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }

  /// Download the APK to the cache dir, reporting 0..1 progress. Throws on
  /// failure so the dialog can surface an error.
  Future<File> downloadApk(
    String url, {
    int expectedSize = 0,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/animeplex-update.apk';
    final file = File(path);
    if (await file.exists()) await file.delete(); // drop any stale partial
    await _dio.download(
      url,
      path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    // Integrity guard: a truncated/corrupt download would otherwise be handed to
    // the installer and rejected as "package appears to be invalid". Fail loudly
    // instead so the user just retries the download.
    if (expectedSize > 0) {
      final actual = await file.length();
      if (actual != expectedSize) {
        await file.delete();
        throw Exception(
          'Download incomplete ($actual/$expectedSize bytes) — please retry.',
        );
      }
    }
    return file;
  }

  /// Hand the APK to the system installer. Requests the "install unknown apps"
  /// permission first. Returns false if the permission was denied or the
  /// installer couldn't be launched.
  Future<bool> installApk(File apk) async {
    if (Platform.isAndroid) {
      final status = await Permission.requestInstallPackages.request();
      if (!status.isGranted) return false;
    }
    final res = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    return res.type == ResultType.done;
  }

  /// Remember a version the user chose to skip (so auto-check won't re-prompt).
  Future<void> skipVersion(String version) async {
    (await _box()).put(_skipKey, version);
  }

  Future<String?> _skippedVersion() async =>
      (await _box()).get(_skipKey) as String?;

  /// Whether the user opted into pre-release (beta) updates. Defaults to false.
  Future<bool> betaOptIn() async =>
      (await _box()).get(_betaKey, defaultValue: false) as bool;

  /// Persist the beta opt-in choice.
  Future<void> setBetaOptIn(bool value) async =>
      (await _box()).put(_betaKey, value);

  Future<Box> _box() async => Hive.isBoxOpen(_boxName)
      ? Hive.box(_boxName)
      : await openBoxSafely(_boxName);

  /// Compare two version strings with semver pre-release ordering.
  /// Returns <0 if [a] < [b], 0 if equal, >0 if [a] > [b].
  /// A leading "v" is ignored. Rules: higher numeric core wins; on an equal
  /// core a final build (no "-label") outranks a pre-release ("-betaN"); two
  /// pre-releases are ordered by the label's trailing integer (beta2 > beta1).
  static int compareVersions(String a, String b) {
    final pa = _parseVersion(a);
    final pb = _parseVersion(b);
    final len = pa.core.length > pb.core.length ? pa.core.length : pb.core.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.core.length ? pa.core[i] : 0;
      final y = i < pb.core.length ? pb.core[i] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    // Cores equal → a final (pre == null) is greater than any pre-release.
    if (pa.pre == null && pb.pre == null) return 0;
    if (pa.pre == null) return 1;
    if (pb.pre == null) return -1;
    if (pa.pre != pb.pre) return pa.pre! < pb.pre! ? -1 : 1;
    return 0;
  }

  /// "v1.9.2-beta3" → (core: [1,9,2], pre: 3). No label → pre == null. A label
  /// without digits ("beta") → pre == 0.
  static ({List<int> core, int? pre}) _parseVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final dash = s.indexOf('-');
    final corePart = dash >= 0 ? s.substring(0, dash) : s;
    final label = dash >= 0 ? s.substring(dash + 1) : null;
    final core =
        corePart.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    int? pre;
    if (label != null) {
      final m = RegExp(r'(\d+)').firstMatch(label);
      pre = m != null ? int.parse(m.group(1)!) : 0;
    }
    return (core: core, pre: pre);
  }
}
