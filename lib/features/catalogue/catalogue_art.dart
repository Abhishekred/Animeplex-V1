import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/repository/curated_catalogue.dart';

class CatalogueImage extends StatelessWidget {
  const CatalogueImage({super.key, required this.url, this.fallback});
  final String url;
  final String? fallback;
  @override
  Widget build(BuildContext context) => Image.network(
    url,
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
    frameBuilder: (_, child, frame, sync) =>
        sync || frame != null ? child : const _LoadingGlow(),
    errorBuilder: (_, _, _) => fallback != null && fallback != url
        ? CatalogueImage(url: fallback!)
        : const ColoredBox(
            color: Color(0xff222222),
            child: Center(
              child: Icon(Icons.movie_outlined, color: Colors.white38),
            ),
          ),
  );
}

class CatalogueTile extends StatelessWidget {
  const CatalogueTile({
    super.key,
    required this.title,
    required this.height,
    required this.onTap,
    this.hero = false,
    this.showRating = false,
  });
  final CuratedTitle title;
  final double height;
  final bool hero, showRating;
  final VoidCallback onTap;

  Widget badge(String text, {required bool rating}) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      gradient: LinearGradient(
        colors: rating
            ? const [Colors.black, Color(0xff242424)]
            : const [Color(0xffff0000), Color(0xffff9900)],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 11,
          color: rating ? const Color(0xffffd700) : Colors.white,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title.name,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ExcludeSemantics(
        child: Column(
          children: [
            SizedBox(
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CatalogueImage(
                      url: hero && title.backdrop.isNotEmpty
                          ? title.backdrop
                          : title.poster,
                      fallback: title.poster,
                    ),
                    if (title.language.isNotEmpty)
                      Positioned(
                        top: 2,
                        left: 2,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: showRating && title.rating != null
                                ? 70
                                : 120,
                          ),
                          child: badge(title.language, rating: false),
                        ),
                      ),
                    if (showRating && title.rating != null)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: badge(
                          '★ ${title.rating!.toStringAsFixed(1)}',
                          rating: true,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!hero)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  title.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.18,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class CatalogueRail extends StatefulWidget {
  const CatalogueRail({
    super.key,
    required this.items,
    required this.hero,
    required this.onTap,
  });
  final List<CuratedTitle> items;
  final bool hero;
  final ValueChanged<CuratedTitle> onTap;
  @override
  State<CatalogueRail> createState() => _CatalogueRailState();
}

class _CatalogueRailState extends State<CatalogueRail> {
  final scroll = ScrollController();
  Timer? timer;
  bool reduced = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced =
        MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context);
    schedule();
  }

  void schedule([Duration delay = const Duration(seconds: 6)]) {
    timer?.cancel();
    if (widget.hero || reduced || widget.items.length < 2) return;
    timer = Timer(delay, () {
      if (scroll.hasClients &&
          !scroll.position.isScrollingNotifier.value &&
          ModalRoute.of(context)?.isCurrent == true) {
        final end = scroll.position.maxScrollExtent;
        if (end > 0) {
          final to = scroll.offset >= end - 1
              ? 0.0
              : math.min(scroll.offset + 162, end);
          scroll.animateTo(
            to,
            duration: const Duration(milliseconds: 480),
            curve: Curves.easeInOut,
          );
        }
      }
      schedule();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => timer?.cancel(),
    onPointerUp: (_) => schedule(const Duration(seconds: 200)),
    onPointerCancel: (_) => schedule(const Duration(seconds: 200)),
    onPointerSignal: (_) => schedule(const Duration(seconds: 200)),
    child: SizedBox(
      height: widget.hero ? 130 : 252,
      child: ListView.separated(
        controller: scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) => SizedBox(
          width: widget.hero ? 220 : 150,
          child: CatalogueTile(
            title: widget.items[i],
            height: widget.hero ? 130 : 210,
            hero: widget.hero,
            onTap: () => widget.onTap(widget.items[i]),
          ),
        ),
      ),
    ),
  );
}

class CatalogueShimmer extends StatelessWidget {
  const CatalogueShimmer({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(10),
    child: Column(
      children: [
        for (var r = 0; r < 2; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              spacing: 12,
              children: List.generate(
                3,
                (_) => Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: const SizedBox(height: 170, child: _LoadingGlow()),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _LoadingGlow extends StatefulWidget {
  const _LoadingGlow();
  @override
  State<_LoadingGlow> createState() => _LoadingGlowState();
}

class _LoadingGlowState extends State<_LoadingGlow>
    with SingleTickerProviderStateMixin {
  late final clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      clock.stop();
    } else if (!clock.isAnimating) {
      clock.repeat();
    }
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: clock,
      builder: (_, _) {
        final x = clock.value * 4 - 2;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(x - .8, 0),
              end: Alignment(x + .8, 0),
              colors: const [
                Color(0xff222222),
                Color(0xff454545),
                Color(0xff222222),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class CatalogueFireHeading extends StatefulWidget {
  const CatalogueFireHeading({super.key});
  @override
  State<CatalogueFireHeading> createState() => _CatalogueFireHeadingState();
}

class _CatalogueFireHeadingState extends State<CatalogueFireHeading>
    with SingleTickerProviderStateMixin {
  late final clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      clock.stop();
    } else if (!clock.isAnimating) {
      clock.repeat();
    }
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _Embers(clock),
        child: const Text(
          'Trending',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: .5,
            shadows: [
              Shadow(color: Colors.orange, blurRadius: 8),
              Shadow(color: Colors.red, blurRadius: 16),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Embers extends CustomPainter {
  _Embers(this.clock) : super(repaint: clock);
  final Animation<double> clock;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 34; i++) {
      final phase = (clock.value + i * .618) % 1;
      final x = size.width * ((i * .38197) % 1) + math.sin(phase * 6 + i) * 3;
      final color = Color.lerp(
        Colors.orange,
        Colors.red,
        phase,
      )!.withValues(alpha: (1 - phase) * .82);
      canvas.drawCircle(
        Offset(x, size.height * (1 - phase)),
        (1 - phase) * 2.4 + .25,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_Embers old) => old.clock != clock;
}
