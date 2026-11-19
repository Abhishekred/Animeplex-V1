import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_selection.dart';

VideoSource stream(
  String label, {
  String quality = '1080p',
  String? audioLang,
  AudioKind kind = AudioKind.unknown,
}) => VideoSource(
  url: 'https://example.com/${Uri.encodeComponent(label)}/$quality',
  label: label,
  quality: quality,
  audioLang: audioLang,
  kind: kind,
);

void main() {
  group('default spoken-audio source', () {
    test('Hindi wins over Portuguese and Original even when listed later', () {
      final ptbr = stream('MovieBox MP4 (H264) (ptbr Audio)');
      final hindi = stream('MovieBox MP4 (HEVC) (Hindi Audio)');
      final original = stream('MovieBox MP4 (HEVC) (Original Audio)');
      expect(pickDefault([ptbr, original, hindi]), hindi);
    });

    test('falls back to Original when Hindi audio is unavailable', () {
      final ptbr = stream('MovieBox MP4 (ptbr Audio)', quality: '2160p');
      final original = stream('MovieBox MP4 (Original Audio)', quality: '720p');
      expect(pickDefault([ptbr, original]), original);
    });

    test('highest resolution within Hindi wins; manual quality preference still applies', () {
      final hindi480 = stream('Hindi Audio 480p', quality: '480p');
      final hindi720 = stream('Hindi Audio 720p', quality: '720p');
      final hindi1080 = stream('Hindi Audio 1080p', quality: '1080p');
      final ptbr2160 = stream('ptbr Audio 2160p', quality: '2160p');
      final sources = [ptbr2160, hindi480, hindi1080, hindi720];
      expect(pickDefault(sources), hindi1080);
      expect(pickDefault(sources, preferQuality: '720p'), hindi720);
      expect(pickDefault(sources, preferQuality: '2160p'), hindi1080);
    });

    test('uses structured language codes when audio label does not state Hindi', () {
      final original = stream('Video 1080p', audioLang: 'original');
      final hindi = stream('Server A', audioLang: 'hi-IN', quality: '720p');
      expect(pickDefault([original, hindi]), hindi);
    });

    test('does not mistake Hindi subtitles for Hindi spoken audio', () {
      final subbed = stream('English Audio / Hindi Subtitles');
      final original = stream('Original Audio');
      expect(pickDefault([subbed, original]), original);
    });

    test('selects original when explicitly labelled org audio', () {
      final portuguese = stream('ptbr Audio', quality: '1080p');
      final original = stream('org Audio', quality: '720p');
      expect(pickDefault([portuguese, original]), original);
    });

    test('preserves Sub/Dub category selection when both categories exist', () {
      final subOriginal = stream('Original Audio', kind: AudioKind.sub);
      final dubHindi = stream('Hindi Audio', kind: AudioKind.dub);
      expect(pickDefault([dubHindi, subOriginal], prefer: AudioKind.sub), subOriginal);
      expect(pickDefault([subOriginal, dubHindi], prefer: AudioKind.dub), dubHindi);
    });

    test('preserves best-quality fallback when no language is labelled', () {
      final low = stream('Server A', quality: '480p');
      final high = stream('Server B', quality: '1080p');
      expect(pickDefault([low, high]), high);
      expect(pickDefault(<VideoSource>[]), isNull);
    });
  });
}
