import 'dart:io';

import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/features/home/home_catalogue_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/repository/curated_catalogue.dart';

import '../playback/my_list_supabase_test.dart' show FakeMyListRemote;
import '../playback/watch_history_supabase_test.dart' show FakeHistoryRemote;

class _Matcher extends Fake implements SourceMatcher {}

class _Sources extends Fake implements SourceRepository {}

void main() {
  test('curated Home persists and resumes only the active profile', () async {
    final dir = await Directory.systemTemp.createTemp('curated-home');
    Hive.init(dir.path);
    addTearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await Hive.openBox(HomeCataloguePrefs.boxName);
    await HomeCataloguePrefs.setSourceIdFor(ContentMode.anime, 'cs:previous');
    await HomeCataloguePrefs.setCatalogue(ContentMode.anime, HomeCatalogueKind.curated);
    await Hive.box(HomeCataloguePrefs.boxName).close();
    await Hive.openBox(HomeCataloguePrefs.boxName);
    expect(HomeCataloguePrefs.curatedSelected, isTrue);
    expect(HomeCataloguePrefs.catalogueShown, isFalse);
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'cs:previous');

    await MyListStore.init();
    await WatchHistory.init();
    var profile = 'family';
    final service = SupabaseService();
    final lists = FakeMyListRemote();
    final progress = FakeHistoryRemote();
    final list = MyListStore(service, () => 'user', remote: lists, currentProfileId: () => profile);
    final history = WatchHistory(service, () => 'user', remote: progress, currentProfileId: () => profile);
    final title = CuratedTitle({
      'kind': 'series', 'tmdb_id': 42, 'title': 'Series', 'poster_url': '',
      'provider_ids': ['first', 'fallback'],
    }).item;
    await list.add(title);
    Future<void> watch(String source, String show, int timestamp) => history.save(
      HistoryEntry(
        sourceId: source, showId: show, showUrl: show, showTitle: 'Title',
        category: 'sub', episodeId: '$show/1/2', episodeNumber: 2,
        episodeUrl: '$show/1/2', position: const Duration(minutes: 3),
        duration: const Duration(minutes: 24), updatedAt: timestamp,
      ),
      flush: true,
    );
    await watch(title.sourceId, title.url, 1);
    await watch('other', 'other-show', 2);
    expect(history.recent(limit: 1).single.sourceId, 'other');
    profile = 'second';
    expect(list.all(), isEmpty);
    expect(history.recent(sourceId: CuratedCatalogue.id), isEmpty);
    expect(lists.rows.single['profile_id'], 'family');
    expect(progress.rows.first['profile_id'], 'family');
    profile = 'family';
    expect(list.all().single.url, title.url);
    final saved = history.recent(sourceId: CuratedCatalogue.id, limit: 1).single;
    expect(saved.episodeId, 'apcatalog://series/42/1/2');
    expect(saved.position, const Duration(minutes: 3));
  });

  test(
    'movie pages and series rails request admin display order before paging',
    () async {
      final requests = <Uri>[];
      final client = SupabaseClient(
        'https://example.test',
        'fixture',
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final catalogue = CuratedCatalogue(
        TmdbCatalogue((_, _) async => null),
        _Matcher(),
        _Sources(),
        client: client,
      );
      await catalogue.page(kind: 'movie', offset: 12, limit: 12);
      await catalogue.rail(kind: 'series');

      expect(requests, hasLength(2));
      for (final uri in requests) {
        final order = uri.queryParameters['order']!.split(',');
        expect(order.map((term) => term.split('.').take(2).join('.')), [
          'sort_order.asc',
          'kind.asc',
          'tmdb_id.asc',
        ]);
      }
      expect(requests.first.queryParameters['offset'], '12');
      expect(requests.first.queryParameters['kind'], 'eq.movie');
      expect(requests.last.queryParameters['kind'], 'eq.series');
    },
  );
  test(
    'skips missing or failing providers and stops on first playable link',
    () async {
      final attempted = <String>[];
      final links = await firstPlayableProvider(['a', 'b', 'c', 'd'], (
        id,
      ) async {
        attempted.add(id);
        if (id == 'a') throw StateError('Provider missing');
        if (id == 'b') return [];
        return [const VideoSource(url: 'https://example.test/video')];
      });
      expect(attempted, ['a', 'b', 'c']);
      expect(links.single.url, endsWith('/video'));
    },
  );
  test(
    'matches the exact season and episode even if a source skips episodes',
    () {
      const episodes = [
        Episode(id: '1', title: 'Pilot', number: 1, season: 1, url: 'first'),
        Episode(id: '3', title: 'Return', number: 3, season: 2, url: 'third'),
      ];
      expect(catalogueEpisode(episodes, true, 2, 1), isNull);
      expect(catalogueEpisode(episodes, true, 2, 3)?.url, 'third');
    },
  );
}
