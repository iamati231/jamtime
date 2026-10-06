import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Single-flight for connectToSpotifyRemote.
//
// The native plugin cannot cancel a connect and (iOS) has ONE result slot that a
// newer connect overwrites. So the Dart side allows only one connect in flight at a
// time: a second caller joins it instead of starting another native connect. A
// Dart timeout ends the flight (and frees the slot) but does NOT end the native
// connect, so an old native answer can still arrive later. It must neither
// resolve a newer attempt nor free the slot of a newer flight.
//
// Time is fake (testWidgets + tester.pump). The "native side" gives every
// connectToSpotify call its OWN pending answer, so the tests decide when and how
// each one finishes.

const _sdk = MethodChannel('spotify_sdk');
const _reconnect = SpotifyAuthService.reconnectTimeout;
const _login = SpotifyAuthService.loginTimeout;
const _second = Duration(seconds: 1);
const _failFast = Timeout(Duration(seconds: 10));

class _Native {
  final List<String> calls = <String>[];
  final List<Completer<Object?>> connects = <Completer<Object?>>[];

  /// When true the pause-after-connect never answers (bounded by the pause timeout).
  bool pauseSilent = false;

  int get connectCount => connects.length;
  int count(String method) => calls.where((c) => c == method).length;

  Future<Object?>? handle(MethodCall call) {
    calls.add(call.method);
    if (call.method == 'connectToSpotify') {
      final answer = Completer<Object?>();
      connects.add(answer);
      return answer.future;
    }
    if (call.method == 'pause' && pauseSilent) return Completer<Object?>().future;
    return Future<Object?>.value(true); // pause, disconnect, ...
  }
}

_Native _install() {
  final native = _Native();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_sdk, native.handle);
  addTearDown(() => messenger.setMockMethodCallHandler(_sdk, null));
  return native;
}

void main() {
  setUp(() {
    SpotifyAuthService.debugReset();
    // A successful flight writes the setup marker; without a mock that call would
    // never answer and leave its bound timer pending at the end of the test.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('callers share one flight', () {
    testWidgets('two simultaneous connects start ONE native connect and share its result',
        (tester) async {
      final native = _install();
      bool? a, b;
      final fa = SpotifyAuthService.connect().then((v) => a = v);
      final fb = SpotifyAuthService.connect().then((v) => b = v);
      await tester.pump(_second);
      expect(native.connectCount, 1, reason: 'the second caller joined the running flight');

      native.connects.single.complete(true);
      await tester.pump(_second);
      await Future.wait([fa, fb]);

      expect([a, b], [true, true]);
      expect(native.calls, ['connectToSpotify', 'pause'],
          reason: 'one connect, one pause-after-connect for the shared flight');
    }, timeout: _failFast);

    testWidgets('a caller that arrives later while the flight is pending joins it too',
        (tester) async {
      final native = _install();
      bool? a, b;
      final fa = SpotifyAuthService.connect().then((v) => a = v);
      await tester.pump(const Duration(seconds: 5));
      final fb = SpotifyAuthService.connect().then((v) => b = v);
      await tester.pump(const Duration(seconds: 3));
      expect(native.connectCount, 1);
      expect([a, b], [null, null]);

      native.connects.single.complete(true);
      await tester.pump(_second);
      await Future.wait([fa, fb]);
      expect([a, b], [true, true]);
      expect(native.connectCount, 1);
    }, timeout: _failFast);

    testWidgets('a joiner adopts the time limit of the running flight (it cannot extend it)',
        (tester) async {
      final native = _install();
      bool? scan, interactive;
      final fs = SpotifyAuthService.connect(timeout: _reconnect).then((v) => scan = v);
      await tester.pump(_second);
      final fi = SpotifyAuthService.connect(timeout: _login).then((v) => interactive = v);

      await tester.pump(_reconnect); // the flight's own limit (counted from its start)
      await Future.wait([fs, fi]);
      expect([scan, interactive], [false, false]);
      expect(native.connectCount, 1);
    }, timeout: _failFast);

    testWidgets('a joiner never waits longer than its OWN limit while the flight goes on',
        (tester) async {
      final native = _install();
      bool? interactive, automatic;
      final fi = SpotifyAuthService.connect(timeout: _login).then((v) => interactive = v);
      await tester.pump(_second);
      // The automatic scan reconnect (15 s) joins the running interactive flight (90 s).
      final fa = SpotifyAuthService.connect(timeout: _reconnect).then((v) => automatic = v);

      await tester.pump(_reconnect + _second);
      await fa;
      expect(automatic, isFalse, reason: 'the joiner gave up after ITS limit');
      expect(interactive, isNull, reason: 'the flight itself keeps waiting');
      expect(native.connectCount, 1);

      native.connects.single.complete(true);
      await tester.pump(_second);
      await fi;
      expect(interactive, isTrue);
    }, timeout: _failFast);

    testWidgets('a caller arriving during the pause phase still joins the same flight',
        (tester) async {
      final native = _install()..pauseSilent = true;
      final first = SpotifyAuthService.connect();
      await tester.pump(_second);
      native.connects.single.complete(true); // connect answers, the pause is pending
      await tester.pump(const Duration(milliseconds: 500));

      final second = SpotifyAuthService.connect(); // arrives during the pause phase
      await tester.pump(_second);
      expect(native.connectCount, 1, reason: 'joined: no second native connect');

      await tester.pump(SpotifyAuthService.pauseTimeout + _second);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(native.count('pause'), 1);
    }, timeout: _failFast);

    testWidgets('the pause after a connect happens if ANY caller of the flight wants it',
        (tester) async {
      final native = _install();
      final fa = SpotifyAuthService.connect(pauseAfter: false);
      final fb = SpotifyAuthService.connect(); // pauseAfter: true
      await tester.pump(_second);
      native.connects.single.complete(true);
      await tester.pump(_second);
      await Future.wait([fa, fb]);
      expect(native.count('pause'), 1);
    }, timeout: _failFast);

    testWidgets('a finished flight frees the slot: the next connect starts a new native connect',
        (tester) async {
      final native = _install();
      final first = SpotifyAuthService.connect();
      await tester.pump(_second);
      native.connects[0].completeError(PlatformException(code: 'errorConnection'));
      expect(await first, isFalse);

      final second = SpotifyAuthService.connect();
      await tester.pump(_second);
      expect(native.connectCount, 2);
      native.connects[1].complete(true);
      await tester.pump(_second);
      expect(await second, isTrue);
    }, timeout: _failFast);
  });

  group('a timeout does not end the native connect', () {
    testWidgets('no cancel call is made; the next explicit connect starts a SECOND native connect',
        (tester) async {
      final native = _install();
      bool? result;
      final f = SpotifyAuthService.connect(timeout: _reconnect).then((v) => result = v);
      await tester.pump(_reconnect + _second);
      await f;

      expect(result, isFalse);
      expect(native.calls, ['connectToSpotify'],
          reason: 'the plugin has no cancel; the native connect is simply left running');

      // KNOWN LIMIT (documented in SpotifyAuthService.connect): once the flight has
      // timed out its slot is free, so a new connect runs next to the old native one.
      final again = SpotifyAuthService.connect(timeout: _reconnect);
      await tester.pump(_second);
      expect(native.connectCount, 2);

      native.connects[1].complete(true);
      await tester.pump(_second);
      expect(await again, isTrue);
    }, timeout: _failFast);

    testWidgets('a late failure after the limit is swallowed (no unhandled error)',
        (tester) async {
      final native = _install();
      final f = SpotifyAuthService.connect(timeout: _reconnect);
      await tester.pump(_reconnect + _second);
      expect(await f, isFalse);

      native.connects[0].completeError(PlatformException(code: 'late'));
      await tester.pump(); // an unhandled async error would fail this test
    }, timeout: _failFast);
  });

  group('an old native answer does not touch a newer flight', () {
    /// Flight 1 times out, flight 2 (with its own native connect) is running, then the
    /// OLD native connect answers via [finishOld].
    Future<void> oldAnswerWhileNewerFlightRuns(
      WidgetTester tester,
      void Function(Completer<Object?> oldAnswer) finishOld,
    ) async {
      final native = _install();
      bool? r1, r2, r3;

      final f1 = SpotifyAuthService.connect(timeout: _reconnect).then((v) => r1 = v);
      await tester.pump(_reconnect + _second);
      await f1;
      expect(r1, isFalse);

      final f2 = SpotifyAuthService.connect(timeout: _login).then((v) => r2 = v);
      await tester.pump(_second);
      expect(native.connectCount, 2);

      finishOld(native.connects[0]); // the OLD native connect answers now
      await tester.pump(_second);
      expect(r2, isNull, reason: 'an old answer must not resolve the newer attempt');
      expect(native.count('pause'), 0, reason: 'no pause-after-connect for an old answer');

      // If the old answer had freed flight 2's slot, this would start a third connect.
      final f3 = SpotifyAuthService.connect(timeout: _login).then((v) => r3 = v);
      await tester.pump(_second);
      expect(native.connectCount, 2, reason: 'flight 2 still owns the slot');

      native.connects[1].complete(true);
      await tester.pump(_second);
      await Future.wait([f2, f3]);
      expect([r2, r3], [true, true]);
      expect(native.count('pause'), 1, reason: 'only the newer flight pauses');
    }

    testWidgets('old SUCCESS', (tester) async {
      await oldAnswerWhileNewerFlightRuns(tester, (old) => old.complete(true));
    }, timeout: _failFast);

    testWidgets('old FAILURE', (tester) async {
      await oldAnswerWhileNewerFlightRuns(
        tester,
        (old) => old.completeError(PlatformException(code: 'errorConnection')),
      );
    }, timeout: _failFast);

    testWidgets('the newer flight finishes first, the old answer arrives afterwards',
        (tester) async {
      final native = _install();
      final f1 = SpotifyAuthService.connect(timeout: _reconnect);
      await tester.pump(_reconnect + _second);
      expect(await f1, isFalse);

      final f2 = SpotifyAuthService.connect(timeout: _login);
      await tester.pump(_second);
      native.connects[1].complete(true);
      await tester.pump(_second);
      expect(await f2, isTrue);
      final pausesBefore = native.count('pause');

      native.connects[0].completeError(PlatformException(code: 'errorConnection'));
      await tester.pump(_second);
      expect(native.count('pause'), pausesBefore, reason: 'the old answer triggers nothing');

      // The slot is free (its owner finished): a new connect starts a third one.
      final f3 = SpotifyAuthService.connect(timeout: _login);
      await tester.pump(_second);
      expect(native.connectCount, 3);
      native.connects[2].complete(true);
      await tester.pump(_second);
      expect(await f3, isTrue);
    }, timeout: _failFast);
  });
}
