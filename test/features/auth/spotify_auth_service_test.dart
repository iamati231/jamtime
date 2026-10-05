import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';

// Regression: das iOS-Plugin von spotify_sdk ruft bei play/pause/connect unter
// Umstaenden NIE einen Callback auf (appRemote.playerAPI?.… ohne else-Zweig).
// Ohne Timeout bleibt der Aufrufer dann fuer immer haengen. Die Tests simulieren
// das mit einem Channel-Mock, dessen Future nie fertig wird, und schieben die
// (Fake-)Zeit mit tester.pump() ueber die Timeouts. Die Dauern kommen aus den
// Konstanten des Service, damit das spaetere Tunen die Tests nicht bricht.

const _sdk = MethodChannel('spotify_sdk');
const _trackUrl = 'https://open.spotify.com/track/abc123';

const _pause = SpotifyAuthService.pauseTimeout;
const _play = SpotifyAuthService.playTimeout;
const _reconnect = SpotifyAuthService.reconnectTimeout;
const _login = SpotifyAuthService.loginTimeout;
const _second = Duration(seconds: 1);

/// Kehrt der Code wieder zum alten Haenge-Verhalten zurueck, soll der Test in
/// Sekunden scheitern statt erst nach dem 10-Minuten-Standard von testWidgets.
const _failFast = Timeout(Duration(seconds: 10));

/// Future, das nie abgeschlossen wird = "native Seite antwortet nicht".
Future<Object?> _silent() => Completer<Object?>().future;

void _mockSdk(Future<Object?>? Function(MethodCall call) handler) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_sdk, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(_sdk, null));
}

void main() {
  group('pause()', () {
    testWidgets('returns after the timeout when the SDK never answers',
        (tester) async {
      final calls = <String>[];
      _mockSdk((call) {
        calls.add(call.method);
        return _silent();
      });

      var done = false;
      final future = SpotifyAuthService.pause().then((_) => done = true);

      await tester.pump(_pause - _second);
      expect(done, isFalse, reason: 'still inside the pause timeout');

      await tester.pump(_second * 2);
      await future;
      expect(done, isTrue);
      expect(calls, ['pause']);
    }, timeout: _failFast);

    testWidgets('swallows SDK errors', (tester) async {
      _mockSdk((call) async => throw PlatformException(code: 'PlayerAPI Error'));

      await SpotifyAuthService.pause(); // must not throw
    }, timeout: _failFast);
  });

  group('playTrack()', () {
    testWidgets('returns true right away when play answers', (tester) async {
      final calls = <String>[];
      _mockSdk((call) async {
        calls.add(call.method);
        return true;
      });

      expect(await SpotifyAuthService.playTrack(_trackUrl), isTrue);
      expect(calls, ['play'], reason: 'no reconnect when play works');
    }, timeout: _failFast);

    testWidgets('reaches the reconnect fallback when play never answers',
        (tester) async {
      final calls = <String>[];
      var plays = 0;
      _mockSdk((call) {
        calls.add(call.method);
        switch (call.method) {
          case 'play':
            return plays++ == 0 ? _silent() : Future<Object?>.value(true);
          case 'connectToSpotify':
            return Future<Object?>.value(true);
          default:
            return Future<Object?>.value(null);
        }
      });

      bool? result;
      final future =
          SpotifyAuthService.playTrack(_trackUrl).then((v) => result = v);

      await tester.pump(_play + _second); // > play timeout
      await future;

      expect(result, isTrue);
      expect(calls, ['play', 'connectToSpotify', 'play'],
          reason: 'silent play -> timeout -> reconnect -> retry (no pause)');
    }, timeout: _failFast);

    testWidgets('gives up (false) when play and reconnect never answer',
        (tester) async {
      final calls = <String>[];
      _mockSdk((call) {
        calls.add(call.method);
        return _silent();
      });

      bool? result;
      final future =
          SpotifyAuthService.playTrack(_trackUrl).then((v) => result = v);

      await tester.pump(_play + _second); // play timed out
      expect(result, isNull, reason: 'waiting for the reconnect (its own timeout)');
      expect(calls, ['play', 'connectToSpotify']);

      // The reconnect inside the scan flow gives up after the (short) reconnect
      // timeout, NOT after the long login timeout.
      await tester.pump(_reconnect + _second);
      await future;

      expect(result, isFalse);
      expect(calls, ['play', 'connectToSpotify'],
          reason: 'no retry play after a failed reconnect');
    }, timeout: _failFast);
  });

  group('connect()', () {
    testWidgets('returns false after the login timeout when the SDK never answers',
        (tester) async {
      _mockSdk((call) => _silent());

      bool? result;
      final future = SpotifyAuthService.connect().then((v) => result = v);

      await tester.pump(_login - _second);
      expect(result, isNull, reason: 'still inside the login timeout');

      await tester.pump(_second * 2);
      await future;
      expect(result, isFalse);
    }, timeout: _failFast);

    // First-time authorization: the user may need longer in the Spotify app than
    // the reconnect timeout. Cutting login off there would show an error screen
    // although the App Remote connects right afterwards (and skip the pause).
    testWidgets('login is not cut off at the reconnect timeout', (tester) async {
      final calls = <String>[];
      _mockSdk((call) {
        calls.add(call.method);
        return call.method == 'connectToSpotify'
            ? Future<Object?>.delayed(_reconnect + const Duration(seconds: 5), () => true)
            : Future<Object?>.value(true);
      });

      bool? result;
      final future = SpotifyAuthService.connect().then((v) => result = v);

      await tester.pump(_reconnect + _second);
      expect(result, isNull, reason: 'login still waits for the user in Spotify');

      await tester.pump(const Duration(seconds: 6));
      await future;
      expect(result, isTrue);
      expect(calls, ['connectToSpotify', 'pause'],
          reason: 'pause-after-connect must still run');
    }, timeout: _failFast);

    testWidgets('pauses after a successful connect even if pause is silent',
        (tester) async {
      final calls = <String>[];
      _mockSdk((call) {
        calls.add(call.method);
        return call.method == 'connectToSpotify'
            ? Future<Object?>.value(true)
            : _silent();
      });

      bool? result;
      final future = SpotifyAuthService.connect().then((v) => result = v);

      await tester.pump(_pause + _second); // > pause timeout
      await future;

      expect(result, isTrue);
      expect(calls, ['connectToSpotify', 'pause']);
    }, timeout: _failFast);
  });

  // Eine Antwort, die erst NACH dem Timeout eintrifft, darf nichts mehr ausloesen:
  // keine zusaetzlichen SDK-Aufrufe und keinen unbehandelten Fehler (testWidgets
  // schlaegt bei einer unbehandelten Async-Exception fehl).
  group('late replies after a timeout', () {
    testWidgets('a late play success is ignored', (tester) async {
      final calls = <String>[];
      final slowFirstPlay = Completer<Object?>();
      var plays = 0;
      _mockSdk((call) {
        calls.add(call.method);
        switch (call.method) {
          case 'play':
            return plays++ == 0 ? slowFirstPlay.future : Future<Object?>.value(true);
          case 'connectToSpotify':
            return Future<Object?>.value(true);
          default:
            return Future<Object?>.value(null);
        }
      });

      bool? result;
      final future =
          SpotifyAuthService.playTrack(_trackUrl).then((v) => result = v);
      await tester.pump(_play + _second); // first play timed out -> reconnect -> retry
      await future;
      expect(result, isTrue);
      expect(calls, ['play', 'connectToSpotify', 'play']);

      slowFirstPlay.complete(true); // Spotify finally answers the FIRST play
      await tester.pump();

      expect(result, isTrue);
      expect(calls, ['play', 'connectToSpotify', 'play'],
          reason: 'a late reply must not cause any SDK traffic');
    }, timeout: _failFast);

    testWidgets('a late play error is swallowed', (tester) async {
      final slowFirstPlay = Completer<Object?>();
      var plays = 0;
      _mockSdk((call) {
        if (call.method == 'play') {
          return plays++ == 0 ? slowFirstPlay.future : Future<Object?>.value(true);
        }
        return Future<Object?>.value(true);
      });

      final future = SpotifyAuthService.playTrack(_trackUrl);
      await tester.pump(_play + _second);
      expect(await future, isTrue);

      slowFirstPlay.completeError(PlatformException(code: 'late'));
      await tester.pump(); // an unhandled async error would fail this test
    }, timeout: _failFast);

    testWidgets('a connect success after the reconnect timeout triggers nothing',
        (tester) async {
      final calls = <String>[];
      final slowConnect = Completer<Object?>();
      _mockSdk((call) {
        calls.add(call.method);
        return call.method == 'connectToSpotify' ? slowConnect.future : _silent();
      });

      bool? result;
      final future =
          SpotifyAuthService.playTrack(_trackUrl).then((v) => result = v);
      await tester.pump(_play + _second);
      await tester.pump(_reconnect + _second);
      await future;
      expect(result, isFalse);
      expect(calls, ['play', 'connectToSpotify']);

      slowConnect.complete(true); // the connection comes up after we gave up
      await tester.pump();

      expect(result, isFalse);
      expect(calls, ['play', 'connectToSpotify'],
          reason: 'no retry play / pause after a late connect');
    }, timeout: _failFast);
  });

  // Generation-Guard: ein veralteter Versuch (Screen geschlossen oder ein neuerer
  // Versuch hat begonnen) startet keine weiteren SDK-Aufrufe (Reconnect / Retry).
  // cancel() entwertet nur den EIGENEN Versuch.
  group('attempt guard', () {
    const urlA = 'https://open.spotify.com/track/trackA';
    const urlB = 'https://open.spotify.com/track/trackB';
    const uriA = 'spotify:track:trackA';
    const uriB = 'spotify:track:trackB';

    String? uriOf(MethodCall call) =>
        (call.arguments as Map<Object?, Object?>?)?['spotifyUri'] as String?;

    testWidgets('scan A waits, scanner closed: a late reply starts no reconnect or retry',
        (tester) async {
      final calls = <String>[];
      final slowFirstPlay = Completer<Object?>();
      _mockSdk((call) {
        calls.add(call.method);
        return call.method == 'play' ? slowFirstPlay.future : Future<Object?>.value(true);
      });

      final a = SpotifyAuthService.beginAttempt();
      bool? result;
      final future =
          SpotifyAuthService.playTrack(urlA, attempt: a).then((v) => result = v);

      await tester.pump(_second);
      a.cancel(); // the scanner was closed while A is still waiting

      await tester.pump(_play); // the first play times out
      await future;
      expect(result, isFalse);
      expect(calls, ['play'], reason: 'stale A: no reconnect, no retry');

      slowFirstPlay.complete(true); // the late reply
      await tester.pump();
      expect(calls, ['play']);
    }, timeout: _failFast);

    testWidgets('closed while the reconnect is in flight: no retry play after it returns',
        (tester) async {
      final calls = <String>[];
      final connect = Completer<Object?>();
      _mockSdk((call) {
        calls.add(call.method);
        return call.method == 'connectToSpotify' ? connect.future : _silent();
      });

      final a = SpotifyAuthService.beginAttempt();
      bool? result;
      final future =
          SpotifyAuthService.playTrack(urlA, attempt: a).then((v) => result = v);
      await tester.pump(_play + _second);
      expect(calls, ['play', 'connectToSpotify']);

      a.cancel();
      connect.complete(true); // the reconnect succeeds, but A is gone
      await tester.pump();
      await future;

      expect(result, isFalse);
      expect(calls, ['play', 'connectToSpotify'], reason: 'no play(A) retry');
    }, timeout: _failFast);

    testWidgets('B plays: a late-returning A must not replace B with play(A)',
        (tester) async {
      final plays = <String>[];
      final connectA = Completer<Object?>();
      _mockSdk((call) {
        switch (call.method) {
          case 'play':
            final uri = uriOf(call);
            plays.add(uri == uriA ? 'A' : uri == uriB ? 'B' : '?');
            return uri == uriA ? _silent() : Future<Object?>.value(true);
          case 'connectToSpotify':
            return connectA.future; // A's reconnect, still pending
          default:
            return Future<Object?>.value(null);
        }
      });

      final a = SpotifyAuthService.beginAttempt();
      bool? resultA;
      final futureA =
          SpotifyAuthService.playTrack(urlA, attempt: a).then((v) => resultA = v);
      await tester.pump(_play + _second); // A: play timed out, reconnect in flight

      // The user left the stuck screen, opened a new scanner and scanned B.
      final b = SpotifyAuthService.beginAttempt(); // A is stale from now on
      expect(await SpotifyAuthService.playTrack(urlB, attempt: b), isTrue);
      expect(plays, ['A', 'B']);

      connectA.complete(true); // A's reconnect finally returns
      await tester.pump();
      await futureA;

      expect(resultA, isFalse);
      expect(plays, ['A', 'B'], reason: 'no play(A) after B started playing');
    }, timeout: _failFast);

    testWidgets('cancelling the old attempt (old screen disposed) does not invalidate B',
        (tester) async {
      final calls = <String>[];
      final plays = <String>[];
      _mockSdk((call) {
        calls.add(call.method);
        switch (call.method) {
          case 'play':
            final uri = uriOf(call);
            plays.add(uri == uriA ? 'A' : uri == uriB ? 'B' : '?');
            // A and B's FIRST play are silent; B's retry (3rd play) answers.
            return plays.length >= 3 ? Future<Object?>.value(true) : _silent();
          case 'connectToSpotify':
            return Future<Object?>.value(true);
          default:
            return Future<Object?>.value(null);
        }
      });

      final a = SpotifyAuthService.beginAttempt();
      unawaited(SpotifyAuthService.playTrack(urlA, attempt: a));
      final b = SpotifyAuthService.beginAttempt();
      bool? resultB;
      final futureB =
          SpotifyAuthService.playTrack(urlB, attempt: b).then((v) => resultB = v);

      await tester.pump(_second);
      a.cancel(); // the OLD screen is disposed while B is still waiting
      expect(b.isCurrent, isTrue);

      await tester.pump(_play + _second); // B's first play times out
      await futureB;

      expect(resultB, isTrue, reason: 'B must still reconnect and retry');
      expect(calls.where((c) => c == 'connectToSpotify'), hasLength(1),
          reason: 'only B reconnects; A is stale');
      expect(plays, ['A', 'B', 'B']);
    }, timeout: _failFast);

    testWidgets('an already stale attempt starts no SDK call at all', (tester) async {
      final calls = <String>[];
      _mockSdk((call) async {
        calls.add(call.method);
        return true;
      });

      final cancelled = SpotifyAuthService.beginAttempt()..cancel();
      expect(await SpotifyAuthService.playTrack(urlA, attempt: cancelled), isFalse);

      final older = SpotifyAuthService.beginAttempt();
      final newer = SpotifyAuthService.beginAttempt(); // supersedes `older`
      expect(older.isCurrent, isFalse);
      expect(newer.isCurrent, isTrue);
      expect(await SpotifyAuthService.playTrack(urlA, attempt: older), isFalse);

      expect(calls, isEmpty);
    }, timeout: _failFast);
  });
}
