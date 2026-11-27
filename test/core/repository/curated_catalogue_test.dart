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

class _Matcher extends Fake implements SourceMatcher {}

class _Sources extends Fake implements SourceRepository {}

void main() {
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
