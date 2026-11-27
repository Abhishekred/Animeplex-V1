import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/user_runtime_controls.dart';
import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import '../zmode/source_matcher.dart';
import '../zmode/tmdb_catalogue.dart';
import '../zmode/zmode_ids.dart';
import 'source_repository.dart';

class CuratedTitle {
  CuratedTitle(Map<String, dynamic> row)
    : series = row['kind'] == 'series',
      tmdbId = row['tmdb_id'] as int,
      name = row['title'] as String,
      poster = row['poster_url'] as String,
      language = row['language_badge'] as String? ?? '',
      backdrop = row['backdrop_url'] as String? ?? '',
      rating = (row['rating'] as num?)?.toDouble(),
      providers = List<String>.from(row['provider_ids'] as List);

  final bool series;
  final int tmdbId;
  final String name, poster, language, backdrop;
  final double? rating;
  final List<String> providers;

  String get url => 'apcatalog://${series ? 'series' : 'movie'}/$tmdbId';
  ZCanonical get canonical =>
      ZCanonical(series ? ZKind.tv : ZKind.movie, 'tmdb:$tmdbId');
  MediaItem get item => MediaItem(
    id: url,
    title: name,
    cover: poster,
    url: url,
    sourceId: CuratedCatalogue.id,
    type: ProviderType.movie,
    tmdbId: tmdbId,
    tmdbIsTv: series,
  );
}

class CuratedCatalogue {
  CuratedCatalogue(
    this.tmdb,
    this.matcher,
    this.sources, {
    SupabaseClient? client,
  }) : _client = client;
  final SupabaseClient? _client;
  final TmdbCatalogue tmdb;
  final SourceMatcher matcher;
  final SourceRepository sources;
  // Detail and playback use different IDs: keep the winning provider's opaque
  // episode data so the player can collect mirrors that arrive after fast play.
  final _linkTargets = <String, ({String provider, String episode})>{};
  ({String url, String name, String? nativeTitle})? _lastTitle;
  static const id = 'animeplex-catalogue';
  static bool owns(String url) => url.startsWith('apcatalog://');
  static const _table = 'animeplex_curated_titles';
  SupabaseClient get _db => _client ?? Supabase.instance.client;

  Future<List<String>> platforms() async {
    final rows = await _db.rpc('animeplex_catalogue_platforms');
    return [for (final row in rows as List) row['platform'] as String];
  }

  Future<List<CuratedTitle>> page({
    String? kind,
    String? platform,
    String search = '',
    bool trending = false,
    int offset = 0,
    int limit = 12,
  }) async {
    var filter = _db.from(_table).select();
    if (kind != null) filter = filter.eq('kind', kind);
    if (platform != null) filter = filter.eq('platform', platform);
    if (trending) filter = filter.eq('trending', true);
    if (search.isNotEmpty) {
      final literal = search
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      filter = filter.ilike('title', '%$literal%');
    }
    final rows = await filter
        .order('sort_order', ascending: true)
        .order('kind', ascending: true)
        .order('tmdb_id', ascending: true)
        .range(offset, offset + limit - 1);
    return rows.map(CuratedTitle.new).toList();
  }

  Future<List<CuratedTitle>> rail({
    String? kind,
    String? platform,
    String search = '',
    bool trending = false,
  }) async {
    final items = <CuratedTitle>[];
    for (var start = 0; ; start += 200) {
      final batch = await page(
        kind: kind,
        platform: platform,
        search: search,
        trending: trending,
        offset: start,
        limit: 200,
      );
      items.addAll(batch);
      if (batch.length < 200) return items;
    }
  }

  Future<CuratedTitle> _published(Uri uri) async {
    if (!{'series', 'movie'}.contains(uri.host) || uri.pathSegments.isEmpty) {
      throw const FormatException('Invalid catalogue title');
    }
    final row = await _db
        .from(_table)
        .select()
        .eq('kind', uri.host)
        .eq('tmdb_id', int.parse(uri.pathSegments.first))
        .maybeSingle();
    if (row == null)
      throw StateError('This title is no longer in the catalogue.');
    return CuratedTitle(row);
  }

  Future<MediaDetail> detail(String url) async {
    final title = await _published(Uri.parse(url));
    final data = await tmdb.detail(title.canonical);
    _lastTitle = (url: title.url, name: data.title, nativeTitle: data.nativeTitle);
    final perSeason = <int, int>{};
    final episodes = <Episode>[];
    for (final ep in data.episodes) {
      final season = ep.season ?? 1;
      final number = perSeason.update(season, (n) => n + 1, ifAbsent: () => 1);
      final path = '${title.url}/$season/$number';
      episodes.add(
        Episode(
          id: path,
          title: ep.title,
          number: ep.number,
          url: path,
          season: ep.season,
          thumbnail: ep.thumbnail,
        ),
      );
    }
    return data.copyWith(
      id: title.url,
      url: title.url,
      sourceId: id,
      title: title.name,
      cover: title.poster,
      episodes: episodes,
    );
  }

  Future<List<VideoSource>> streams(String url, {bool fast = false}) async {
    final uri = Uri.parse(url);
    if (uri.pathSegments.length != 3) return [];
    final title = await _published(uri).timeout(const Duration(seconds: 15));
    final season = int.parse(uri.pathSegments[1]);
    final number = int.parse(uri.pathSegments[2]);
    final meta = _lastTitle;
    final name = meta != null && meta.url == title.url && meta.name.trim().isNotEmpty
        ? meta.name : title.name;
    final nativeTitle = meta != null && meta.url == title.url ? meta.nativeTitle : null;

    _linkTargets.remove(url);
    return firstPlayableProvider(title.providers, (provider) async {
      if (!UserRuntimeControls.maySelect(provider)) return [];
      // Bound each operation separately. A successful search and episode lookup
      // must not consume the time needed by the provider to extract video links.
      var searching = true;
      final match = await matcher.matchOn(
        title.canonical,
        provider,
        title: name,
        altTitle: title.name,
        metadataAliases: [if (nativeTitle != null) nativeTitle],
        abandoned: () => !searching || !UserRuntimeControls.maySelect(provider),
      ).timeout(const Duration(seconds: 30)).whenComplete(() => searching = false);
      if (match == null || !UserRuntimeControls.maySelect(provider)) return [];
      final eps = await sources.episodes(match.showUrl, sourceId: provider)
          .timeout(const Duration(seconds: 60));
      final ep = catalogueEpisode(eps, title.series, season, number);
      if (ep == null || !UserRuntimeControls.maySelect(provider)) return [];
      final links = await sources.sources(ep.url, sourceId: provider, fast: fast)
          .timeout(Duration(seconds: fast ? 25 : 65));
      if (!UserRuntimeControls.maySelect(provider)) return [];
      if (links.any((link) => link.url.trim().isNotEmpty)) {
        _linkTargets[url] = (provider: provider, episode: ep.url);
        if (_linkTargets.length > 32) _linkTargets.remove(_linkTargets.keys.first);
      }
      return links;
    });
  }

  Future<({List<VideoSource> sources, bool done})> polledSources(String url) async {
    final target = _linkTargets[url];
    if (target == null || !UserRuntimeControls.maySelect(target.provider)) {
      return (sources: <VideoSource>[], done: true);
    }
    final result = await sources.polledSources(target.episode, sourceId: target.provider);
    if (target != _linkTargets[url] || !UserRuntimeControls.maySelect(target.provider)) {
      return (sources: <VideoSource>[], done: true);
    }
    return result;
  }
}

Future<List<VideoSource>> firstPlayableProvider(
  List<String> ids,
  Future<List<VideoSource>> Function(String) resolve,
) async {
  for (final id in ids) {
    try {
      final links = await resolve(id);
      final playable = links.where((s) => s.url.trim().isNotEmpty).toList();
      if (playable.isNotEmpty) return playable;
      debugPrint('[curated-playback] $id returned no links; trying next provider');
    } catch (error) {
      // A plugin may return malformed native data (TypeError) as well as a
      // network error. Either failure belongs to this attempt only.
      debugPrint('[curated-playback] $id failed (${error.runtimeType}); trying next provider');
    }
  }
  return [];
}

Episode? catalogueEpisode(
  List<Episode> episodes,
  bool series,
  int season,
  int number,
) {
  if (!series)
    return episodes.where((e) => e.available && e.url.isNotEmpty).firstOrNull;
  for (final ep in episodes) {
    if (!ep.available || ep.url.isEmpty) continue;
    final label = RegExp(
      r'^S(\d+)\s*[· .-]?\s*E(\d+)\b',
      caseSensitive: false,
    ).firstMatch(ep.title.trim());
    final s = ep.season ?? (label == null ? 1 : int.parse(label[1]!));
    final n = label == null ? ep.number : int.parse(label[2]!);
    if (s == season && n == number) return ep;
  }
  return null;
}
