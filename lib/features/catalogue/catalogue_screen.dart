import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/repository/curated_catalogue.dart';
import '../detail/detail_screen.dart';
import 'catalogue_art.dart';

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  final repo = sl<CuratedCatalogue>();
  final scroll = ScrollController();
  final search = TextEditingController();
  final focus = FocusNode();
  Timer? debounce;
  List<CuratedTitle> series = [], trending = [], movies = [], matches = [];
  List<String> platforms = [];
  String? platform;
  String query = '';
  bool loading = true,
      failed = false,
      more = false,
      paging = false,
      pageError = false;
  bool searching = false, finding = false, searchError = false;
  int generation = 0, searchGeneration = 0, offset = 0;
  static const pageSize = 12;

  @override
  void initState() {
    super.initState();
    scroll.addListener(nearEnd);
    reload();
  }

  @override
  void dispose() {
    debounce?.cancel();
    focus.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final version = ++generation;
    setState(() {
      loading = true;
      failed = false;
      more = false;
      paging = false;
      pageError = false;
    });
    try {
      final (labels, shows, banners, films) = await (
        repo.platforms(),
        repo.rail(kind: 'series', platform: platform, search: query),
        repo.rail(trending: true, platform: platform, search: query),
        repo.page(
          kind: 'movie',
          platform: platform,
          search: query,
          limit: pageSize + 1,
        ),
      ).wait;
      if (!mounted || generation != version) return;
      if (platform != null && !labels.contains(platform)) {
        platform = null;
        await reload();
        return;
      }
      setState(() {
        platforms = labels;
        series = shows;
        trending = banners;
        movies = films.take(pageSize).toList();
        offset = movies.length;
        more = films.length > pageSize;
        loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) nearEnd();
      });
    } catch (_) {
      if (mounted && version == generation)
        setState(() {
          failed = true;
          loading = false;
        });
    }
  }

  void nearEnd() {
    if (scroll.hasClients && scroll.position.extentAfter < 200 && !pageError)
      nextPage();
  }

  Future<void> nextPage() async {
    if (loading || paging || !more) return;
    final version = generation;
    setState(() {
      paging = true;
      pageError = false;
    });
    try {
      final batch = await repo.page(
        kind: 'movie',
        platform: platform,
        search: query,
        offset: offset,
        limit: pageSize + 1,
      );
      if (!mounted || version != generation) return;
      final items = batch.take(pageSize).toList();
      final ids = movies.map((t) => t.tmdbId).toSet();
      setState(() {
        offset += items.length;
        movies.addAll(items.where((t) => ids.add(t.tmdbId)));
        more = batch.length > pageSize;
        paging = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) nearEnd();
      });
    } catch (_) {
      if (mounted && version == generation)
        setState(() {
          pageError = true;
          paging = false;
        });
    }
  }

  void find(String value) {
    final version = ++searchGeneration;
    final term = value.trim();
    debounce?.cancel();
    setState(() {
      matches = [];
      finding = term.isNotEmpty;
      searchError = false;
    });
    if (term.isEmpty) return;
    debounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final result = await repo.page(
          search: term,
          platform: platform,
          limit: 30,
        );
        if (mounted && version == searchGeneration)
          setState(() {
            matches = result;
            finding = false;
          });
      } catch (_) {
        if (mounted && version == searchGeneration)
          setState(() {
            searchError = true;
            finding = false;
          });
      }
    });
  }

  void hideSearch() {
    debounce?.cancel();
    searchGeneration++;
    focus.unfocus();
    setState(() {
      searching = false;
      matches = [];
      finding = false;
      searchError = false;
    });
  }

  void apply({String? label, required String term}) {
    hideSearch();
    platform = label;
    query = term;
    if (scroll.hasClients) scroll.jumpTo(0);
    reload();
  }

  void open(CuratedTitle title) {
    if (searching) hideSearch();
    Navigator.of(context).push(DetailScreen.route(title.item));
  }

  Widget heading(String name) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 5),
      child: name == 'Trending'
          ? const CatalogueFireHeading()
          : Text(
              name,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 24,
                letterSpacing: .5,
              ),
            ),
    ),
  );

  Widget rail(List<CuratedTitle> items, {required bool hero}) =>
      SliverToBoxAdapter(
        child: CatalogueRail(
          key: ValueKey((platform, query, hero)),
          items: items,
          hero: hero,
          onTap: open,
        ),
      );

  Widget status(String text, [VoidCallback? retry]) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Center(
        child: retry == null
            ? Text(text, style: const TextStyle(color: Colors.white70))
            : TextButton(onPressed: retry, child: Text(text)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final resultsVisible = searching && search.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xffe50914),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        titleSpacing: 12,
        toolbarHeight: 49,
        title: const Text(
          'Anime Plex',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: searching ? 'Close search' : 'Search catalogue',
            icon: Icon(searching ? Icons.close : Icons.search),
            onPressed: () {
              if (searching) {
                hideSearch();
                return;
              }
              search.text = query;
              setState(() => searching = true);
              if (query.isNotEmpty) find(query);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && searching) focus.requestFocus();
              });
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (searching)
              ColoredBox(
                color: const Color(0xff111111),
                child: TextField(
                  controller: search,
                  focusNode: focus,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(color: Colors.white),
                  onChanged: find,
                  onSubmitted: (value) =>
                      apply(label: platform, term: value.trim()),
                  decoration: const InputDecoration(
                    hintText: 'Search...',
                    hintStyle: TextStyle(color: Colors.white60),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  RefreshIndicator(
                    onRefresh: reload,
                    child: CustomScrollView(
                      controller: scroll,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (platforms.isNotEmpty)
                          SliverToBoxAdapter(
                            child: SizedBox(
                              height: 50,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                children: [
                                  for (final p in <String?>[...platforms, null])
                                    Padding(
                                      padding: const EdgeInsets.only(right: 10),
                                      child: ChoiceChip(
                                        selected: p == platform,
                                        showCheckmark: false,
                                        label: Text(p ?? 'ALL'),
                                        shape: const StadiumBorder(),
                                        side: BorderSide.none,
                                        backgroundColor: const Color(
                                          0xffe5e5e5,
                                        ),
                                        selectedColor: const Color(0xffe50914),
                                        labelStyle: TextStyle(
                                          color: p == platform
                                              ? Colors.white
                                              : Colors.black,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        onSelected: (_) =>
                                            apply(label: p, term: query),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (query.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () =>
                                    apply(label: platform, term: ''),
                                icon: const Icon(Icons.close, size: 16),
                                label: Text(query),
                              ),
                            ),
                          ),
                        if (loading)
                          const SliverToBoxAdapter(child: CatalogueShimmer())
                        else if (failed)
                          status(
                            'Could not load catalogue. Tap to retry.',
                            reload,
                          )
                        else ...[
                          if (series.isNotEmpty) ...[
                            heading('Web Series'),
                            rail(series, hero: false),
                          ],
                          if (trending.isNotEmpty) ...[
                            heading('Trending'),
                            rail(trending, hero: true),
                          ],
                          if (movies.isNotEmpty) ...[
                            heading('Movies'),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              sliver: SliverGrid.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                      mainAxisExtent: 214,
                                    ),
                                itemCount: movies.length,
                                itemBuilder: (_, i) => CatalogueTile(
                                  title: movies[i],
                                  height: 170,
                                  showRating: true,
                                  onTap: () => open(movies[i]),
                                ),
                              ),
                            ),
                          ],
                          if (series.isEmpty &&
                              movies.isEmpty &&
                              trending.isEmpty)
                            status(
                              platform == null && query.isEmpty
                                  ? 'No published titles yet.'
                                  : 'No titles found.',
                            ),
                          if (paging)
                            const SliverToBoxAdapter(child: CatalogueShimmer())
                          else if (pageError)
                            status(
                              'Could not load more movies. Retry',
                              nextPage,
                            )
                          else if (movies.isNotEmpty && !more)
                            status('No more movies'),
                        ],
                      ],
                    ),
                  ),
                  if (resultsVisible) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: hideSearch,
                      ),
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: Material(
                          color: const Color(0xff111111),
                          child: finding
                              ? const LinearProgressIndicator()
                              : matches.isEmpty
                              ? ListTile(
                                  title: Text(
                                    searchError
                                        ? 'Search unavailable. Tap to retry.'
                                        : 'No matches',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  onTap: searchError
                                      ? () => find(search.text)
                                      : null,
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: matches.length,
                                  itemBuilder: (_, i) {
                                    final t = matches[i];
                                    return ListTile(
                                      leading: SizedBox(
                                        width: 40,
                                        height: 60,
                                        child: CatalogueImage(url: t.poster),
                                      ),
                                      title: Text(
                                        t.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      onTap: () => open(t),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
