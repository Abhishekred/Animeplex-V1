import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/share/pair_link.dart';

void main() {
  const code = 'ABCD2345';
  const nonce = 'n_s3creTN0nceValue_________pad';

  test('QR data always uses the app deeplink with no old website hop', () {
    final uri = Uri.parse(PairLink.qrData(code: code, nonce: nonce));
    expect(uri.scheme, 'zangetsu');
    expect(uri.host, 'pair');
    expect(uri.queryParameters['code'], code);
    expect(uri.queryParameters['nonce'], nonce);
    expect(uri.queryParameters.containsKey('auth'), isFalse);
  });

  test('trackers-only deeplink round-trips without exposing a web URL', () {
    final uri = Uri.parse(
      PairLink.deepLink(code: code, nonce: nonce, trackers: true),
    );
    final parsed = PairLink.parse(uri);
    expect(parsed, isNotNull);
    expect(parsed!.trackers, isTrue);
    expect(parsed.code, code);
    expect(parsed.nonce, nonce);
    expect(parsed.authority, 'cloud');
  });

  test('no legacy VPS authority can be generated or accepted', () {
    expect(
      () => PairLink.deepLink(code: code, authority: 'vps'),
      throwsArgumentError,
    );
    expect(
      () => PairLink.qrData(code: code, authority: 'vps'),
      throwsArgumentError,
    );
    expect(
      PairLink.parse(Uri.parse('zangetsu://pair?code=$code&auth=vps')),
      isNull,
    );
    expect(
      PairLink.parse(Uri.parse('zangetsu://pair?code=$code&auth=cloud')),
      isNull,
    );
  });

  test('rejects web links even if they look like pairing links', () {
    expect(
      PairLink.parse(Uri.parse('https://zangetsu.online/pair/?code=$code')),
      isNull,
    );
    expect(
      PairLink.parse(Uri.parse('https://example.com/pair/?code=$code')),
      isNull,
    );
  });

  test('omits missing nonce and retains tracker intent', () {
    final uri = Uri.parse(PairLink.qrData(code: code, trackers: true));
    expect(uri.queryParameters['code'], code);
    expect(uri.queryParameters.containsKey('nonce'), isFalse);
    expect(uri.queryParameters['trackers'], '1');
  });
}
