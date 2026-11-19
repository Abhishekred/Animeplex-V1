import 'dart:io';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'apk_parts.dart';

export 'apk_parts.dart' show UpdatePart, MultipartUpdate;

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
    this.parts = const <UpdatePart>[],
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

  /// Upload-only: download, verify and join these pieces before installation.
  final List<UpdatePart> parts;

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

  // Separate public update feed: the app's login Supabase can use a DIFFERENT
  // project, VPS auth route or be temporarily uninitialized. Never query
  // release metadata through Supabase.instance.client.
  static const String _feedBaseUrl =
      'https://iwiujqjipotwvigvaaid.supabase.co/rest/v1';
  // Public publishable key: safe to ship in the client; RLS only exposes
  // published release metadata. Do NOT use a service-role key here.
  static const String _feedPublishableKey = 'sb_publishable_A436wPL9-Bfc6mg4dtUkQQ_2WLkfY9t';

  final Dio _dio = Dio();

  Future<List<Map<String, dynamic>>> _publicRows(
    String table, Map<String, String> query,
  ) async {
    final response = await _dio.get<List<dynamic>>(
      '$_feedBaseUrl/$table',
      queryParameters: query,
      options: Options(
        headers: const {
          'apikey': _feedPublishableKey,
          'Accept': 'application/json',
        },
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 12),
      ),
    );
    return (response.data ?? const <dynamic>[])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  /// Only a direct public HTTPS APK file is acceptable for in-app install.
  /// Dynamic store links and byte counts such as "24" (meaning MB) are not.
  static bool validUpdatePackage(String url, int byteSize) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !trimmed.contains(RegExp(r'\s')) &&
        uri.path.toLowerCase().endsWith('.apk') &&
        (byteSize == 0 || byteSize >= 1000000);
  }

  /// Non-null if a check failed, so manual checks don't claim "latest" on
  /// network or authentication errors. Auto checks intentionally stay silent.
  String? lastCheckError;

  /// About → GitHub follows the update admin's repository setting.
  Future<String> repositoryUrl() async {
    try {
      final rows = await _publicRows('animeplex_update_config', {
        'select': 'repository_url',
        'id': 'eq.true',
        'limit': '1',
      });
      final url = rows.isEmpty
          ? ''
          : ((rows.first['repository_url'] as String?) ?? '').trim();
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'https' &&
          uri.host.isNotEmpty && uri.userInfo.isEmpty) {
        return url;
      }
    } catch (_) {}
    return fallbackRepositoryUrl;
  }

  /// A release is eligible only after admin Publish, with global delivery ON.
  /// Beta requires both admin availability and the viewer's beta opt-in.
  Future<UpdateInfo?> checkForUpdate({
    bool respectSkip = false,
    bool automatic = false,
  }) async {
    lastCheckError = null;
    try {
      final configs = await _publicRows('animeplex_update_config', {
        'select': 'enabled,auto_check,beta_enabled',
        'id': 'eq.true',
        'limit': '1',
      });
      if (configs.isEmpty || configs.first['enabled'] != true) return null;
      final settings = configs.first;
      if (automatic && settings['auto_check'] != true) return null;

      final allowBeta =
          settings['beta_enabled'] == true && await betaOptIn();
      final current = (await PackageInfo.fromPlatform()).version;
      final skipped = respectSkip ? await _skippedVersion() : null;

      final releases = await _publicRows('animeplex_update_releases', {
        'select': 'version,channel,release_notes,apk_url,apk_size,mandatory,delivery_method,apk_parts',
        'status': 'eq.published',
        'order': 'published_at.desc',
        'limit': '100',
      });

      Map<String, dynamic>? best;
      String bestVersion = '';
      var invalidEligibleApks = 0;
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
        final apkSize = (r['apk_size'] as num?)?.toInt() ?? 0;
        final method = (r['delivery_method'] as String?) ?? 'link';
        final rawParts = r['apk_parts'];
        final valid = method == 'upload'
            ? rawParts is List<dynamic> &&
                MultipartUpdate.validManifest(rawParts, apkSize)
            : method == 'link' && validUpdatePackage(url, apkSize);
        if (!valid) {
          invalidEligibleApks++;
          continue;
        }
        if (best == null || compareVersions(version, bestVersion) > 0) {
          best = r;
          bestVersion = version;
        }
      }
      if (best == null) {
        if (invalidEligibleApks > 0) {
          lastCheckError =
              'Admin published an incomplete APK upload or an invalid '
              'APK link/size. Please correct it in the Admin Panel.';
        }
        return null;
      }

      final uploaded = best['delivery_method'] == 'upload';
      final apkUrl = uploaded ? '' : (best['apk_url'] as String).trim();
      final asset = uploaded
          ? 'AnimePlex-' + bestVersion + '.apk'
          : Uri.decodeComponent(Uri.parse(apkUrl).pathSegments.last);
      final parts = uploaded
          ? MultipartUpdate.parse(best['apk_parts'] as List<dynamic>)
          : const <UpdatePart>[];
      return UpdateInfo(
        version: bestVersion,
        notes: ((best['release_notes'] as String?) ?? '').trim(),
        apkUrl: apkUrl,
        assetName: asset.isEmpty ? 'AnimePlex-update.apk' : asset,
        apkSize: (best['apk_size'] as num?)?.toInt() ?? 0,
        parts: parts,
        isPrerelease: best['channel'] == 'beta',
        isMandatory: best['mandatory'] == true,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      lastCheckError = status != null
          ? 'AnimePlex update server returned HTTP $status.'
          : 'Unable to reach AnimePlex update server. Check your connection.';
      return null;
    } catch (_) {
      lastCheckError = 'Unable to check AnimePlex updates. Please retry.';
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
    List<UpdatePart> parts = const <UpdatePart>[],
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/animeplex-update.apk';
    final file = File(path);
    if (await file.exists()) await file.delete(); // drop any stale partial
    if (parts.isNotEmpty) {
      try {
        await MultipartUpdate.download(
          dio: _dio,
          parts: parts,
          destination: file,
          expectedSize: expectedSize,
          onProgress: onProgress,
        );
      } catch (_) {
        if (await file.exists()) await file.delete();
        rethrow;
      }
    } else {
      if (!validUpdatePackage(url, expectedSize)) {
        throw const FormatException('Invalid direct APK download URL.');
      }
      await _dio.download(
        url,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
    }
    // Block HTML redirects, truncated downloads and fake "APK" payloads.
    // A valid APK is a ZIP package and must be meaningfully larger than 1 MB.
    final actual = await file.length();
    if (actual < 1000000 || (expectedSize > 0 && actual != expectedSize)) {
      await file.delete();
      throw Exception('Downloaded APK size is invalid ($actual bytes).');
    }
    final header = await file.openRead(0, 4).first;
    if (header.length < 4 ||
        header[0] != 0x50 || header[1] != 0x4b ||
        header[2] != 0x03 || header[3] != 0x04) {
      await file.delete();
      throw Exception('Download is not an APK file.');
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
