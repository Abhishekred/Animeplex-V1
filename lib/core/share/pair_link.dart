import '../environment.dart';

/// Pairing codes remain in app deep links. Never send codes or nonces to a
/// legacy website: the phone talks only to the new Supabase pair-tv function.
class PairLink {
  const PairLink({
    this.code,
    this.nonce,
    this.trackers = false,
    this.authority = 'cloud',
  });
  final String authority;
  final String? code;
  final String? nonce;
  final bool trackers;

  /// Secure direct app QR (no third-party web hop).
  static String qrData({
    required String code,
    String? nonce,
    bool trackers = false,
    String? authority,
  }) => deepLink(
    code: code,
    nonce: nonce,
    trackers: trackers,
    authority: authority,
  );

  static String deepLink({
    required String code,
    String? nonce,
    bool trackers = false,
    String? authority,
  }) {
    if (authority != null && authority != 'cloud') {
      throw ArgumentError.value(authority, 'authority', 'Cloud only');
    }
    return Uri(
      scheme: Environment.trackerRedirectScheme,
      host: Environment.pairLinkHost,
      queryParameters: {
        'code': code,
        if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
        if (trackers) 'trackers': '1',
      },
    ).toString();
  }

  static PairLink? parse(Uri uri) {
    if (uri.scheme != Environment.trackerRedirectScheme ||
        uri.host != Environment.pairLinkHost ||
        (uri.queryParametersAll['auth']?.length ?? 0) > 0) {
      return null;
    }
    final q = uri.queryParameters;
    return PairLink(
      code: q['code'],
      nonce: q['nonce'],
      trackers: q['trackers'] == '1',
    );
  }
}
