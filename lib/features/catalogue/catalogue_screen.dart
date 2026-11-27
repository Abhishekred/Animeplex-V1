import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/repository/curated_catalogue.dart';
import '../../core/ui/poster_card.dart';
import '../detail/detail_screen.dart';

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  late Future<List<CuratedTitle>> titles = sl<CuratedCatalogue>().titles();

  Future<void> refresh() async {
    final request = sl<CuratedCatalogue>().titles();
    setState(() => titles = request);
    try {
      await request;
    } catch (_) {
      /* FutureBuilder displays the error. */
    }
  }

  Widget poster(CuratedTitle title, double width) => PosterCard(
    title: title.name,
    imageUrl: title.poster,
    wideOverride: false,
    cellWidth: width,
    onTap: () => Navigator.of(context).push(DetailScreen.route(title.item)),
  );

  Widget heading(String label) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Text(label, style: Theme.of(context).textTheme.titleLarge),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AnimePlex Catalogue'),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: refresh,
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<CuratedTitle>>(
        future: titles,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError)
            return Center(
              child: TextButton(
                onPressed: refresh,
                child: const Text('Could not load catalogue. Retry'),
              ),
            );
          final data = snapshot.data ?? [];
          if (data.isEmpty)
            return const Center(child: Text('No published titles yet.'));
          final series = data.where((t) => t.series).toList();
          final movies = data.where((t) => !t.series).toList();
          return LayoutBuilder(
            builder: (context, box) {
              final width = (box.maxWidth - 52) / 3;
              final height = posterCellHeight(
                width,
                textScaler: MediaQuery.textScalerOf(context),
              );
              return RefreshIndicator(
                onRefresh: refresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (series.isNotEmpty) ...[
                      heading('Web Series'),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: height,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: series.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 10),
                            itemBuilder: (_, i) => SizedBox(
                              width: width,
                              child: poster(series[i], width),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (movies.isNotEmpty) ...[
                      heading('Movies'),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        sliver: SliverGrid.builder(
                          itemCount: movies.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 12,
                                mainAxisExtent: height,
                              ),
                          itemBuilder: (_, i) => poster(movies[i], width),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    ),
  );
}
