// The platform interface is a transitive dependency; the test needs it to model a
// platform store that REFUSES to remove the marker.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/auth_screen.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';
import 'package:jamtime/features/auth/spotify_session_store.dart';
import 'package:jamtime/features/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../helpers/fake_spotify_sdk.dart';

// The "Spotify" menu on Home: known state and the two deliberate actions. Neither
// action revokes Spotify's consent for the app, and the texts must not claim that.

const _failFast = Timeout(Duration(seconds: 10));
const _qrLabel = 'QR Tara';
const _statusUp = "Spotify'a bağlı";
const _statusDown = "Spotify'a bağlı değil";
const _statusDownHint = 'QR kod tarandığında yeniden bağlanır.';
const _disconnectLabel = 'Spotify bağlantısını kes';
const _switchLabel = 'Spotify hesabını değiştir';
const _disconnectTitle = 'Spotify bağlantısı kesilsin mi?';
const _switchTitle = 'Spotify hesabını değiştirmek istiyor musunuz?';
// The approved dialog texts, word for word.
const _disconnectBody =
    "JamTime'ın bu cihazda hatırladığı bağlantı bilgisi silinir ve Spotify bağlantısı "
    "kesilmeye çalışılır. Spotify'da JamTime'a verdiğiniz izin kaldırılmaz. Bu izni "
    'Spotify hesap ayarlarından kaldırabilirsiniz.';
const _switchBody =
    'JamTime, Spotify uygulamasında açık olan hesabı kullanır. Önce mevcut bağlantı '
    "bilgisi silinir. Ardından Spotify'da hesabınızı değiştirip JamTime'a dönerek "
    "yeniden bağlanın. Spotify'da JamTime'a verdiğiniz izin kaldırılmaz.";
const _noRevocation = 'izin kaldırılmaz';
// "not verified", not "failed": a timeout or an unreachable read-back proves no failure.
const _notForgotten = 'Bağlantı bilgisinin silindiği doğrulanamadı. Lütfen tekrar deneyin.';
const _cancel = 'Vazgeç';
const _confirmDisconnect = 'Bağlantıyı kes';
const _confirmSwitch = 'Devam';
const _connectLabel = 'Spotify ile Bağlan';
const _guideTitle = 'Spotify hesabını değiştir'; // same words as the menu entry
final _markerKey = PrefsSpotifySessionStore.key;

const _rootLabel = 'root page';

/// A platform store that refuses to save or remove (the native call returns `false`).
class _RefusingPlatformStore extends InMemorySharedPreferencesStore {
  _RefusingPlatformStore(super.data) : super.withData();

  @override
  Future<bool> remove(String key) async => false;
}

/// A marker store whose `clear` never answers (everything else works).
class _HangingClearStore implements SpotifySessionStore {
  @override
  Future<bool> readSetupDone() async => true;
  @override
  Future<void> writeSetupDone() async {}
  @override
  Future<void> clear() => Completer<void>().future;
}

/// Home as the only route, or - with [onTopOfRoot] - pushed on top of a root page, so
/// that "no way back" can tell `pushAndRemoveUntil` from `pushReplacement`.
Future<void> _showHome(WidgetTester tester, {bool onTopOfRoot = false}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  if (!onTopOfRoot) {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    return;
  }
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
              ),
              child: const Text(_rootLabel),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text(_rootLabel));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.headphones));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400)); // sheet animation
}

Future<bool?> _marker() async => (await SharedPreferences.getInstance()).getBool(_markerKey);

void main() {
  setUp(() async {
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{_markerKey: true});
  });

  testWidgets('the menu shows the KNOWN state and follows changes', (tester) async {
    FakeSdk.install();
    await _showHome(tester);
    await _openMenu(tester);

    expect(find.text(_statusDown), findsOneWidget, reason: 'a marker is not a connection');
    expect(find.text(_statusDownHint), findsOneWidget);

    SpotifyConnectionMonitor.reportConnected();
    await tester.pump();
    expect(find.text(_statusUp), findsOneWidget);
    expect(find.text(_statusDown), findsNothing);
    expect(find.text(_statusDownHint), findsNothing, reason: 'only while not connected');
  }, timeout: _failFast);

  testWidgets('opening the menu talks to no SDK', (tester) async {
    final sdk = FakeSdk.install();
    await _showHome(tester);
    await _openMenu(tester);
    expect(sdk.calls, isEmpty);
  }, timeout: _failFast);

  group('Verbindung trennen', () {
    testWidgets('asks first, says that the Spotify consent is NOT revoked, cancel changes nothing',
        (tester) async {
      final sdk = FakeSdk.install();
      await _showHome(tester);
      await _openMenu(tester);

      await tester.tap(find.text(_disconnectLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(_disconnectTitle), findsOneWidget);
      expect(find.text(_disconnectBody), findsOneWidget);
      expect(find.textContaining(_noRevocation), findsOneWidget,
          reason: 'must not claim that Spotify\'s consent is withdrawn');
      expect(find.textContaining('kurulum'), findsNothing,
          reason: 'no Spotify installation is deleted: the word would mislead');

      await tester.tap(find.text(_cancel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(_qrLabel), findsOneWidget, reason: 'still on Home');
      expect(sdk.calls, isEmpty);
      expect(await _marker(), isTrue);
    }, timeout: _failFast);

    testWidgets('confirmed: marker gone, attempts invalidated, SDK disconnected, no way back',
        (tester) async {
      final sdk = FakeSdk.install();
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final attempt = SpotifyAuthService.beginAttempt(); // a playback still in flight
      await _showHome(tester, onTopOfRoot: true);
      await _openMenu(tester);

      await tester.tap(find.text(_disconnectLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(_confirmDisconnect));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(await _marker(), isNull, reason: 'the marker is removed');
      expect(attempt.isCurrent, isFalse, reason: 'old attempts are invalidated');
      expect(sdk.calls, ['disconnectFromSpotify']);
      expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);

      expect(find.text(_connectLabel), findsOneWidget, reason: 'connect screen is the new root');
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.text(_rootLabel), findsNothing, reason: 'the whole stack is gone');
      expect(find.text(_guideTitle), findsNothing, reason: 'a plain disconnect has no account guide');
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isFalse, reason: 'no way back to Home');
    }, timeout: _failFast);

    testWidgets('the buttons are locked while the disconnect runs', (tester) async {
      final sdk = FakeSdk.install();
      sdk.onCall = (_) => FakeSdk.silent(); // the SDK never answers: bounded by the timeout
      await _showHome(tester);
      await _openMenu(tester);

      await tester.tap(find.text(_disconnectLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(_confirmDisconnect));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      TextButton cancel() => tester.widget(find.ancestor(
          of: find.text(_cancel), matching: find.bySubtype<TextButton>()));
      TextButton confirm() => tester.widget(find.ancestor(
          of: find.byType(CircularProgressIndicator), matching: find.bySubtype<TextButton>()));
      expect(cancel().onPressed, isNull, reason: 'cannot cancel half way');
      expect(confirm().onPressed, isNull, reason: 'and cannot confirm a second time');
      expect(await _marker(), isNull, reason: 'already forgotten before the SDK call ends');

      // Android system Back must not close the busy dialog and leave Home half-forgotten.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.pump(SpotifyAuthService.disconnectTimeout + const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_connectLabel), findsOneWidget, reason: 'finished despite the silent SDK');
    }, timeout: _failFast);
  });

  // The removal of the remembered connection info could not be verified: the app must
  // not say it is gone. It stays on Home, says so, and the user can try again. The rest
  // of the deliberate disconnect (attempts, flight, SDK) has happened anyway.
  group('the removal could not be verified', () {
    for (final action in [_disconnectLabel, _switchLabel]) {
      final confirm = action == _disconnectLabel ? _confirmDisconnect : _confirmSwitch;

      testWidgets('"$action": a store that never answers the clear: stays on Home, says so',
          (tester) async {
        SpotifyAuthService.sessionStore = _HangingClearStore();
        final sdk = FakeSdk.install();
        final attempt = SpotifyAuthService.beginAttempt();
        await _showHome(tester);
        await _openMenu(tester);

        await tester.tap(find.text(action));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text(confirm));
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(AlertDialog), findsOneWidget, reason: 'still waiting for the store');

        await tester.pump(SpotifyAuthService.setupMarkerTimeout + const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(AlertDialog), findsNothing, reason: 'the bound ended the wait');
        expect(find.text(_notForgotten), findsOneWidget);
        expect(find.text(_qrLabel), findsOneWidget, reason: 'still on Home');
        expect(find.byType(AuthScreen), findsNothing, reason: 'nothing is claimed as done');
        expect(attempt.isCurrent, isFalse);
        expect(sdk.calls, ['disconnectFromSpotify']);
      }, timeout: _failFast);
    }

    testWidgets('a clear that fails: stays on Home, says so, the marker is still there',
        (tester) async {
      final sdk = FakeSdk.install();
      SharedPreferencesStorePlatform.instance = _RefusingPlatformStore(
        <String, Object>{'flutter.$_markerKey': true},
      );
      SharedPreferences.resetStatic();
      await _showHome(tester);
      await _openMenu(tester);

      await tester.tap(find.text(_disconnectLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(_confirmDisconnect));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(_notForgotten), findsOneWidget);
      expect(find.text(_qrLabel), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(sdk.calls, ['disconnectFromSpotify']);
      expect(await const PrefsSpotifySessionStore().readSetupDone(), isTrue,
          reason: 'the stored marker is really still there');
    }, timeout: _failFast);
  });

  group('Konto wechseln', () {
    testWidgets('asks first and explains that the account comes from the Spotify app',
        (tester) async {
      FakeSdk.install();
      await _showHome(tester);
      await _openMenu(tester);

      await tester.tap(find.text(_switchLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(_switchTitle), findsOneWidget);
      expect(find.text(_switchBody), findsOneWidget);
      expect(find.textContaining(_noRevocation), findsOneWidget);
      expect(find.textContaining('kurulum'), findsNothing);
    }, timeout: _failFast);

    testWidgets('confirmed: same cleanup as disconnect, then the guided connect screen',
        (tester) async {
      final sdk = FakeSdk.install();
      final attempt = SpotifyAuthService.beginAttempt();
      await _showHome(tester);
      await _openMenu(tester);

      await tester.tap(find.text(_switchLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(_confirmSwitch));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(await _marker(), isNull);
      expect(attempt.isCurrent, isFalse);
      expect(sdk.calls, ['disconnectFromSpotify']);

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text(_guideTitle), findsOneWidget, reason: 'the account guide is shown');
      expect(find.text('Spotify\'ı aç'), findsOneWidget);
      expect(find.text(_connectLabel), findsOneWidget);
      expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
    }, timeout: _failFast);
  });
}
