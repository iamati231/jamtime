import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';
import 'package:jamtime/features/auth/spotify_session_store.dart';
import 'package:jamtime/features/home/home_screen.dart';
import 'package:jamtime/features/rules/rules_screen.dart';
import 'package:jamtime/features/scanner/scanner_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/channel_guard.dart';

// The "Oyun kuralları" entry on Home: a SECONDARY action next to the main action
// "QR Tara", which opens the local rules page and starts neither camera nor Spotify.

const _failFast = Timeout(Duration(seconds: 10));
final _markerKey = PrefsSpotifySessionStore.key;

const _qr = 'QR Tara';
const _rules = 'Oyun kuralları';

Widget _app({double textScale = 1}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const HomeScreen(),
    );

Future<void> _showHome(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double ratio = 3,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(size.width * ratio, size.height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(textScale: textScale));
  await tester.pumpAndSettle();
}

bool _isGradient(Widget w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration! as BoxDecoration).gradient != null;

void main() {
  setUp(() async {
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{_markerKey: true});
  });

  testWidgets('"Oyun kuralları" is a secondary action; "QR Tara" stays the main one',
      (tester) async {
    await _showHome(tester);

    expect(find.text(_qr), findsOneWidget);
    expect(find.text(_rules), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, _rules), findsOneWidget,
        reason: 'outlined, i.e. quieter than the gradient main action');
    expect(find.widgetWithIcon(OutlinedButton, Icons.menu_book_outlined), findsOneWidget,
        reason: 'book icon');
    expect(find.byWidgetPredicate(_isGradient), findsOneWidget,
        reason: 'only "QR Tara" has the gradient');
    expect(find.descendant(of: find.byWidgetPredicate(_isGradient), matching: find.text(_qr)),
        findsOneWidget);
    expect(tester.getTopLeft(find.text(_rules)).dy, greaterThan(tester.getTopLeft(find.text(_qr)).dy),
        reason: 'below the main action');
  }, timeout: _failFast);

  testWidgets('the button opens the rules page and back returns to Home', (tester) async {
    await _showHome(tester);

    await tester.tap(find.text(_rules));
    await tester.pumpAndSettle();
    expect(find.byType(RulesScreen), findsOneWidget);
    expect(find.text('JamTime nasıl oynanır?'), findsOneWidget);
    expect(find.text(_qr), findsNothing, reason: 'Home is below the rules page');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(RulesScreen), findsNothing);
    expect(find.text(_qr), findsOneWidget, reason: 'back on Home');
    expect(find.text(_rules), findsOneWidget);
  }, timeout: _failFast);

  testWidgets('opening and closing the rules from Home starts neither camera nor Spotify',
      (tester) async {
    final guard = ChannelGuard.install();
    await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
    final attempt = SpotifyAuthService.beginAttempt();
    await _showHome(tester);

    await tester.tap(find.text(_rules));
    await tester.pumpAndSettle();
    expect(find.byType(ScannerScreen), findsNothing, reason: 'no scanner, no camera');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(guard.calls, isEmpty, reason: 'no Spotify, camera, permission or link call');
    expect(SpotifyConnectionMonitor.isConnected, isTrue, reason: 'connection state kept');
    expect(attempt.isCurrent, isTrue, reason: 'a running playback attempt is not invalidated');
    expect((await SharedPreferences.getInstance()).getBool(_markerKey), isTrue);
  }, timeout: _failFast);

  // The new button adds height to a column that does not scroll: small phones and large
  // system fonts must still fit (otherwise Home would have to become overflow-safe).
  const cases = <(Size, double)>[
    (Size(320, 568), 1.0),
    (Size(320, 568), 2.0),
    (Size(375, 667), 2.0),
    (Size(375, 667), 3.0),
  ];
  for (final (size, scale) in cases) {
    testWidgets('Home fits ${size.width.toInt()}x${size.height.toInt()} with text x$scale',
        (tester) async {
      await _showHome(tester, size: size, ratio: 2, textScale: scale);

      expect(tester.takeException(), isNull, reason: 'RenderFlex overflow or similar');
      expect(find.text(_qr), findsOneWidget);
      expect(find.text(_rules), findsOneWidget);
    }, timeout: _failFast);
  }
}
