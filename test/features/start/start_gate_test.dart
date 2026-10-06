import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/app.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';
import 'package:jamtime/features/auth/spotify_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_spotify_sdk.dart';

// App start: the persistent marker decides between Home and the connect screen.
// Starting NEVER touches Spotify: no connect, no app switch. (An automatic connect at
// launch was tried in 5813e07 and removed in cb58cdd because it opened Spotify on
// every launch.) The connection is made on a deliberate play or connect action.

const _failFast = Timeout(Duration(seconds: 10));
const _connectLabel = 'Spotify ile Bağlan';
const _qrLabel = 'QR Tara';
final _markerKey = PrefsSpotifySessionStore.key;

class _BrokenStore implements SpotifySessionStore {
  @override
  Future<bool> readSetupDone() async => throw Exception('unreadable');
  @override
  Future<void> writeSetupDone() async => throw Exception('unwritable');
  @override
  Future<void> clear() async => throw Exception('unwritable');
}

/// A marker store that never answers (the app must not stay blank forever).
class _HangingStore implements SpotifySessionStore {
  @override
  Future<bool> readSetupDone() => Completer<bool>().future;
  @override
  Future<void> writeSetupDone() => Completer<void>().future;
  @override
  Future<void> clear() => Completer<void>().future;
}

Future<void> _startApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const JamTimeApp());
  await tester.pump(); // the marker is read
  await tester.pump();
}

void main() {
  setUp(() async {
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
  });

  testWidgets('with the marker the app opens Home at once and never touches Spotify',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{_markerKey: true});
    final sdk = FakeSdk.install();

    await _startApp(tester);

    expect(find.text(_qrLabel), findsOneWidget);
    expect(find.text(_connectLabel), findsNothing);

    await tester.pump(const Duration(minutes: 2)); // nothing happens later either
    expect(sdk.calls, isEmpty, reason: 'no connect, no play, no pause, no disconnect');
    expect(SpotifyConnectionMonitor.isConnected, isFalse,
        reason: 'the marker is not a connection');
  }, timeout: _failFast);

  testWidgets('without the marker the connect screen is shown and Spotify stays untouched',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final sdk = FakeSdk.install();

    await _startApp(tester);

    expect(find.text(_connectLabel), findsOneWidget);
    expect(find.text(_qrLabel), findsNothing);
    await tester.pump(const Duration(minutes: 2));
    expect(sdk.calls, isEmpty, reason: 'connecting needs the user\'s tap');
  }, timeout: _failFast);

  testWidgets('an unreadable marker means "not set up": connect screen', (tester) async {
    SpotifyAuthService.sessionStore = _BrokenStore();
    final sdk = FakeSdk.install();

    await _startApp(tester);

    expect(find.text(_connectLabel), findsOneWidget);
    expect(sdk.calls, isEmpty);
  }, timeout: _failFast);

  testWidgets('app lifecycle changes never touch Spotify (no connect on resume)',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{_markerKey: true});
    final sdk = FakeSdk.install();
    await _startApp(tester);

    // A real session: the app is backgrounded and comes back several times (for
    // example after the Spotify app was used). Resuming is NOT a reason to connect.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump(const Duration(seconds: 5));
    }

    expect(find.text(_qrLabel), findsOneWidget);
    expect(sdk.calls, isEmpty, reason: 'a lifecycle callback must not start a connect');
  }, timeout: _failFast);

  testWidgets('a marker store that never answers cannot leave the app blank',
      (tester) async {
    SpotifyAuthService.sessionStore = _HangingStore();
    final sdk = FakeSdk.install();

    await _startApp(tester);
    expect(find.text(_connectLabel), findsNothing, reason: 'still reading the marker');
    expect(find.text(_qrLabel), findsNothing);

    await tester.pump(SpotifyAuthService.setupMarkerTimeout + const Duration(seconds: 1));
    expect(find.text(_connectLabel), findsOneWidget, reason: 'gave up: safe default');
    expect(sdk.calls, isEmpty);
  }, timeout: _failFast);

  testWidgets('a marker with the wrong type is not trusted', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{_markerKey: 'yes'});
    FakeSdk.install();

    await _startApp(tester);

    expect(find.text(_connectLabel), findsOneWidget);
  }, timeout: _failFast);

  testWidgets('restart: first setup writes the marker, the next start opens Home directly',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final sdk = FakeSdk.install();

    // First start: connect screen -> the user connects.
    await _startApp(tester);
    await tester.tap(find.text(_connectLabel));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // pause(after connect) answers
    await tester.pump(const Duration(seconds: 1)); // page transition
    expect(find.text(_qrLabel), findsOneWidget, reason: 'connected: Home');
    expect(sdk.calls, ['connectToSpotify', 'pause']);
    expect((await SharedPreferences.getInstance()).getBool(_markerKey), isTrue);

    // "Restart": the process is new (no flight, nothing known about a connection),
    // only the persisted marker survives.
    await tester.pumpWidget(const SizedBox());
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
    sdk.calls.clear();

    await _startApp(tester);
    expect(find.text(_qrLabel), findsOneWidget, reason: 'straight to Home');
    expect(find.text(_connectLabel), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(sdk.calls, isEmpty, reason: 'and still no Spotify switch');
  }, timeout: _failFast);

  testWidgets('a failed first setup leaves no marker: the next start shows the connect screen',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final sdk = FakeSdk.install();
    sdk.onCall = (call) => call.method == 'connectToSpotify' ? FakeSdk.silent() : Future.value(true);

    await _startApp(tester);
    await tester.tap(find.text(_connectLabel));
    await tester.pump(SpotifyAuthService.loginTimeout + const Duration(seconds: 1));
    await tester.pump();
    expect(find.text(_connectLabel), findsOneWidget, reason: 'error state, button is back');
    expect((await SharedPreferences.getInstance()).containsKey(_markerKey), isFalse);

    await tester.pumpWidget(const SizedBox());
    SpotifyAuthService.debugReset();
    await _startApp(tester);
    expect(find.text(_connectLabel), findsOneWidget);
  }, timeout: _failFast);
}
