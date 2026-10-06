import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/auth_screen.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';
import 'package:jamtime/features/auth/spotify_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_spotify_sdk.dart';

// The interactive connect screen, including the guided account switch (the account
// is chosen in the Spotify app; JamTime cannot pick it).

const _failFast = Timeout(Duration(seconds: 10));
const _connectLabel = 'Spotify ile Bağlan';
const _qrLabel = 'QR Tara';
const _hopHint = 'Bağlanırken Spotify kısa süre açılabilir.';
const _connectError = 'Bağlantı kurulamadı.\nSpotify\'ı açıp giriş yaptıktan sonra tekrar dene.';
const _guideTitle = 'Spotify hesabını değiştir';
const _openSpotifyLabel = 'Spotify\'ı aç';
const _notFound = 'Spotify uygulaması bulunamadı.';
final _markerKey = PrefsSpotifySessionStore.key;

/// Counts how often a route was replaced.
class _ReplaceCounter extends NavigatorObserver {
  int replaced = 0;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => replaced++;
}

Future<void> _show(
  WidgetTester tester, {
  bool switchAccount = false,
  Future<bool> Function()? onOpenSpotify,
  Size size = const Size(1170, 2532),
  double ratio = 3,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: AuthScreen(switchAccount: switchAccount, onOpenSpotify: onOpenSpotify),
    ),
  );
}

void main() {
  setUp(() async {
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('announces the unavoidable Spotify switch before it happens', (tester) async {
    FakeSdk.install();
    await _show(tester);
    expect(find.text(_hopHint), findsOneWidget);
  }, timeout: _failFast);

  testWidgets('a successful connect writes the marker and opens Home', (tester) async {
    final sdk = FakeSdk.install();
    await _show(tester);
    expect((await SharedPreferences.getInstance()).containsKey(_markerKey), isFalse);

    await tester.tap(find.text(_connectLabel));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // page transition

    expect(find.text(_qrLabel), findsOneWidget, reason: 'Home');
    expect(sdk.calls, ['connectToSpotify', 'pause']);
    expect((await SharedPreferences.getInstance()).getBool(_markerKey), isTrue);
    expect(SpotifyConnectionMonitor.isConnected, isTrue);
  }, timeout: _failFast);

  testWidgets('a failed connect shows the error, offers the button again, writes no marker',
      (tester) async {
    final sdk = FakeSdk.install();
    sdk.onCall = (_) => Future<Object?>.error(Exception('boom'));
    await _show(tester);

    await tester.tap(find.text(_connectLabel));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text(_connectError), findsOneWidget);
    expect(find.text(_connectLabel), findsOneWidget);
    expect((await SharedPreferences.getInstance()).containsKey(_markerKey), isFalse);
  }, timeout: _failFast);

  testWidgets('a second tap while connecting does not start a second native connect',
      (tester) async {
    final sdk = FakeSdk.install();
    sdk.onCall = (call) => call.method == 'connectToSpotify' ? FakeSdk.silent() : Future.value(true);
    await _show(tester);

    final spot = tester.getCenter(find.text(_connectLabel));
    await tester.tapAt(spot);
    await tester.tapAt(spot); // a second tap on the same spot (button or spinner by now)
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(spot); // and a third, while the connect is still pending

    expect(sdk.count('connectToSpotify'), 1);

    await tester.pump(SpotifyAuthService.loginTimeout + const Duration(seconds: 1)); // drain
  }, timeout: _failFast);

  testWidgets('two taps in the same frame open Home exactly once', (tester) async {
    final sdk = FakeSdk.install();
    final routes = _ReplaceCounter();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(navigatorObservers: [routes], home: const AuthScreen()),
    );

    // tester.tap pumps a frame between taps, so the replaced button could never be hit a
    // second time. Call the handler twice in the SAME frame instead (a double tap that
    // arrives before the next rebuild): the second call must be ignored.
    final onTap = tester
        .widget<GestureDetector>(find.ancestor(
          of: find.text(_connectLabel),
          matching: find.byType(GestureDetector),
        ))
        .onTap!;
    onTap();
    onTap();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(sdk.count('connectToSpotify'), 1);
    expect(find.text(_qrLabel), findsOneWidget);
    expect(routes.replaced, 1, reason: 'Home is opened once, not once per tap');
  }, timeout: _failFast);

  group('account switch (guided)', () {
    testWidgets('shows the steps and says that the account comes from the Spotify app',
        (tester) async {
      FakeSdk.install();
      await _show(tester, switchAccount: true);

      expect(find.text(_guideTitle), findsOneWidget);
      expect(find.text('JamTime, Spotify uygulamasında açık olan hesabı kullanır.'),
          findsOneWidget);
      expect(find.textContaining('1. Spotify\'ı aç'), findsOneWidget);
      expect(find.textContaining('3. "Spotify ile Bağlan"a dokun.'), findsOneWidget);
      expect(find.text(_openSpotifyLabel), findsOneWidget);
      expect(find.text(_connectLabel), findsOneWidget);
    }, timeout: _failFast);

    testWidgets('the normal connect screen has no account guide', (tester) async {
      FakeSdk.install();
      await _show(tester);
      expect(find.text(_guideTitle), findsNothing);
      expect(find.text(_openSpotifyLabel), findsNothing);
    }, timeout: _failFast);

    testWidgets('"Spotify\'ı aç" opens the Spotify app and touches no SDK call', (tester) async {
      final sdk = FakeSdk.install();
      var opened = 0;
      await _show(tester, switchAccount: true, onOpenSpotify: () async {
        opened++;
        return true;
      });

      await tester.tap(find.text(_openSpotifyLabel));
      await tester.pump();

      expect(opened, 1);
      expect(sdk.calls, isEmpty, reason: 'only a deliberate connect talks to the SDK');
      expect(find.text(_notFound), findsNothing);
    }, timeout: _failFast);

    testWidgets('a missing Spotify app is reported', (tester) async {
      FakeSdk.install();
      await _show(tester, switchAccount: true, onOpenSpotify: () async => false);

      await tester.tap(find.text(_openSpotifyLabel));
      await tester.pump();

      expect(find.text(_notFound), findsOneWidget);
    }, timeout: _failFast);

    testWidgets('after switching in Spotify, connecting sets the marker again', (tester) async {
      final sdk = FakeSdk.install();
      await _show(tester, switchAccount: true);

      await tester.tap(find.text(_connectLabel));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(_qrLabel), findsOneWidget);
      expect(sdk.count('connectToSpotify'), 1);
      expect((await SharedPreferences.getInstance()).getBool(_markerKey), isTrue);
    }, timeout: _failFast);

    testWidgets('fits a small phone (375x667) without overflow and can be scrolled',
        (tester) async {
      FakeSdk.install();
      await _show(tester,
          switchAccount: true, size: const Size(750, 1334), ratio: 2);
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull, reason: 'RenderFlex overflow or similar');
      // The connect button may be below the fold, but it can be reached by scrolling.
      await tester.scrollUntilVisible(find.text(_connectLabel), 100);
      expect(find.text(_connectLabel), findsOneWidget);
    }, timeout: _failFast);
  });
}
