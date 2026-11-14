import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/onboarding/animeplex_splash.dart';
import 'package:watch_app/features/onboarding/onboarding_screen.dart';

void main() {
  testWidgets('startup displays the AnimePlex logo animation', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    expect(find.byType(AnimePlexSplash), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == 'assets/icon/app_icon.png',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
