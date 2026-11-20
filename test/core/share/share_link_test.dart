import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/share/share_link.dart';

void main() {
  group('ShareLink.watchUrl', () {
    test('builds the https open link for the Discord button', () {
      final url = ShareLink.watchUrl(
        sourceId: 'cs:hiAnime',
        url: 'https://hianime.to/watch/one-piece-100',
        title: 'One Piece',
        type: ProviderType.anime,
      );
      expect(url, startsWith('https://abhishek.dpdns.org/open/'));
      expect(url, contains('s=cs%3AhiAnime'));
      expect(url, contains('One+Piece'));
    });

    test('null when the title identity is incomplete', () {
      expect(
        ShareLink.watchUrl(
          sourceId: '',
          url: 'https://hianime.to/watch/x',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: null,
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: '',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
    });
  });

  group('AnimePlex share deep links', () {
    test('new AnimePlex scheme opens a title', () {
      final item = ShareLink.parse(Uri.parse(
        'animeplex://open?s=zm&u=zm%3A%2F%2Fanime%2Fmal%3A1735&t=Naruto&y=a',
      ));
      expect(item, isNotNull);
      expect(item!.sourceId, 'zm');
      expect(item.url, 'zm://anime/mal:1735');
      expect(item.title, 'Naruto');
    });

    test('legacy Zangetsu share links are rejected', () {
      expect(ShareLink.parse(Uri.parse(
        'zangetsu://open?s=zm&u=zm%3A%2F%2Fanime%2Fmal%3A1',
      )), isNull);
    });

    test('bottom Share button text contains only our HTTPS domain', () {
      final item = ShareLink.parse(Uri.parse(
        'animeplex://open?s=zm&u=zm%3A%2F%2Fanime%2Fmal%3A1735&t=Naruto',
      ))!;
      final text = ShareLink.shareText(item);
      expect(text, contains('Watch on AnimePlex:'));
      expect(text, contains('https://abhishek.dpdns.org/open/'));
      expect(text, isNot(contains('zangetsu.online')));
      expect(text, isNot(contains('zangetsu://')));
    });

    test('unrelated hosts and https are not app schemes', () {
      expect(ShareLink.parse(Uri.parse('animeplex://pair?s=zm&u=x')), isNull);
      expect(ShareLink.parse(Uri.parse(
        'https://abhishek.dpdns.org/open/?s=zm&u=x',
      )), isNull);
    });
  });
}
