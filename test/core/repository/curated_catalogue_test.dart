import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/repository/curated_catalogue.dart';

void main() {
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
