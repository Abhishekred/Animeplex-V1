import '../models/video_source.dart';

/// Parses a quality label like `'1080p'` into a comparable int (height in px).
/// Unknown/empty → -1 so it sorts last.
int qualityRank(String? quality) {
  if (quality == null) return -1;
  final m = RegExp(r'(\d{3,4})').firstMatch(quality);
  if (m == null) return -1;
  return int.tryParse(m.group(1)!) ?? -1;
}

/// Returns [sources] sorted by quality high→low; unknown qualities last.
/// Stable for equal ranks (preserves input order).
List<VideoSource> sortByQuality(List<VideoSource> sources) {
  final indexed = sources.asMap().entries.toList();
  indexed.sort((a, b) {
    final r = qualityRank(
      b.value.quality,
    ).compareTo(qualityRank(a.value.quality));
    return r != 0 ? r : a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Distinct [AudioKind]s present in [sources], in first-seen order.
List<AudioKind> availableKinds(List<VideoSource> sources) {
  final seen = <AudioKind>[];
  for (final s in sources) {
    if (!seen.contains(s.kind)) seen.add(s.kind);
  }
  return seen;
}

/// Only the sources matching [kind].
List<VideoSource> sourcesForKind(List<VideoSource> sources, AudioKind kind) =>
    sources.where((s) => s.kind == kind).toList();

/// Approximate vertical resolution (px) named by a quality label. Handles the
/// 4K/2K/FHD shorthand as well as bare numbers. Null when the label names no
/// resolution at all — 'auto', 'highest', or a bare server name like
/// 'Doodstream'.
int? resolutionPx(String? label) {
  if (label == null) return null;
  final l = label.toLowerCase();
  if (l.contains('2160') || l.contains('4k') || l.contains('uhd')) return 2160;
  if (l.contains('1440') || l.contains('2k')) return 1440;
  if (l.contains('1080') || l.contains('fhd')) return 1080;
  if (l.contains('720')) return 720;
  if (l.contains('480')) return 480;
  if (l.contains('360')) return 360;
  if (l.contains('240')) return 240;
  final m = RegExp(r'(\d{3,4})').firstMatch(l);
  return m != null ? int.tryParse(m.group(1)!) : null;
}

/// Rank an episode's *spoken audio* for automatic source selection:
/// Hindi first, then explicitly labelled original audio, then other sources.
/// Prefer structured audioLang when available, otherwise the provider's
/// descriptive stream label (e.g. "MovieBox (Hindi Audio)").
/// Don't confuse a Hindi subtitle-only label with Hindi spoken audio.
int sourceAudioPriority(VideoSource source) {
  final language = source.audioLang?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (RegExp(r'^(?:hi|hin|hindi)(?:-|$)').hasMatch(language)) return 0;
  if (RegExp(r'^(?:original|orig|org)(?:-|$)').hasMatch(language)) return 1;

  final label = (source.label ?? '').toLowerCase();
  final hindi = RegExp(r'\b(?:hindi|hin)\b|हिंदी|हिन्दी');
  final hindiSubOnly = RegExp(
    r'\b(?:hindi|hin)\s+(?:sub|subs|subtitle|subtitles)\b',
  );
  if (hindi.hasMatch(label) && !hindiSubOnly.hasMatch(label)) return 0;
  if (RegExp(r'\b(?:original|orig)\b|\borg\s+audio\b')
      .hasMatch(label)) {
    return 1;
  }
  return 2;
}

/// Best default source: Hindi audio first (when offered), otherwise Original
/// audio, then remaining sources. Within that audio priority choose the highest
/// quality of [prefer], or highest quality overall if that kind is absent.
/// Null only when [sources] is empty.
///
/// [preferQuality] is the user's saved resolution preference. When it names a
/// real resolution the source closest to it wins, so a provider that ships one
/// stream per quality honours the preference by STARTING on the right stream.
/// Switching streams once playback is already running would be a different
/// file — different server, audio and subtitles — which is never what a
/// quality preference means.
VideoSource? pickDefault(
  List<VideoSource> sources, {
  AudioKind prefer = AudioKind.sub,
  String? preferQuality,
}) {
  if (sources.isEmpty) return null;
  final preferred = sortByQuality(sourcesForKind(sources, prefer));
  final candidates = preferred.isNotEmpty ? preferred : sortByQuality(sources);

  // The default language wins before quality: a 1080p Portuguese link must
  // not outrank a Hindi stream. Explicit manual source picks bypass this.
  final priority = candidates
      .map(sourceAudioPriority)
      .reduce((a, b) => a < b ? a : b);
  final pool = candidates
      .where((source) => sourceAudioPriority(source) == priority)
      .toList();

  final want = resolutionPx(preferQuality);
  if (want != null) {
    VideoSource? best;
    var bestDiff = 1 << 30;
    for (final s in pool) {
      final px = resolutionPx(s.quality);
      if (px == null) continue;
      final d = (px - want).abs();
      // Pool is sorted high->low, so a strict < keeps the HIGHER one on a tie.
      if (d < bestDiff) {
        bestDiff = d;
        best = s;
      }
    }
    if (best != null) return best;
  }
  // 'auto'/'highest', or nothing carried a resolution: the existing default.
  return pool.first;
}

/// Gives late CloudStream links a short chance to include the user's preferred
/// quality before [pickDefault] chooses an initial stream. This happens before
/// playback starts, so it never switches servers (and their audio/subtitles)
/// underneath the viewer. If the preference doesn't arrive within [maxWait],
/// the available links are returned and the saved preference remains intact.
Future<List<VideoSource>> waitForPreferredQuality({
  required List<VideoSource> initial,
  required String preferredQuality,
  required AudioKind preferredKind,
  required Future<({List<VideoSource> sources, bool done})> Function() poll,
  bool Function()? isStillCurrent,
  Duration maxWait = const Duration(seconds: 2),
  Duration pollInterval = const Duration(milliseconds: 250),
}) async {
  if (initial.isEmpty ||
      preferredQuality == 'auto' ||
      maxWait <= Duration.zero) {
    return initial;
  }

  final target = resolutionPx(preferredQuality);
  var collected = List<VideoSource>.of(initial);
  final seen = initial.map((source) => source.url).toSet();
  final timer = Stopwatch()..start();

  bool preferredQualityAvailable() {
    if (preferredQuality == 'highest') return false;
    if (target == null) return true;
    final inPreferredKind = preferredKind == AudioKind.unknown
        ? collected
        : sourcesForKind(collected, preferredKind);
    if (preferredKind != AudioKind.unknown && inPreferredKind.isEmpty) {
      return false;
    }
    return inPreferredKind.any(
      (source) => resolutionPx(source.quality) == target,
    );
  }

  while (timer.elapsed < maxWait) {
    if (isStillCurrent != null && !isStillCurrent()) return collected;
    if (preferredQualityAvailable()) return collected;
    final remaining = maxWait - timer.elapsed;
    late final ({List<VideoSource> sources, bool done}) result;
    try {
      result = await poll().timeout(
        remaining,
        onTimeout: () => (sources: const <VideoSource>[], done: true),
      );
    } catch (_) {
      return collected;
    }
    for (final source in result.sources) {
      if (seen.add(source.url)) collected.add(source);
    }
    if (preferredQualityAvailable() || result.done) return collected;

    final pause = maxWait - timer.elapsed;
    if (pause <= Duration.zero) break;
    await Future<void>.delayed(pollInterval < pause ? pollInterval : pause);
  }
  return collected;
}
