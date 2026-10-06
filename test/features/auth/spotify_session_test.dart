// The platform interface is a transitive dependency; the tests need it to model a
// platform store that REFUSES to save or remove (the native call returns false).
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';
import 'package:jamtime/features/auth/spotify_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

// The persistent "setup was done once" marker and everything that may touch it.
//
// The marker is NOT "connected" and NOT "token valid". It is written only after a
// successful setup and removed only by a deliberate disconnect / account switch or
// a definitive authorization failure. Timeouts and temporary errors never remove it.

const _sdk = MethodChannel('spotify_sdk');
const _trackUrl = 'https://open.spotify.com/track/abc123';
const _reconnect = SpotifyAuthService.reconnectTimeout;
const _play = SpotifyAuthService.playTimeout;
const _second = Duration(seconds: 1);
const _tick = Duration(milliseconds: 100);
const _failFast = Timeout(Duration(seconds: 10));

/// In-memory store that records what happened to the marker.
class _MemoryStore implements SpotifySessionStore {
  _MemoryStore({this.done = false});

  bool done;
  final List<String> log = <String>[];

  /// When set, every call throws it (a broken disk must never break playback).
  Object? failWith;

  /// When set, that kind of call never answers (a store that hangs).
  bool hangReads = false;
  bool hangWrites = false;
  bool hangClears = false;

  /// When set, a write waits for the gate BEFORE it takes effect: a write that lands
  /// late, possibly after a clear that was issued later (nothing guarantees the order
  /// in which the storage finishes its operations).
  Completer<void>? writeGate;

  /// When set, a clear waits for the gate BEFORE it takes effect (a clear that lands late).
  Completer<void>? clearGate;

  /// A faulty store: clear() completes normally but changes nothing.
  bool ignoreClears = false;

  void _maybeFail() {
    final e = failWith;
    if (e != null) throw e;
  }

  @override
  Future<bool> readSetupDone() async {
    _maybeFail();
    if (hangReads) await Completer<void>().future;
    return done;
  }

  @override
  Future<void> writeSetupDone() async {
    _maybeFail();
    if (hangWrites) await Completer<void>().future;
    final gate = writeGate;
    if (gate != null) await gate.future;
    log.add('write');
    done = true;
  }

  @override
  Future<void> clear() async {
    _maybeFail();
    if (hangClears) await Completer<void>().future;
    final gate = clearGate;
    if (gate != null) await gate.future;
    log.add('clear');
    if (!ignoreClears) done = false;
  }
}

/// A store whose every operation waits for the test, so the test decides in which order
/// the operations land (real storage guarantees no order).
class _ScriptedStore implements SpotifySessionStore {
  /// The operations in the order they were issued ('write' / 'clear').
  final List<String> kinds = <String>[];
  final List<Completer<void>> _gates = <Completer<void>>[];

  /// The really stored state; an operation changes it when it LANDS.
  bool done = false;

  /// When set, a read answers this instead of the stored state (a stale read-back).
  bool? staleRead;

  /// When set, every operation (also later ones) lands at once.
  bool _autoLand = false;

  @override
  Future<bool> readSetupDone() async => staleRead ?? done;

  @override
  Future<void> writeSetupDone() => _issue('write');

  @override
  Future<void> clear() => _issue('clear');

  Future<void> _issue(String kind) async {
    final gate = Completer<void>();
    kinds.add(kind);
    _gates.add(gate);
    if (_autoLand) gate.complete();
    await gate.future;
    done = kind == 'write';
  }

  /// Lets the [index]-th issued operation land.
  void land(int index) => _gates[index].complete();

  /// Lets every pending operation land, and every later one at once.
  void landAll() {
    _autoLand = true;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

/// A platform store that refuses to save or remove (the native call returns `false`),
/// like a full or locked disk. `shared_preferences` has already changed its cache by
/// then, so only the returned `false` tells the truth.
class _RefusingPlatformStore extends InMemorySharedPreferencesStore {
  _RefusingPlatformStore(super.data) : super.withData();

  bool refuse = true;

  @override
  Future<bool> remove(String key) async => refuse ? false : super.remove(key);

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      refuse ? false : super.setValue(valueType, key, value);
}

/// The plugin's connection status event stream (what the iOS plugin sends).
class _StatusEvents {
  _StatusEvents() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    _messenger = messenger;
    messenger.setMockMethodCallHandler(const MethodChannel('connection_status_subscription'),
        (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('connection_status_subscription'), null));
  }

  late final TestDefaultBinaryMessenger _messenger;

  void emit(String json) {
    _messenger.handlePlatformMessage(
      'connection_status_subscription',
      const StandardMethodCodec().encodeSuccessEnvelope(json),
      null,
    );
  }
}

/// Fake native side: every connectToSpotify gets its own pending answer.
class _Native {
  final List<String> calls = <String>[];
  final List<Completer<Object?>> connects = <Completer<Object?>>[];

  /// How the other methods answer (default: success).
  Future<Object?>? Function(MethodCall call) other = (_) => Future<Object?>.value(true);

  int count(String method) => calls.where((c) => c == method).length;

  Future<Object?>? handle(MethodCall call) {
    calls.add(call.method);
    if (call.method == 'connectToSpotify') {
      final answer = Completer<Object?>();
      connects.add(answer);
      return answer.future;
    }
    return other(call);
  }
}

_Native _installNative() {
  final native = _Native();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_sdk, native.handle);
  addTearDown(() => messenger.setMockMethodCallHandler(_sdk, null));
  return native;
}

_MemoryStore _installStore({bool done = false}) {
  final store = _MemoryStore(done: done);
  SpotifyAuthService.sessionStore = store;
  return store;
}

/// One connect flight that ends with [answer], then lets the fire-and-forget marker
/// write/clear finish.
Future<bool> _connectAnswering(
  WidgetTester tester,
  _Native native,
  void Function(Completer<Object?> pending) answer, {
  Duration timeout = _reconnect,
}) async {
  final index = native.connects.length;
  final future = SpotifyAuthService.connect(timeout: timeout);
  await tester.pump(_second);
  answer(native.connects[index]);
  await tester.pump(_second);
  final ok = await future;
  await tester.pump(); // the marker write / clear is fire-and-forget
  return ok;
}

/// A connect that succeeds at once: the decision becomes "remember" (the marker write starts).
Future<void> _connectQuickly(WidgetTester tester, _Native native) async {
  final index = native.connects.length;
  final future = SpotifyAuthService.connect(timeout: _reconnect);
  await tester.pump(_tick);
  native.connects[index].complete(true);
  await tester.pump(_tick);
  expect(await future, isTrue);
}

void main() {
  setUp(() async {
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('marker: only a successful setup writes it', () {
    testWidgets('written after a successful connect, not while it is pending',
        (tester) async {
      final native = _installNative();
      final store = _installStore();

      final future = SpotifyAuthService.connect();
      await tester.pump(_second);
      expect(store.log, isEmpty, reason: 'connect still pending: nothing written yet');

      native.connects.single.complete(true);
      await tester.pump(_second);
      expect(await future, isTrue);
      await tester.pump();
      expect(store.log, ['write']);
      expect(store.done, isTrue);
    }, timeout: _failFast);

    testWidgets('a failed connect never writes it', (tester) async {
      final native = _installNative();
      final store = _installStore();

      final ok = await _connectAnswering(
        tester,
        native,
        (c) => c.completeError(PlatformException(code: 'errorConnection')),
      );
      expect(ok, isFalse);
      expect(store.log, isEmpty);
    }, timeout: _failFast);

    testWidgets('a connect that answers false never writes it', (tester) async {
      final native = _installNative();
      final store = _installStore();

      final ok = await _connectAnswering(tester, native, (c) => c.complete(false));
      expect(ok, isFalse);
      expect(store.log, isEmpty);
    }, timeout: _failFast);

    testWidgets('a store that throws never breaks the connect', (tester) async {
      final native = _installNative();
      final store = _installStore()..failWith = Exception('disk full');

      final ok = await _connectAnswering(tester, native, (c) => c.complete(true));
      expect(ok, isTrue, reason: 'playback must not depend on persisting the marker');
      expect(store.log, isEmpty);
    }, timeout: _failFast);

    testWidgets('hasCompletedSetup reads the store; a broken store means "not set up"',
        (tester) async {
      final store = _installStore(done: true);
      expect(await SpotifyAuthService.hasCompletedSetup(), isTrue);

      store.done = false;
      expect(await SpotifyAuthService.hasCompletedSetup(), isFalse);

      store.failWith = Exception('unreadable');
      expect(await SpotifyAuthService.hasCompletedSetup(), isFalse,
          reason: 'safe default: show the connect screen');
    }, timeout: _failFast);
  });

  group('marker: timeouts and temporary errors do not log out', () {
    testWidgets('a connect timeout keeps it', (tester) async {
      _installNative(); // never answers
      final store = _installStore(done: true);

      final future = SpotifyAuthService.connect(timeout: _reconnect);
      await tester.pump(_reconnect + _second);
      expect(await future, isFalse);
      await tester.pump();
      expect(store.log, isEmpty);
      expect(store.done, isTrue);
    }, timeout: _failFast);

    testWidgets('temporary errors keep it (unknown codes, numeric iOS codes, plain exceptions)',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);

      final answers = <void Function(Completer<Object?>)>[
        (c) => c.completeError(PlatformException(code: 'errorConnection')),
        (c) => c.completeError(PlatformException(code: '-1000')), // numeric iOS code
        (c) => c.completeError(PlatformException(code: 'SpotifyDisconnectedException')),
        (c) => c.completeError(PlatformException(code: 'OfflineModeException')),
        (c) => c.completeError(MissingPluginException()),
        (c) => c.completeError(Exception('boom')),
      ];
      for (final answer in answers) {
        expect(await _connectAnswering(tester, native, answer), isFalse);
      }
      expect(store.log, isEmpty, reason: 'none of these may clear the marker');
      expect(store.done, isTrue);
    }, timeout: _failFast);

    testWidgets('"Spotify not installed" keeps it (the app may be installed later)',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);

      for (final code in ['spotifyNotInstalled', 'CouldNotFindSpotifyApp']) {
        expect(
          await _connectAnswering(
              tester, native, (c) => c.completeError(PlatformException(code: code))),
          isFalse,
        );
      }
      expect(store.log, isEmpty);
      expect(store.done, isTrue);
    }, timeout: _failFast);

    testWidgets('a playback that gives up (play + reconnect time out) keeps it',
        (tester) async {
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final native = _installNative();
      native.other = (_) => Completer<Object?>().future; // play never answers either
      final store = _installStore(done: true);

      final future = SpotifyAuthService.playTrack(_trackUrl);
      await tester.pump(_play + _second);
      await tester.pump(_reconnect + _second);
      expect(await future, isFalse);
      await tester.pump();
      expect(store.log, isEmpty);
      expect(store.done, isTrue);
    }, timeout: _failFast);
  });

  group('marker: a definitive authorization failure removes it', () {
    testWidgets('authorization codes clear it', (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);

      for (final code in [
        'authenticationTokenError', // iOS
        'UserNotAuthorizedException', // Android
        'AuthenticationFailedException',
        'NotLoggedInException',
      ]) {
        store.done = true;
        store.log.clear();
        expect(
          await _connectAnswering(
              tester, native, (c) => c.completeError(PlatformException(code: code))),
          isFalse,
          reason: code,
        );
        expect(store.log, ['clear'], reason: code);
        expect(store.done, isFalse, reason: code);
      }
    }, timeout: _failFast);
  });

  group('classification of connect errors', () {
    final cases = <String, ConnectFailure>{
      'authenticationTokenError': ConnectFailure.authRequired,
      'UserNotAuthorizedException': ConnectFailure.authRequired,
      'AuthenticationFailedException': ConnectFailure.authRequired,
      'NotLoggedInException': ConnectFailure.authRequired,
      'spotifyNotInstalled': ConnectFailure.spotifyMissing,
      'CouldNotFindSpotifyApp': ConnectFailure.spotifyMissing,
      'errorConnection': ConnectFailure.temporary,
      'errorConnecting': ConnectFailure.temporary,
      'SpotifyDisconnectedException': ConnectFailure.temporary,
      'SpotifyRemoteServiceException': ConnectFailure.temporary,
      '-1000': ConnectFailure.temporary,
      '': ConnectFailure.temporary,
    };
    cases.forEach((code, expected) {
      test('PlatformException "$code" -> $expected', () {
        expect(SpotifyAuthService.classifyConnectError(PlatformException(code: code)),
            expected);
      });
    });

    test('a TimeoutException is a timeout, anything else is temporary', () {
      expect(SpotifyAuthService.classifyConnectError(TimeoutException('x')),
          ConnectFailure.timeout);
      expect(SpotifyAuthService.classifyConnectError(Exception('x')),
          ConnectFailure.temporary);
      expect(SpotifyAuthService.classifyConnectError(MissingPluginException()),
          ConnectFailure.temporary);
    });
  });

  // KNOWN LIMIT (see SpotifyAuthService.connect): a Dart timeout cannot cancel the
  // native connect, so its answer can arrive later. The Dart side ignores it: no
  // marker change, no state change. The plugin's connection event stream (not tested
  // here) is what reports a connection that does come up late.
  group('a late native answer after the limit changes nothing', () {
    testWidgets('a late success writes no marker and does not mark the link as up',
        (tester) async {
      final native = _installNative();
      final store = _installStore();

      final future = SpotifyAuthService.connect(timeout: _reconnect);
      await tester.pump(_reconnect + _second);
      expect(await future, isFalse);

      native.connects.single.complete(true); // Spotify connects after all
      await tester.pump(_second);
      await tester.pump();

      expect(store.log, isEmpty);
      expect(store.done, isFalse);
      expect(SpotifyConnectionMonitor.isConnected, isFalse);
      expect(native.count('pause'), 0);
    }, timeout: _failFast);

    testWidgets('a late authorization error does not clear the marker', (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);

      final future = SpotifyAuthService.connect(timeout: _reconnect);
      await tester.pump(_reconnect + _second);
      expect(await future, isFalse);

      native.connects.single
          .completeError(PlatformException(code: 'authenticationTokenError'));
      await tester.pump(_second);
      await tester.pump();

      expect(store.log, isEmpty, reason: 'the flight was over; the answer is only logged');
      expect(store.done, isTrue);
    }, timeout: _failFast);
  });

  group('known connection state during and after a flight', () {
    testWidgets('a link drop reported during the pause phase is not overridden afterwards',
        (tester) async {
      final events = _StatusEvents();
      SpotifyConnectionMonitor.install();
      await tester.pump();
      final native = _installNative();
      native.other = (call) =>
          call.method == 'pause' ? Completer<Object?>().future : Future<Object?>.value(true);
      _installStore();

      final future = SpotifyAuthService.connect();
      await tester.pump(_second);
      native.connects.single.complete(true); // connected; the pause is pending now
      await tester.pump(const Duration(milliseconds: 100));
      expect(SpotifyConnectionMonitor.isConnected, isTrue, reason: 'up as soon as Spotify answered');

      events.emit('{"connected": false, "errorCode": "-1001"}'); // the link drops meanwhile
      await tester.pump(const Duration(milliseconds: 100));
      expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);

      await tester.pump(SpotifyAuthService.pauseTimeout + _second); // the pause times out
      expect(await future, isTrue);
      expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue,
          reason: 'finishing the flight must not override the later event');
    }, timeout: _failFast);

    // KNOWN LIMIT (iOS): the plugin answers ANY foreign URL that opens the app while a
    // connect is pending with `authenticationTokenError` and frees its slot. Dart cannot tell
    // that from a real refusal: the marker goes, and the next connect runs next to the hop.
    testWidgets('KNOWN LIMIT: a foreign URL ends the flight and clears the marker; the hop may still run',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);

      final first = SpotifyAuthService.connect();
      await tester.pump(_second);
      native.connects[0].completeError(PlatformException(code: 'authenticationTokenError'));
      expect(await first, isFalse);
      await tester.pump();
      expect(store.log, ['clear']);

      final again = SpotifyAuthService.connect();
      await tester.pump(_second);
      expect(native.connects, hasLength(2), reason: 'a second native connect next to the hop');
      native.connects[1].complete(true);
      await tester.pump(_second);
      expect(await again, isTrue);
      await tester.pump();
      expect(store.log, ['clear', 'write']);
    }, timeout: _failFast);
  });

  group('a successful connect updates the known connection state', () {
    testWidgets('disconnected -> connected after a flight succeeded', (tester) async {
      final native = _installNative();
      _installStore();
      expect(SpotifyConnectionMonitor.isConnected, isFalse);

      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);
      expect(SpotifyConnectionMonitor.isConnected, isTrue);
    }, timeout: _failFast);

    testWidgets('a failed connect does not claim a connection', (tester) async {
      final native = _installNative();
      _installStore();
      expect(
        await _connectAnswering(
            tester, native, (c) => c.completeError(PlatformException(code: 'x'))),
        isFalse,
      );
      expect(SpotifyConnectionMonitor.isConnected, isFalse);
    }, timeout: _failFast);
  });

  group('disconnectAndForget (deliberate "Verbindung trennen")', () {
    testWidgets('removes the marker, disconnects the SDK once, marks the link as down',
        (tester) async {
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final native = _installNative();
      final store = _installStore(done: true);

      await SpotifyAuthService.disconnectAndForget();

      expect(store.log, ['clear']);
      expect(store.done, isFalse);
      expect(native.count('disconnectFromSpotify'), 1);
      expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);
    }, timeout: _failFast);

    testWidgets('stays bounded when the SDK never answers (marker is cleared first)',
        (tester) async {
      final native = _installNative();
      native.other = (_) => Completer<Object?>().future; // disconnect never answers
      final store = _installStore(done: true);

      bool finished = false;
      final future = SpotifyAuthService.disconnectAndForget().then((_) => finished = true);
      await tester.pump(_second ~/ 2);
      expect(store.done, isFalse, reason: 'forgotten before the SDK call is over');
      expect(finished, isFalse);

      await tester.pump(SpotifyAuthService.disconnectTimeout + _second);
      await future;
      expect(finished, isTrue, reason: 'bounded by the disconnect timeout');
    }, timeout: _failFast);

    testWidgets('SDK errors on disconnect are swallowed; the marker is gone anyway',
        (tester) async {
      final native = _installNative();
      native.other = (_) => Future<Object?>.error(PlatformException(code: 'errorDisconnecting'));
      final store = _installStore(done: true);

      await SpotifyAuthService.disconnectAndForget(); // must not throw
      expect(store.done, isFalse);
    }, timeout: _failFast);

    testWidgets('invalidates a running playback attempt: no reconnect, no retry later',
        (tester) async {
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final native = _installNative();
      native.other = (call) =>
          call.method == 'play' ? Completer<Object?>().future : Future<Object?>.value(true);
      _installStore(done: true);

      bool? result;
      final future = SpotifyAuthService.playTrack(_trackUrl).then((v) => result = v);
      await tester.pump(_second);
      expect(native.calls, ['play']);

      await SpotifyAuthService.disconnectAndForget();
      await tester.pump(_play); // the first play times out
      await future;

      expect(result, isFalse);
      expect(native.count('connectToSpotify'), 0, reason: 'a stale attempt reconnects nothing');
      expect(native.count('play'), 1, reason: 'and retries nothing');
    }, timeout: _failFast);

    testWidgets('ends a running connect at once and ignores its late success',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);

      bool? result;
      final future = SpotifyAuthService.connect().then((v) => result = v);
      await tester.pump(_second);
      expect(result, isNull);

      await SpotifyAuthService.disconnectAndForget();
      await future;
      expect(result, isFalse, reason: 'the pending connect was invalidated');

      native.connects.single.complete(true); // Spotify connects after all ...
      await tester.pump(_second);
      await tester.pump();
      expect(store.log, ['clear'], reason: 'a late success must not write the marker again');
      expect(SpotifyConnectionMonitor.isConnected, isFalse);
      expect(native.count('pause'), 0, reason: 'and must not pause anything');
    }, timeout: _failFast);

    testWidgets('invalidated during the pause phase: the connect fails, no marker is written',
        (tester) async {
      final native = _installNative();
      native.other = (call) =>
          call.method == 'pause' ? Completer<Object?>().future : Future<Object?>.value(true);
      final store = _installStore(done: true);

      bool? result;
      final future = SpotifyAuthService.connect().then((v) => result = v);
      await tester.pump(_second);
      native.connects.single.complete(true); // connected; the pause is pending now
      await tester.pump(const Duration(milliseconds: 500));
      expect(result, isNull);

      await SpotifyAuthService.disconnectAndForget();
      await future;
      expect(result, isFalse);

      await tester.pump(SpotifyAuthService.pauseTimeout + _second); // the pause times out
      await tester.pump();
      expect(store.log, ['clear'], reason: 'the finished setup must not be written afterwards');
      expect(SpotifyConnectionMonitor.isConnected, isFalse);
    }, timeout: _failFast);

    // KNOWN LIMIT, same as after a timeout: the plugin cannot cancel a native connect,
    // so "Verbindung trennen" frees the slot while the native connect may still be
    // pending. The next deliberate connect then runs next to it (documented on
    // SpotifyAuthService.connect).
    testWidgets('KNOWN LIMIT: after the disconnect a new connect runs next to the pending native one',
        (tester) async {
      final native = _installNative();
      _installStore(done: true);

      final first = SpotifyAuthService.connect();
      await tester.pump(_second);
      await SpotifyAuthService.disconnectAndForget();
      expect(await first, isFalse);
      expect(native.connects, hasLength(1), reason: 'the first native connect is still pending');

      final second = SpotifyAuthService.connect();
      await tester.pump(_second);
      expect(native.connects, hasLength(2));

      native.connects[1].complete(true);
      await tester.pump(_second);
      expect(await second, isTrue);
    }, timeout: _failFast);

    testWidgets('a connect started AFTER the disconnect works normally', (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);
      await SpotifyAuthService.disconnectAndForget();
      store.log.clear();

      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);
      expect(store.log, ['write']);
      expect(SpotifyConnectionMonitor.isConnected, isTrue);
    }, timeout: _failFast);
  });

  group('first play is skipped only for a known, current "disconnected"', () {
    testWidgets('known disconnected: connect first, then play', (tester) async {
      final native = _installNative();
      _installStore();
      await SpotifyConnectionMonitor.debugReset(); // fresh process: no connection exists

      bool? result;
      final future = SpotifyAuthService.playTrack(_trackUrl).then((v) => result = v);
      await tester.pump(_second);
      expect(native.calls, ['connectToSpotify'], reason: 'no doomed first play');

      native.connects.single.complete(true);
      await tester.pump(_second);
      await future;
      expect(result, isTrue);
      expect(native.calls, ['connectToSpotify', 'play'],
          reason: 'the reconnect does not pause (the play follows at once)');
    }, timeout: _failFast);

    testWidgets('known disconnected and the connect fails: false, play never called',
        (tester) async {
      final native = _installNative();
      _installStore();

      final future = SpotifyAuthService.playTrack(_trackUrl);
      await tester.pump(_second);
      native.connects.single.completeError(PlatformException(code: 'errorConnection'));
      expect(await future, isFalse);
      expect(native.count('play'), 0);
    }, timeout: _failFast);

    testWidgets('known connected: play goes first, as before', (tester) async {
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final native = _installNative();
      _installStore();

      expect(await SpotifyAuthService.playTrack(_trackUrl), isTrue);
      expect(native.calls, ['play']);
    }, timeout: _failFast);

    testWidgets('a play error alone does not mark the connection as down', (tester) async {
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final native = _installNative();
      native.other = (call) => call.method == 'play'
          ? Future<Object?>.error(PlatformException(code: 'PlayerAPI Error'))
          : Future<Object?>.value(true);
      _installStore();

      final future = SpotifyAuthService.playTrack(_trackUrl);
      await tester.pump(_second);
      native.connects.single.completeError(PlatformException(code: 'errorConnection'));
      expect(await future, isFalse);
      expect(SpotifyConnectionMonitor.isConnected, isTrue,
          reason: 'only events and our own actions change the known state');
    }, timeout: _failFast);
  });

  // A successful connect starts the marker WRITE; a deliberate disconnect can come
  // before that write has finished. Nothing guarantees the order in which the storage
  // finishes its operations, so the service must not rely on it: the last decision wins
  // and "forgotten" is only reported after the stored state was read back.
  group('marker race: a late write cannot re-activate the setup', () {
    testWidgets('the write lands AFTER the clear: the last decision (forget) is applied again',
        (tester) async {
      final native = _installNative();
      final store = _installStore();
      store.writeGate = Completer<void>(); // the write is held back

      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);
      expect(store.log, isEmpty, reason: 'the write has not taken effect yet');

      bool? forgotten;
      final disconnect = SpotifyAuthService.disconnectAndForget().then((v) => forgotten = v);
      await tester.pump(_second);
      expect(store.log, ['clear']);
      expect(forgotten, isNull, reason: 'a write is still pending: nothing is claimed yet');

      store.writeGate!.complete(); // the late write lands now - after the clear
      await tester.pump(_second);
      await disconnect;

      expect(store.done, isFalse, reason: 'the late write must not win');
      expect(store.log, ['clear', 'write', 'clear'], reason: 'the clear was applied again');
      expect(forgotten, isTrue, reason: 'verified by reading the stored state back');
    }, timeout: _failFast);

    testWidgets('a write that never finishes: "forgotten" is not claimed', (tester) async {
      final native = _installNative();
      final store = _installStore()..hangWrites = true;
      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);

      bool? forgotten;
      final disconnect = SpotifyAuthService.disconnectAndForget().then((v) => forgotten = v);
      await tester.pump(SpotifyAuthService.setupMarkerTimeout + _second);
      await disconnect;

      expect(forgotten, isFalse, reason: 'a pending write may still land: not verified');
      expect(store.log, ['clear']);
    }, timeout: _failFast);

    testWidgets('a clear that fails is not reported as forgotten (the marker stays)',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true)..failWith = Exception('disk');
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final attempt = SpotifyAuthService.beginAttempt();

      expect(await SpotifyAuthService.disconnectAndForget(), isFalse);

      expect(store.done, isTrue, reason: 'nothing was removed, and nothing is claimed');
      // Everything else of the deliberate disconnect still happened.
      expect(attempt.isCurrent, isFalse);
      expect(native.count('disconnectFromSpotify'), 1);
      expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);
    }, timeout: _failFast);

    testWidgets('a clear that times out is not reported as forgotten', (tester) async {
      _installNative();
      final store = _installStore(done: true)..hangClears = true;

      bool? forgotten;
      final future = SpotifyAuthService.disconnectAndForget().then((v) => forgotten = v);
      await tester.pump(SpotifyAuthService.setupMarkerTimeout + _second);
      await future;

      expect(forgotten, isFalse);
      expect(store.done, isTrue);
    }, timeout: _failFast);

    testWidgets('a faulty store whose clear changes nothing is caught by the read-back',
        (tester) async {
      _installNative();
      final store = _installStore(done: true)..ignoreClears = true;

      expect(await SpotifyAuthService.disconnectAndForget(), isFalse);
      expect(store.log, ['clear'], reason: 'the clear "worked", the stored state says otherwise');
      expect(store.done, isTrue);
    }, timeout: _failFast);

    // The decision can also flip the other way: while a clear is still on its way the user
    // connects again. The newer decision (remember) wins and nothing is claimed as forgotten.
    testWidgets('a new successful connect during a running forget: the newer decision wins',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);
      store.clearGate = Completer<void>(); // the clear is held back

      bool? forgotten;
      final disconnect = SpotifyAuthService.disconnectAndForget().then((v) => forgotten = v);
      await tester.pump(const Duration(milliseconds: 100)); // the clear is still on its way
      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);

      store.clearGate!.complete(); // the OLD clear lands now and would erase the new setup
      await tester.pump(_second);
      await disconnect;

      expect(store.done, isTrue, reason: 'the newer decision (remember) must win');
      expect(forgotten, isFalse, reason: 'a newer decision exists: not claimed as forgotten');
    }, timeout: _failFast);

    testWidgets('a write that hangs inside a running forget cannot hold the disconnect forever',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);
      store.clearGate = Completer<void>();

      bool? forgotten;
      final disconnect = SpotifyAuthService.disconnectAndForget().then((v) => forgotten = v);
      await tester.pump(const Duration(milliseconds: 100));
      store.hangWrites = true;
      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);

      store.clearGate!.complete(); // the old clear lands; its follow-up write never finishes
      await tester.pump(SpotifyAuthService.setupMarkerTimeout * 3 + _second);
      await disconnect;

      expect(forgotten, isFalse, reason: 'the overall bound ended the wait, nothing is claimed');
    }, timeout: _failFast);

    // KNOWN LIMIT: once the Dart side has given up waiting for a clear (timeout), that clear
    // is still on its way in the storage. If it lands after a LATER successful write it
    // drops the marker silently. Safe direction (the next start shows the Connect screen),
    // and nothing was claimed: the forget that timed out reported "not verified".
    testWidgets('KNOWN LIMIT: a clear that timed out can still land after a newer write',
        (tester) async {
      final native = _installNative();
      final store = _installStore(done: true);
      store.clearGate = Completer<void>();

      bool? forgotten;
      final disconnect = SpotifyAuthService.disconnectAndForget().then((v) => forgotten = v);
      await tester.pump(SpotifyAuthService.setupMarkerTimeout + _second); // Dart gave up
      await disconnect;
      expect(forgotten, isFalse, reason: 'the timed-out forget claims nothing');

      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);
      expect(store.done, isTrue, reason: 'the new setup was written');

      store.clearGate!.complete(); // the abandoned clear finally lands
      await tester.pump(_second);
      expect(store.done, isFalse, reason: 'it drops the newer marker: the documented limit');
    }, timeout: _failFast);

    testWidgets('a verified removal is reported as forgotten', (tester) async {
      _installNative();
      final store = _installStore(done: true);

      expect(await SpotifyAuthService.disconnectAndForget(), isTrue);
      expect(store.done, isFalse);
    }, timeout: _failFast);
  });

  // The loop that applies a marker decision gives up after 4 rounds: every decision that
  // arrives while its last operation is still on its way costs one round. If the decisions
  // keep changing, its last operation can be the OPPOSITE of the final decision. The loop
  // must then say "not converged" instead of claiming that the final decision was applied.
  group('marker race: the round limit', () {
    testWidgets('the decision keeps changing: 4 rounds are not enough, nothing is claimed',
        (tester) async {
      final native = _installNative();
      // Every operation lands when the test says so. A read-back that says "not stored"
      // (stale) must not be able to rescue the claim: the loop's own verdict decides.
      final store = _ScriptedStore()..staleRead = false;
      SpotifyAuthService.sessionStore = store;

      // Loop A is the first "forget". Four decision changes follow (remember, forget,
      // remember, forget), each while A's current operation is still pending, so A would
      // need a 5th round that it does not get. Each change starts a loop of its own.
      bool? first;
      final firstForget = SpotifyAuthService.disconnectAndForget().then((v) => first = v);
      await _connectQuickly(tester, native); // decision: remember
      store.land(0);
      await tester.pump(_tick); // A, round 2: write
      final secondForget = SpotifyAuthService.disconnectAndForget(); // decision: forget
      store.land(2);
      await tester.pump(_tick); // A, round 3: clear
      await _connectQuickly(tester, native); // decision: remember
      store.land(4);
      await tester.pump(_tick); // A, round 4: write
      final thirdForget = SpotifyAuthService.disconnectAndForget(); // decision: forget
      expect(
        store.kinds,
        ['clear', 'write', 'write', 'clear', 'clear', 'write', 'write', 'clear'],
        reason: 'A issued the operations 0, 2, 4 and 6; the others belong to the decision changes',
      );

      store.land(6); // A's 4th and last operation lands: a write, but the decision is "forget"
      await tester.pump(_tick);
      await firstForget;

      expect(first, isFalse, reason: 'not converged after 4 rounds: "forgotten" is not claimed');
      expect(store.done, isTrue, reason: 'in reality the marker is stored: a claim would be false');

      // Nothing stays stuck: once the pending operations land, the loops of the later
      // decisions apply the final one (forget) and the last caller gets a verified answer.
      store.staleRead = null; // honest reads again
      store.landAll();
      await tester.pump(_tick);
      await secondForget;
      expect(await thirdForget, isTrue, reason: 'the final decision is verified by its own call');
      expect(store.done, isFalse, reason: 'the final decision (forget) is what ends up stored');
    }, timeout: _failFast);
  });

  // KNOWN LIMIT: the plugin cannot cancel a native connect. If the user disconnects
  // while a hop to Spotify is still pending, that connect can complete later; the
  // plugin connection (and the Spotify side of the hop) can come up. The Dart side must
  // not turn that into more activity.
  group('a late native connect after a deliberate disconnect', () {
    testWidgets('may bring the plugin link up, but Dart plays, pauses, reconnects, remembers nothing',
        (tester) async {
      final events = _StatusEvents();
      SpotifyConnectionMonitor.install();
      await tester.pump();
      final native = _installNative();
      final store = _installStore(done: true);

      final connecting = SpotifyAuthService.connect(); // a hop to Spotify is pending
      await tester.pump(_second);
      expect(await SpotifyAuthService.disconnectAndForget(), isTrue);
      expect(await connecting, isFalse);
      final callsAfterDisconnect = List<String>.of(native.calls);
      expect(callsAfterDisconnect, ['connectToSpotify', 'disconnectFromSpotify']);

      // The user finishes the hop in Spotify anyway: the native connect completes late
      // and the plugin reports the connection.
      native.connects.single.complete(true);
      events.emit('{"connected": true}');
      await tester.pump(const Duration(minutes: 1));

      expect(SpotifyConnectionMonitor.isConnected, isTrue,
          reason: 'the plugin connection IS up: the known state is truthful');
      expect(native.calls, callsAfterDisconnect,
          reason: 'Dart starts no play, pause, connect or disconnect on its own');
      expect(store.log, ['clear'], reason: 'and remembers nothing');
      expect(store.done, isFalse);

      // The next connect is a deliberate one and starts a fresh flight.
      final again = SpotifyAuthService.connect();
      await tester.pump(_second);
      expect(native.count('connectToSpotify'), 2);
      native.connects[1].complete(true);
      await tester.pump(_second);
      expect(await again, isTrue);
    }, timeout: _failFast);
  });

  group('marker I/O is bounded (a hanging store traps nobody)', () {
    testWidgets('a store that never answers a read means "not set up" after the bound',
        (tester) async {
      final store = _installStore(done: true)..hangReads = true;

      bool? result;
      final future = SpotifyAuthService.hasCompletedSetup().then((v) => result = v);
      await tester.pump(SpotifyAuthService.setupMarkerTimeout - _second);
      expect(result, isNull, reason: 'still inside the bound');

      await tester.pump(_second * 2);
      await future;
      expect(result, isFalse);
      expect(store.hangReads, isTrue);
    }, timeout: _failFast);

    testWidgets('a store whose clear hangs cannot hold back the disconnect', (tester) async {
      final native = _installNative();
      _installStore(done: true).hangClears = true;

      bool finished = false;
      bool? forgotten;
      final future = SpotifyAuthService.disconnectAndForget().then((v) {
        finished = true;
        forgotten = v;
      });
      await tester.pump(SpotifyAuthService.setupMarkerTimeout - _second);
      expect(finished, isFalse);

      await tester.pump(_second * 2); // the clear gave up
      await future;
      expect(finished, isTrue);
      expect(forgotten, isFalse, reason: 'the clear timed out: not verified, not claimed');
      expect(native.count('disconnectFromSpotify'), 1, reason: 'the SDK disconnect ran anyway');
    }, timeout: _failFast);

    testWidgets('a store whose write hangs never delays the connect result', (tester) async {
      final native = _installNative();
      final store = _installStore()..hangWrites = true;

      expect(await _connectAnswering(tester, native, (c) => c.complete(true)), isTrue);
      expect(store.log, isEmpty, reason: 'the write is fire-and-forget; nobody waits for it');
    }, timeout: _failFast);
  });

  group('the real store', () {
    test('a refused save or remove is an error, not a silent success', () async {
      SharedPreferencesStorePlatform.instance = _RefusingPlatformStore(<String, Object>{});
      SharedPreferences.resetStatic();
      const store = PrefsSpotifySessionStore();

      await expectLater(store.writeSetupDone(), throwsA(isA<SpotifySessionStoreException>()));
      await expectLater(store.clear(), throwsA(isA<SpotifySessionStoreException>()));
    });

    test('reading reports the really stored state, not the optimistic cache', () async {
      SharedPreferencesStorePlatform.instance = _RefusingPlatformStore(
        <String, Object>{'flutter.${PrefsSpotifySessionStore.key}': true},
      );
      SharedPreferences.resetStatic();
      const store = PrefsSpotifySessionStore();

      // shared_preferences drops the value from its cache first and only then asks the
      // platform, which refuses. The cache says "gone", the storage still has it.
      await expectLater(store.clear(), throwsA(isA<SpotifySessionStoreException>()));
      expect(await store.readSetupDone(), isTrue);
    });

    testWidgets('end to end: a platform that refuses the remove is not reported as forgotten',
        (tester) async {
      SharedPreferencesStorePlatform.instance = _RefusingPlatformStore(
        <String, Object>{'flutter.${PrefsSpotifySessionStore.key}': true},
      );
      SharedPreferences.resetStatic();
      _installNative();

      expect(await SpotifyAuthService.disconnectAndForget(), isFalse);
      expect(await const PrefsSpotifySessionStore().readSetupDone(), isTrue);
    }, timeout: _failFast);

    test('reads false, writes true, clears', () async {
      const store = PrefsSpotifySessionStore();
      expect(await store.readSetupDone(), isFalse);
      await store.writeSetupDone();
      expect(await store.readSetupDone(), isTrue);
      await store.clear();
      expect(await store.readSetupDone(), isFalse);
    });

    test('stores exactly one non-sensitive bool and nothing else', () async {
      await const PrefsSpotifySessionStore().writeSetupDone();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {PrefsSpotifySessionStore.key});
      expect(prefs.get(PrefsSpotifySessionStore.key), true);
    });
  });
}
