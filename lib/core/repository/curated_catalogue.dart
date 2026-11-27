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
      providers = List<String>.from(row['provider_ids'] as List);

  final bool series;
  final int tmdbId;
  final String name, poster;
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
  CuratedCatalogue(this.tmdb, this.matcher, this.sources);
  final TmdbCatalogue tmdb;
  final SourceMatcher matcher;
  final SourceRepository sources;
  static const id = 'animeplex-catalogue';
  static bool owns(String url) => url.startsWith('apcatalog://');
  static const _table = 'animeplex_curated_titles';
  SupabaseClient get _db => Supabase.instance.client;

  Future<List<CuratedTitle>> titles() async {
    final titles = <CuratedTitle>[];
    for (var start = 0; ; start += 500) {
      final rows = await _db
          .from(_table)
          .select()
          .order('kind')
          .order('sort_order')
          .order('tmdb_id')
          .range(start, start + 499);
      titles.addAll(rows.map(CuratedTitle.new));
      if (rows.length < 500) return titles;
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
    final title = await _published(uri);
    final season = int.parse(uri.pathSegments[1]);
    final number = int.parse(uri.pathSegments[2]);
    return firstPlayableProvider(title.providers, (provider) async {
      if (!UserRuntimeControls.maySelect(provider)) return [];
      final match = await matcher.matchOn(
        title.canonical,
        provider,
        title: title.name,
      );
      if (match == null) return [];
      final eps = await sources.episodes(match.showUrl, sourceId: provider);
      final ep = catalogueEpisode(eps, title.series, season, number);
      if (ep == null || !UserRuntimeControls.maySelect(provider)) return [];
      final links = await sources.sources(
        ep.url,
        sourceId: provider,
        fast: fast,
      );
      return UserRuntimeControls.maySelect(provider) ? links : [];
    });
  }
}

Future<List<VideoSource>> firstPlayableProvider(
  List<String> ids,
  Future<List<VideoSource>> Function(String) resolve,
) async {
  for (final id in ids) {
    try {
      final links = await resolve(id).timeout(const Duration(seconds: 25));
      final playable = links.where((s) => s.url.trim().isNotEmpty).toList();
      if (playable.isNotEmpty) return playable;
    } on Exception {
      continue;
    } on StateError {
      continue;
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
