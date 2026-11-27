import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/repository/curated_catalogue.dart';
import 'package:watch_app/features/catalogue/catalogue_screen.dart';

class _Feed implements CuratedCatalogue {
  final calls =
      <({String? kind, String? platform, String search, int offset})>[];
  final data = [
    for (var i = 0; i < 32; i++)
      CuratedTitle({
        'kind': i == 0 ? 'series' : 'movie',
        'tmdb_id': i + 1,
        'title': i == 0 ? 'Farzi' : 'Film $i',
        'poster_url': 'https://example.test/$i',
        'provider_ids': ['cs:AniVortex'],
        'language_badge': 'Hindi',
        'rating': 8.3,
      }),
  ];
  @override
  Future<List<String>> platforms() async => ['Prime Video'];
  @override
  Future<List<CuratedTitle>> rail({
    String? kind,
    String? platform,
    String search = '',
    bool trending = false,
  }) async => trending ? [data[1]] : [data.first];
  @override
  Future<List<CuratedTitle>> page({
    String? kind,
    String? platform,
    String search = '',
    bool trending = false,
    int offset = 0,
    int limit = 12,
  }) async {
    calls.add((kind: kind, platform: platform, search: search, offset: offset));
    return data
        .where(
          (t) =>
              (kind == null || !t.series) &&
              t.name.toLowerCase().contains(search.toLowerCase()),
        )
        .skip(offset)
        .take(limit)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Home exposes the switcher and profile rows on the full catalogue',
      (tester) async {
    sl.registerSingleton<CuratedCatalogue>(_Feed());
    addTearDown(() => sl.unregister<CuratedCatalogue>());
    var switched = false;
    await tester.pumpWidget(MaterialApp(home: CatalogueScreen(
      onSwitchCatalogue: () => switched = true,
      profileSlivers: const [
        SliverToBoxAdapter(child: Text('Continue Watching')),
        SliverToBoxAdapter(child: Text('My List')),
      ],
    )));
    await tester.pump();
    await tester.pump();
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('My List'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch catalogue'));
    expect(switched, isTrue);
    await tester.tap(find.text('Prime Video'));
    await tester.pump();
    expect(find.text('My List'), findsNothing);
    await tester.tap(find.text('ALL'));
    await tester.pump();
    expect(find.text('My List'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reference catalogue filters, searches and pages its three-column grid',
    (tester) async {
      final feed = _Feed();
      sl.registerSingleton<CuratedCatalogue>(feed);
      addTearDown(() => sl.unregister<CuratedCatalogue>());
      await tester.pumpWidget(const MaterialApp(home: CatalogueScreen()));
      await tester.pump();
      await tester.pump();
      expect(find.text('Anime Plex'), findsOneWidget);
      expect(find.text('Trending'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      await tester.tap(find.text('Prime Video'));
      await tester.pump();
      await tester.pump();
      expect(feed.calls.last.platform, 'Prime Video');
      await tester.tap(find.byTooltip('Search catalogue'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Farzi');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(feed.calls.last.search, 'Farzi');
      expect(find.widgetWithText(ListTile, 'Farzi'), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pump();
      final view = tester.state<ScrollableState>(
        find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      view.position.jumpTo(view.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(
        feed.calls.any((c) => c.offset == 12 && c.platform == 'Prime Video'),
        isTrue,
      );
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
