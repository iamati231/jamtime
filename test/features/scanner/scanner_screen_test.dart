import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/player_mode/song_mode_screen.dart';
import 'package:jamtime/features/scanner/qr_handler.dart';
import 'package:jamtime/features/scanner/scan_overlay_painter.dart';
import 'package:jamtime/features/scanner/scanner_screen.dart';
import 'package:jamtime/features/scanner/track_whitelist.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

// Regression: on iOS the spotify_sdk plugin can NEVER answer play/pause/connect
// (playerAPI is nil -> no callback). The awaits had no timeout, so ScannerScreen
// stayed in "validDetected" ("Spotify'a baglaniyor...") forever and ignored every
// further scan. SpotifyAuthService now bounds the calls (pause 2s, play 4s,
// connect 15s), so playTrack gives up after ~19s and the screen has to recover.
//
// The tests drive the REAL ScannerScreen + MobileScanner widget + SpotifyAuthService
// and only fake the native side (method/event channels). Time is fake:
// testWidgets + tester.pump(duration).

// ─── Channels (verified in mobile_scanner 7.2.0, ────────────────────────────────
// ─── permission_handler_platform_interface 4.3.0, spotify_sdk 3.0.2) ────────────
const _scannerMethods = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
const _scannerEvents = EventChannel('dev.steenbakker.mobile_scanner/scanner/event');
const _orientationEvents =
    EventChannel('dev.steenbakker.mobile_scanner/scanner/deviceOrientation');
const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
const _sdk = MethodChannel('spotify_sdk');
const _playerState = MethodChannel('player_state_subscription');

// ─── UI texts (ScannerScreen / SongModeScreen) ──────────────────────────────────
const _idleLabel = 'Kartı okutun';
const _connectingLabel = "Spotify'a bağlanıyor...";
const _connectFailedLabel = 'Spotify bağlantısı kurulamadı';
const _notJamTimeLabel = 'Bu bir JamTime QR kodu değil';
const _songModeStopLabel = 'Durdur ve çık';
const _rescanLabel = 'Durdur ve yeniden tara';
const _sameCardLabel = 'Aynı kartı tekrar tara';
const _pauseHint = "Müzik durmamış olabilir. Gerekirse Spotify'dan durdurun.";

// ─── Timing (fake time) ─────────────────────────────────────────────────────────
// playTrack: play (play timeout), then ONE reconnect (reconnect timeout). Both come
// from SpotifyAuthService, so re-tuning them does not break these tests.
const _playTimeout = SpotifyAuthService.playTimeout;
const _connectTimeout = SpotifyAuthService.reconnectTimeout;
final _giveUpAfter = _playTimeout + _connectTimeout;
// Hard-coded in ScannerScreen: failure / "not a JamTime QR" label stays for 3s.
const _labelHold = Duration(seconds: 3);
// mobile_scanner re-emits a code roughly every 250ms while it stays in view.
const _cadence = Duration(milliseconds: 250);
// One frame's worth: lets microtasks (event -> setState -> channel calls) run.
const _tick = Duration(milliseconds: 10);
// AnimatedSwitcher cross-fades labels for 300ms; old and new label coexist until then.
const _fade = Duration(milliseconds: 400);
// A replaced route stays mounted until its page transition (<= 500 ms) is over.
const _transition = Duration(milliseconds: 600);

/// If the old "hangs forever" behaviour comes back, fail in seconds instead of
/// after testWidgets' 10 minute default.
const _failFast = Timeout(Duration(seconds: 10));

/// "Native side never answers" (what the iOS plugin does).
Future<Object?> _silent() => Completer<Object?>().future;

/// A QR code from assets/allowed_tracks.json (picked in setUpAll).
late final String _whitelistedUrl;

/// A second, different whitelisted QR code ("card B").
late final String _otherWhitelistedUrl;

/// Valid https URL that is not a JamTime code.
const _foreignUrl = 'https://example.com/x';

/// Right host, but not a track from the whitelist.
const _unlistedSpotifyUrl = 'https://open.spotify.com/track/0000000000000000000000';

/// mobile_scanner `start` answer as the iOS plugin sends it (darwin/.../
/// MobileScannerPlugin.swift): size already swapped to portrait, torch -1 = none.
const _startResult = <String, Object?>{
  'textureId': 1,
  'size': <String, Object?>{'width': 1080.0, 'height': 1920.0},
  'currentTorchState': -1,
  'cameraDirection': 1, // back
  'initialDeviceOrientation': 'PORTRAIT_UP',
};

/// The fake "native side" of everything ScannerScreen talks to.
class _Device {
  _Device._(this._messenger);

  final TestDefaultBinaryMessenger _messenger;

  /// Every call on the mobile_scanner method channel, in order.
  final List<MethodCall> scannerCalls = <MethodCall>[];

  /// Method names received on the spotify_sdk channel, in order.
  final List<String> sdkCalls = <String>[];

  /// How the fake Spotify SDK answers. Default: never (the iOS bug).
  Future<Object?>? Function(MethodCall call) sdk = (_) => _silent();

  /// True while the Dart side listens to the camera event stream
  /// (EventChannel `listen` ... `cancel`).
  bool cameraEventsAttached = false;

  Iterable<String> get scannerMethods => scannerCalls.map((c) => c.method);

  int sdkCount(String method) => sdkCalls.where((m) => m == method).length;

  int scannerCount(String method) => scannerMethods.where((m) => m == method).length;

  static _Device install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final device = _Device._(messenger);

    // An EventChannel talks to the platform through a MethodChannel of the same name.
    final cameraEvents = MethodChannel(_scannerEvents.name);
    final orientationEvents = MethodChannel(_orientationEvents.name);
    messenger
      ..setMockMethodCallHandler(_permissions, device._onPermissions)
      ..setMockMethodCallHandler(_scannerMethods, device._onScanner)
      ..setMockMethodCallHandler(cameraEvents, device._onCameraEvents)
      ..setMockMethodCallHandler(orientationEvents, (_) async => null)
      ..setMockMethodCallHandler(_sdk, device._onSdk)
      // SongModeScreen subscribes to the player state (EventChannel listen/cancel).
      ..setMockMethodCallHandler(_playerState, (_) async => null);
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(_permissions, null)
        ..setMockMethodCallHandler(_scannerMethods, null)
        ..setMockMethodCallHandler(cameraEvents, null)
        ..setMockMethodCallHandler(orientationEvents, null)
        ..setMockMethodCallHandler(_sdk, null)
        ..setMockMethodCallHandler(_playerState, null);
    });
    return device;
  }

  // permission_handler: Permission.camera == 1, PermissionStatus.granted == 1.
  Future<Object?>? _onPermissions(MethodCall call) async {
    switch (call.method) {
      case 'requestPermissions': // List<int> -> Map<int, int>
        return <int, int>{for (final p in call.arguments as List<Object?>) p! as int: 1};
      case 'checkPermissionStatus': // int -> int
        return 1;
    }
    return null;
  }

  Future<Object?>? _onScanner(MethodCall call) async {
    scannerCalls.add(call);
    switch (call.method) {
      case 'state': // MobileScannerAuthorizationState.authorized
        return 1;
      case 'start':
        return _startResult;
    }
    return null; // stop, updateScanWindow, ...
  }

  Future<Object?>? _onCameraEvents(MethodCall call) async {
    switch (call.method) {
      case 'listen':
        cameraEventsAttached = true;
      case 'cancel':
        cameraEventsAttached = false;
    }
    return null;
  }

  Future<Object?>? _onSdk(MethodCall call) {
    sdkCalls.add(call.method);
    return sdk(call);
  }

  /// The platform reports a detected QR code (what iOS pushes into the camera
  /// event stream). Dropped silently if nobody listens, like the real thing.
  void detect(String rawValue) {
    final event = <String, Object?>{
      'name': 'barcode',
      'data': <Object?>[
        <String, Object?>{
          'rawValue': rawValue,
          'displayValue': rawValue,
          'format': 256, // BarcodeFormat.qrCode
          'type': 8, // BarcodeType.url
        },
      ],
    };
    unawaited(
      _messenger.handlePlatformMessage(
        _scannerEvents.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        null,
      ),
    );
  }
}

/// testWidgets as iOS (where the bug lives; mobile_scanner's `start` answer is
/// platform specific and `flutter test` defaults to Android) with a fail-fast timeout.
void _iosTest(String description, WidgetTesterCallback body) {
  testWidgets(
    description,
    body,
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    timeout: _failFast,
  );
}

/// Phone sized view + ScannerScreen; waits until the camera is running and the
/// overlay (idle label) is on screen.
Future<_Device> _openScanner(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532); // iPhone like, 3x
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final device = _Device.install();
  await tester.pumpWidget(const MaterialApp(home: ScannerScreen()));

  // permission request -> setState -> MobileScanner init (stop(force), state,
  // start) -> rebuild with overlay. No pumpAndSettle: keep the clock under control.
  for (var i = 0; i < 20 && find.text(_idleLabel).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.text(_idleLabel), findsOneWidget, reason: 'scanner did not come up');
  expect(device.cameraEventsAttached, isTrue, reason: 'camera not streaming');
  device.scannerCalls.clear(); // from here on: only what the scan itself causes
  return device;
}

/// Advances fake time, runs due timers/microtasks and builds the frame.
Future<void> _elapse(WidgetTester tester, Duration d) => tester.pump(d);

const _openLabel = 'open scanner';

/// A Home screen with a button that pushes a NEW ScannerScreen, like the real app
/// (phone sized view). Use [_openScannerFromHome] / [_leaveScanner] on top of it.
Future<_Device> _installHome(WidgetTester tester, {NavigatorObserver? observer}) async {
  tester.view.physicalSize = const Size(1170, 2532); // iPhone like, 3x
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final device = _Device.install();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [?observer],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ScannerScreen()),
              ),
              child: const Text(_openLabel),
            ),
          ),
        ),
      ),
    ),
  );
  return device;
}

/// Opens a (new) scanner from Home and waits until its idle label is on screen.
Future<void> _openScannerFromHome(WidgetTester tester) async {
  await tester.tap(find.text(_openLabel));
  for (var i = 0; i < 20 && find.text(_idleLabel).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.text(_idleLabel), findsOneWidget, reason: 'scanner did not come up');
}

/// The user taps the back arrow; waits until the pop transition is over, i.e. the
/// scanner's State is disposed.
Future<void> _leaveScanner(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.arrow_back));
  await _elapse(tester, _tick); // the pop animation starts with this frame
  await _elapse(tester, const Duration(milliseconds: 600));
  expect(find.byType(ScannerScreen), findsNothing);
  expect(find.text(_openLabel), findsOneWidget);
}

/// The Spotify URI the app derives from a QR URL (`open.spotify.com/track/ID`).
String _uriFor(String url) {
  final s = Uri.parse(url).pathSegments;
  return 'spotify:${s[0]}:${s[1]}';
}

String? _playedUri(MethodCall call) =>
    (call.arguments as Map<Object?, Object?>?)?['spotifyUri'] as String?;

/// Counts the routes on the navigator stack (push / pop / replace / remove).
class _RouteCounter extends NavigatorObserver {
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];

  int get depth => _stack.length;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (i >= 0) _stack.removeAt(i);
    if (newRoute != null) _stack.insert(i >= 0 ? i : _stack.length, newRoute);
  }
}

enum _PauseMode { confirm, silent, error }

/// SDK answers for the song-mode flows: `play` always succeeds, `pause` behaves as
/// [pause]. [plays] collects WHICH card was played ('A' / 'B' / '?'), never the URI.
void _answerSdk(_Device device, {_PauseMode pause = _PauseMode.confirm, List<String>? plays}) {
  final uriA = _uriFor(_whitelistedUrl);
  final uriB = _uriFor(_otherWhitelistedUrl);
  device.sdk = (call) {
    switch (call.method) {
      case 'play':
        final uri = _playedUri(call);
        plays?.add(uri == uriA ? 'A' : (uri == uriB ? 'B' : '?'));
        return Future<Object?>.value(true);
      case 'pause':
        switch (pause) {
          case _PauseMode.confirm:
            return Future<Object?>.value(true);
          case _PauseMode.silent:
            return _silent();
          case _PauseMode.error:
            return Future<Object?>.error(PlatformException(code: 'PlayerAPI Error'));
        }
    }
    return Future<Object?>.value(null);
  };
}

/// The user shows [url]; the song mode opens (the play call answers right away).
Future<void> _scanUntilSongMode(WidgetTester tester, _Device device, String url) async {
  device.detect(url);
  await _elapse(tester, _tick);
  await _elapse(tester, const Duration(seconds: 1)); // page transition
  expect(find.text(_songModeStopLabel), findsOneWidget, reason: 'song mode did not open');
}

/// Waits until a scanner is on screen with its camera streaming (e.g. after the
/// song mode replaced itself by a new scanner).
Future<void> _waitForScanner(WidgetTester tester, _Device device) async {
  for (var i = 0;
      i < 30 && !(find.text(_idleLabel).evaluate().isNotEmpty && device.cameraEventsAttached);
      i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.text(_idleLabel), findsOneWidget, reason: 'scanner not ready');
  expect(device.cameraEventsAttached, isTrue, reason: 'camera not streaming');
}

/// Colour of the scan frame. Unlike the label it flips with the state at once
/// (no cross-fade): red = invalid / failure, anything else = idle or connecting.
Color _frameColor(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ScanOverlayPainter),
  );
  return (paint.painter! as ScanOverlayPainter).borderColor;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await TrackWhitelist.load();
    final json = jsonDecode(await rootBundle.loadString('assets/allowed_tracks.json'))
        as Map<String, dynamic>;
    final urls = (json['allowed_urls'] as List<dynamic>).cast<String>();
    _whitelistedUrl = urls[0];
    _otherWhitelistedUrl = urls[1];
    expect(QrHandler.isAllowed(_whitelistedUrl), isTrue,
        reason: 'fixture precondition: first asset URL must be accepted');
    expect(QrHandler.isAllowed(_otherWhitelistedUrl), isTrue);
    expect(_otherWhitelistedUrl, isNot(_whitelistedUrl));
    expect(QrHandler.isAllowed(_foreignUrl), isFalse);
    expect(QrHandler.isAllowed(_unlistedSpotifyUrl), isFalse,
        reason: 'fixture precondition: placeholder track must not be whitelisted');
  });

  group('whitelisted QR, Spotify SDK never answers (iOS bug)', () {
    _iosTest('recovers: failure label after ~19s, idle 3s later, camera restarted',
        (tester) async {
      final device = await _openScanner(tester);

      device.detect(_whitelistedUrl);
      await _elapse(tester, _tick);

      // Scanner is stopped first, then Spotify is asked to play.
      expect(find.text(_connectingLabel), findsOneWidget);
      expect(device.scannerMethods, ['stop']);
      expect(device.sdkCalls, ['play']);

      // Inside the play timeout: still waiting.
      await _elapse(tester, _playTimeout - const Duration(seconds: 1));
      expect(find.text(_connectingLabel), findsOneWidget);
      expect(device.sdkCalls, ['play']);

      // Play timed out -> exactly one reconnect; still waiting for it.
      await _elapse(tester, const Duration(seconds: 2));
      expect(find.text(_connectingLabel), findsOneWidget);
      expect(device.sdkCalls, ['play', 'connectToSpotify']);

      // Just before the reconnect gives up: still connecting.
      await _elapse(tester, _giveUpAfter - _playTimeout - const Duration(seconds: 2));
      expect(find.text(_connectingLabel), findsOneWidget);

      // Past ~19s: playTrack returned false -> failure label (no second play).
      await _elapse(tester, const Duration(seconds: 2));
      expect(find.text(_connectFailedLabel), findsOneWidget);
      await _elapse(tester, _fade);
      expect(find.text(_connectingLabel), findsNothing);
      expect(device.sdkCalls, ['play', 'connectToSpotify']);
      expect(device.cameraEventsAttached, isFalse, reason: 'camera still stopped');

      // 3s later: back to idle AND the scanner was restarted.
      await _elapse(tester, _labelHold);
      await _elapse(tester, _fade);
      expect(find.text(_idleLabel), findsOneWidget);
      expect(find.text(_connectFailedLabel), findsNothing);
      expect(device.scannerMethods, containsAllInOrder(<String>['stop', 'start']));
      expect(device.cameraEventsAttached, isTrue, reason: 'camera streaming again');
      expect(device.sdkCalls, ['play', 'connectToSpotify'],
          reason: 'no SDK traffic on restart');
    });

    _iosTest('after recovering, the next scan is accepted again', (tester) async {
      final device = await _openScanner(tester);

      device.detect(_whitelistedUrl);
      await _elapse(tester, _giveUpAfter + _labelHold + const Duration(seconds: 1));
      await _elapse(tester, _fade);
      expect(find.text(_idleLabel), findsOneWidget, reason: 'did not recover');

      // Spotify is reachable now. The user holds the card up again.
      device.sdk = (call) async => call.method == 'play' ? true : null;
      device.detect(_whitelistedUrl);
      await _elapse(tester, _tick);
      await _elapse(tester, const Duration(seconds: 1)); // page transition

      expect(device.sdkCount('play'), 2, reason: 'second scan reached Spotify');
      expect(find.text(_songModeStopLabel), findsOneWidget);
      expect(find.byType(ScannerScreen), findsNothing);
    });

    _iosTest('the same QR re-emitted every 250ms causes exactly one play call until recovery',
        (tester) async {
      final device = await _openScanner(tester);

      // First a burst inside one event-loop turn (in flight when the camera stops) ...
      for (var i = 0; i < 3; i++) {
        device.detect(_whitelistedUrl);
      }
      await _elapse(tester, _tick);
      expect(find.text(_connectingLabel), findsOneWidget);

      // ... then the steady 250ms cadence while the card stays in view, through
      // connecting (0-19s) and the failure label (19-22s), up to just before recovery.
      final busyUntil = _giveUpAfter + _labelHold - const Duration(seconds: 1);
      for (var t = _tick; t < busyUntil; t += _cadence) {
        device.detect(_whitelistedUrl);
        await _elapse(tester, _cadence);
      }
      expect(find.text(_connectFailedLabel), findsOneWidget,
          reason: 'still inside the failure window');
      expect(device.sdkCount('play'), 1, reason: 'repeats must not start another play');
      expect(device.sdkCount('connectToSpotify'), 1, reason: 'one reconnect only');
      expect(device.scannerMethods, ['stop'], reason: 'camera stays stopped meanwhile');

      // Recovery still happens exactly once.
      await _elapse(tester, const Duration(seconds: 2));
      await _elapse(tester, _fade);
      expect(find.text(_idleLabel), findsOneWidget);
      expect(device.sdkCalls, ['play', 'connectToSpotify']);
      expect(device.scannerMethods, containsAllInOrder(<String>['stop', 'start']));
      expect(device.scannerCount('stop'), 1);
      expect(device.scannerCount('start'), 1);
    });

    // playTrack cannot be cancelled: leaving the screen while it is still running
    // must neither crash (setState / Navigator after dispose) nor open the song
    // mode when the result arrives later.
    _iosTest('leaving while connecting: a late result is ignored', (tester) async {
      final device = await _installHome(tester);
      final slowPlay = Completer<Object?>();
      device.sdk = (call) => call.method == 'play' ? slowPlay.future : _silent();
      await _openScannerFromHome(tester);

      device.detect(_whitelistedUrl);
      await _elapse(tester, _tick);
      expect(find.text(_connectingLabel), findsOneWidget);

      // The user taps the back arrow while Spotify is still being asked.
      await _leaveScanner(tester);

      // Spotify answers late with success: the screen is gone, nothing may happen.
      slowPlay.complete(true);
      await _elapse(tester, _tick);
      expect(find.text(_openLabel), findsOneWidget, reason: 'no navigation after leaving');
      expect(find.text(_songModeStopLabel), findsNothing);

      // ... and nothing blows up when the other timers run out.
      await _elapse(tester, _giveUpAfter + _labelHold);
      expect(find.text(_openLabel), findsOneWidget);
    });

    // Generation guard (see also the 'attempt guard' group in
    // spotify_auth_service_test.dart): the stuck screen is closed, so its attempt A
    // is cancelled and must not reconnect or retry later.
    _iosTest('scan A waits, scanner closed: A starts no reconnect or retry', (tester) async {
      final device = await _installHome(tester); // every SDK call stays silent
      await _openScannerFromHome(tester);

      device.detect(_whitelistedUrl);
      await _elapse(tester, _tick);
      expect(device.sdkCalls, ['play']);

      await _elapse(tester, const Duration(seconds: 1));
      await _leaveScanner(tester); // dispose cancels A's attempt

      await _elapse(tester, _giveUpAfter + _labelHold); // A's play times out, and more
      expect(device.sdkCalls, ['play'], reason: 'closed scanner: no reconnect, no retry');
    });

    // The realistic "escape from the hang": scan A hangs, the user goes back, opens
    // the scanner again and scans card B, which plays. A's reconnect that is already
    // in flight then returns late: it must NOT play A over B.
    _iosTest('a late reconnect of A does not replace B with play(A)', (tester) async {
      final device = await _installHome(tester);
      final uriA = _uriFor(_whitelistedUrl);
      final uriB = _uriFor(_otherWhitelistedUrl);
      final plays = <String>[];
      final connectA = Completer<Object?>();
      device.sdk = (call) {
        switch (call.method) {
          case 'play':
            final uri = _playedUri(call);
            plays.add(uri == uriA ? 'A' : (uri == uriB ? 'B' : '?'));
            return uri == uriA ? _silent() : Future<Object?>.value(true);
          case 'connectToSpotify':
            return connectA.future; // A's reconnect, still pending
        }
        return Future<Object?>.value(null);
      };

      await _openScannerFromHome(tester);
      device.detect(_whitelistedUrl); // scan A: first play times out, reconnect in flight
      await _elapse(tester, _tick);
      await _elapse(tester, _playTimeout + const Duration(seconds: 1));
      expect(device.sdkCalls, ['play', 'connectToSpotify']);

      await _leaveScanner(tester);
      await _openScannerFromHome(tester);
      device.detect(_otherWhitelistedUrl); // scan B plays right away
      await _elapse(tester, _tick);
      await _elapse(tester, const Duration(seconds: 1)); // page transition
      expect(find.text(_songModeStopLabel), findsOneWidget, reason: 'B is playing');
      expect(plays, ['A', 'B']);

      connectA.complete(true); // A's reconnect finally returns
      await _elapse(tester, _tick);
      await _elapse(tester, const Duration(seconds: 1));
      expect(plays, ['A', 'B'], reason: 'no play(A) over B');
    });

    // The old screen is disposed AFTER B has started (route transition: both are
    // mounted for a moment) while B is still waiting. The dispose may only cancel
    // A, so B must still reconnect and retry.
    _iosTest('disposing the old scanner does not invalidate B', (tester) async {
      final device = await _installHome(tester);
      var plays = 0;
      device.sdk = (call) {
        switch (call.method) {
          case 'play':
            // A's and B's FIRST play stay silent; B's retry (3rd play) answers.
            return ++plays >= 3 ? Future<Object?>.value(true) : _silent();
          case 'connectToSpotify':
            return Future<Object?>.value(true);
        }
        return Future<Object?>.value(null);
      };

      await _openScannerFromHome(tester);
      device.detect(_whitelistedUrl); // scan A: the camera stops, A waits
      await _elapse(tester, _tick);
      expect(device.sdkCalls, ['play']);

      // Open the next scanner IN PLACE of the first one: the old screen stays mounted
      // until the transition ends, so B starts before A's dispose.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const ScannerScreen()),
      ));
      await tester.pump(); // builds the replacing route
      // Scanner A stopped its camera after the scan; wait until the NEW one streams.
      for (var i = 0; i < 20 && !device.cameraEventsAttached; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(device.cameraEventsAttached, isTrue, reason: 'new scanner not streaming');
      expect(find.byType(ScannerScreen), findsNWidgets(2),
          reason: 'old and new scanner are mounted together');
      device.detect(_otherWhitelistedUrl); // scan B
      await _elapse(tester, _tick);
      expect(device.sdkCalls, ['play', 'play']);

      await _elapse(tester, const Duration(seconds: 1)); // transition over: OLD scanner disposed
      expect(find.byType(ScannerScreen), findsOneWidget);

      await _elapse(tester, _playTimeout); // both first plays time out
      await _elapse(tester, _tick);
      expect(device.sdkCalls.where((m) => m == 'connectToSpotify'), hasLength(1),
          reason: 'only B reconnects (A is stale); the dispose must not have cancelled B');

      await _elapse(tester, const Duration(seconds: 1)); // B's retry plays, song mode opens
      expect(find.text(_songModeStopLabel), findsOneWidget);
    });
  });

  group('whitelisted QR, Spotify SDK answers', () {
    _iosTest('play answers -> SongModeScreen replaces the scanner', (tester) async {
      final device = await _openScanner(tester);
      device.sdk = (call) async => call.method == 'play' ? true : null;

      device.detect(_whitelistedUrl);
      await _elapse(tester, _tick);
      await _elapse(tester, const Duration(seconds: 1)); // page transition

      expect(find.text(_songModeStopLabel), findsOneWidget);
      expect(find.byType(ScannerScreen), findsNothing);
      expect(device.sdkCalls, ['play'], reason: 'no reconnect when play works');
    });
  });

  group('other QR codes', () {
    final foreign = <String, String>{
      'https URL that is not a JamTime code': _foreignUrl,
      'Spotify URL that is not on the whitelist': _unlistedSpotifyUrl,
    };
    for (final entry in foreign.entries) {
      _iosTest('${entry.key}: hint for 3s, then idle, Spotify is never called',
          (tester) async {
        final device = await _openScanner(tester);

        device.detect(entry.value);
        await _elapse(tester, _tick);
        expect(find.text(_notJamTimeLabel), findsOneWidget);
        expect(find.text(_connectingLabel), findsNothing);

        await _elapse(tester, const Duration(seconds: 2));
        expect(find.text(_notJamTimeLabel), findsOneWidget, reason: 'hint lasts 3s');

        await _elapse(tester, const Duration(seconds: 1) + _tick); // 3s are up
        await _elapse(tester, _fade); // let the cross-fade finish
        expect(find.text(_idleLabel), findsOneWidget);
        expect(find.text(_notJamTimeLabel), findsNothing);
        expect(device.sdkCalls, isEmpty);
      });
    }

    // The camera keeps running in this branch, so every re-emitted frame really
    // reaches _onQrDetected; only the `_scanState != idle` guard stops a repeat from
    // restarting the 3s hint (its stale timer would otherwise flip the screen back to
    // idle early and make the hint flicker).
    _iosTest('a foreign QR that stays in view keeps full 3s hints (repeats are ignored)',
        (tester) async {
      final device = await _openScanner(tester);

      // 9s of the card staying in view; note when the screen is back to idle.
      final idleAt = <Duration>[];
      var now = Duration.zero;
      for (var i = 0; i < 9 * 4; i++) {
        device.detect(_foreignUrl);
        await _elapse(tester, _cadence);
        now += _cadence;
        if (_frameColor(tester) != Colors.redAccent) idleAt.add(now);
      }

      expect(idleAt.length, greaterThanOrEqualTo(2), reason: 'hint cycles while in view');
      for (var i = 1; i < idleAt.length; i++) {
        expect(idleAt[i] - idleAt[i - 1], greaterThanOrEqualTo(_labelHold - _cadence),
            reason: 'idle at ${idleAt[i - 1]} and again at ${idleAt[i]}: a repeat '
                'shortened the hint');
      }
      expect(device.sdkCalls, isEmpty);
    });

    final ignored = <String, String>{
      'plain text': 'hello world',
      'http (not https) URL': 'http://open.spotify.com/track/abc123',
    };
    for (final entry in ignored.entries) {
      _iosTest('${entry.key} is ignored silently', (tester) async {
        final device = await _openScanner(tester);

        device.detect(entry.value);
        await _elapse(tester, _tick);
        await _elapse(tester, _fade);

        expect(find.text(_idleLabel), findsOneWidget);
        expect(find.text(_notJamTimeLabel), findsNothing);
        expect(find.text(_connectingLabel), findsNothing);
        expect(device.sdkCalls, isEmpty);
        expect(device.scannerMethods, isEmpty, reason: 'camera keeps scanning');
      });
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Song mode: "Durdur ve yeniden tara" replaces the song mode by a new scanner.
  // ─────────────────────────────────────────────────────────────────────────────
  group('song mode: stop and re-scan', () {
    _iosTest('pause confirmed: a ready scanner replaces the song mode, no hint',
        (tester) async {
      final routes = _RouteCounter();
      final device = await _installHome(tester, observer: routes);
      _answerSdk(device);
      await _openScannerFromHome(tester);
      expect(routes.depth, 2, reason: 'Home + scanner');

      await _scanUntilSongMode(tester, device, _whitelistedUrl);
      expect(routes.depth, 2, reason: 'Home + song mode (replaced, not stacked)');

      await tester.tap(find.text(_rescanLabel));
      await _elapse(tester, _tick);
      await _waitForScanner(tester, device);
      await _elapse(tester, _transition); // the old song mode is disposed now

      expect(find.byType(ScannerScreen), findsOneWidget);
      expect(find.byType(SongModeScreen), findsNothing);
      expect(find.text(_pauseHint), findsNothing);
      expect(device.sdkCalls.where((m) => m == 'pause'), hasLength(1));
      expect(routes.depth, 2, reason: 'Home + the new scanner');
    });

    for (final mode in [_PauseMode.silent, _PauseMode.error]) {
      _iosTest('pause ${mode.name}: the scanner still opens and the hint is visible there',
          (tester) async {
        final device = await _installHome(tester);
        _answerSdk(device, pause: mode);
        await _openScannerFromHome(tester);
        await _scanUntilSongMode(tester, device, _whitelistedUrl);

        await tester.tap(find.text(_rescanLabel));
        await _elapse(tester, _tick);
        if (mode == _PauseMode.silent) {
          // Inside the pause timeout nothing is claimed and nothing is left yet.
          await _elapse(tester, SpotifyAuthService.pauseTimeout - const Duration(seconds: 1));
          expect(find.byType(SongModeScreen), findsOneWidget);
          expect(find.text(_pauseHint), findsNothing);
          await _elapse(tester, const Duration(seconds: 2)); // pause timed out
        }
        await _waitForScanner(tester, device);
        await _elapse(tester, _transition); // old song mode disposed, snack bar settled

        expect(find.byType(SongModeScreen), findsNothing);
        expect(find.byType(ScannerScreen), findsOneWidget);
        expect(find.text(_pauseHint), findsOneWidget, reason: 'visible on the target page');
      });
    }

    _iosTest('shared guard: double tap, other action and back gesture give one pause, one navigation',
        (tester) async {
      final routes = _RouteCounter();
      final device = await _installHome(tester, observer: routes);
      _answerSdk(device, pause: _PauseMode.silent); // keeps the guarded window open
      await _openScannerFromHome(tester);
      await _scanUntilSongMode(tester, device, _whitelistedUrl);

      await tester.tap(find.text(_rescanLabel));
      await _elapse(tester, _tick);
      await tester.tap(find.text(_rescanLabel)); // double tap
      await tester.tap(find.text(_songModeStopLabel)); // the other action
      await tester.binding.handlePopRoute(); // back gesture
      await _elapse(tester, _tick);
      expect(device.sdkCalls.where((m) => m == 'pause'), hasLength(1));

      await _elapse(tester, SpotifyAuthService.pauseTimeout + const Duration(seconds: 1));
      await _waitForScanner(tester, device);
      expect(device.sdkCalls.where((m) => m == 'pause'), hasLength(1));
      expect(find.byType(ScannerScreen), findsOneWidget, reason: 'the first action (re-scan) wins');
      expect(find.text(_openLabel), findsNothing, reason: 'no second navigation to Home');
      expect(routes.depth, 2);
    });

    _iosTest('several rounds: constant stack depth, one camera session and one play per round',
        (tester) async {
      final routes = _RouteCounter();
      final device = await _installHome(tester, observer: routes);
      final plays = <String>[];
      _answerSdk(device, plays: plays);
      await _openScannerFromHome(tester);

      for (var round = 0; round < 4; round++) {
        final startsBefore = device.scannerCount('start');
        expect(find.byType(MobileScanner), findsOneWidget, reason: 'round $round: one camera widget');
        await _scanUntilSongMode(
            tester, device, round.isEven ? _whitelistedUrl : _otherWhitelistedUrl);
        expect(find.byType(MobileScanner), findsNothing, reason: 'no camera in the song mode');
        expect(device.cameraEventsAttached, isFalse, reason: 'camera stopped during the song');
        expect(routes.depth, 2, reason: 'round $round: Home + song mode');

        await tester.tap(find.text(_rescanLabel));
        await _elapse(tester, _tick);
        await _waitForScanner(tester, device);
        expect(find.byType(MobileScanner), findsOneWidget);
        expect(find.byType(ScannerScreen), findsOneWidget);
        expect(device.scannerCount('start') - startsBefore, 1,
            reason: 'round $round: exactly one camera start');
        expect(routes.depth, 2, reason: 'round $round: Home + scanner');
      }
      expect(plays, ['A', 'B', 'A', 'B'], reason: 'exactly one play per round');
      expect(device.sdkCalls.where((m) => m == 'pause'), hasLength(4));
    });

    _iosTest('the pause hint does not linger into the next song mode', (tester) async {
      final device = await _installHome(tester);
      _answerSdk(device, pause: _PauseMode.error);
      await _openScannerFromHome(tester);
      await _scanUntilSongMode(tester, device, _whitelistedUrl);
      await tester.tap(find.text(_rescanLabel));
      await _elapse(tester, _tick);
      await _waitForScanner(tester, device);
      await _elapse(tester, _transition);
      expect(find.text(_pauseHint), findsOneWidget);

      await _scanUntilSongMode(tester, device, _otherWhitelistedUrl); // another card
      expect(find.text(_pauseHint), findsNothing, reason: 'stale warning must be gone');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Re-scan lock. mobile_scanner (7.2.0) re-reports a visible code every >=250 ms
  // but sends NOTHING when a frame has no (or an undecodable) code, so missing
  // callbacks cannot be read as "card removed". The just-played card is therefore
  // locked until the user asks for it explicitly; any other valid card plays at once.
  // ─────────────────────────────────────────────────────────────────────────────
  group('re-scan: just-played card lock', () {
    /// Card A plays, then "Durdur ve yeniden tara": the new scanner is locked on A.
    Future<_Device> rescanAfterPlayingA(WidgetTester tester, {List<String>? plays}) async {
      final device = await _installHome(tester);
      _answerSdk(device, plays: plays);
      await _openScannerFromHome(tester);
      await _scanUntilSongMode(tester, device, _whitelistedUrl);
      await tester.tap(find.text(_rescanLabel));
      await _elapse(tester, _tick);
      await _waitForScanner(tester, device);
      return device;
    }

    _iosTest('card A seen again: not played again, explicit action offered',
        (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      expect(plays, ['A']);
      expect(find.text(_sameCardLabel), findsNothing,
          reason: 'the locked card was not seen yet: nothing to offer');

      device.detect(_whitelistedUrl);
      await _elapse(tester, _cadence);
      expect(find.text(_sameCardLabel), findsOneWidget,
          reason: 'the locked card was seen again');

      for (var i = 0; i < 20; i++) {
        // 5 s of the card staying in view, reported every 250 ms
        device.detect(_whitelistedUrl);
        await _elapse(tester, _cadence);
      }
      expect(plays, ['A'], reason: 'the locked card must not start again');
      expect(find.byType(ScannerScreen), findsOneWidget);
      expect(find.text(_idleLabel), findsOneWidget);
      expect(find.text(_sameCardLabel), findsOneWidget);
    });

    // The action is offered only after the locked card was really seen again.
    // Silence, other codes or the mere passing of time never show it, and silence
    // never withdraws it either (the scanner cannot tell that a card was removed).
    _iosTest('no offer without a detection, not even after a long silence', (tester) async {
      final plays = <String>[];
      await rescanAfterPlayingA(tester, plays: plays);
      expect(find.text(_sameCardLabel), findsNothing);

      await _elapse(tester, const Duration(minutes: 2)); // no callbacks at all
      expect(find.text(_sameCardLabel), findsNothing, reason: 'time alone offers nothing');
      expect(plays, ['A']);
    });

    _iosTest('only the locked card itself triggers the offer, other codes do not',
        (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);

      device.detect(_foreignUrl); // valid https, but not a JamTime card
      await _elapse(tester, _tick);
      expect(find.text(_notJamTimeLabel), findsOneWidget);
      expect(find.text(_sameCardLabel), findsNothing);
      await _elapse(tester, _labelHold + _fade);

      device.detect(_unlistedSpotifyUrl); // right host, not on the whitelist
      await _elapse(tester, _tick);
      await _elapse(tester, _labelHold + _fade);

      device.detect('just some text'); // not even a URL
      await _elapse(tester, _cadence);

      expect(find.text(_idleLabel), findsOneWidget);
      expect(find.text(_sameCardLabel), findsNothing);
      expect(plays, ['A']);
    });

    _iosTest('once offered, the action stays while nothing else happens (no timer)',
        (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      device.detect(_whitelistedUrl);
      await _elapse(tester, _cadence);
      expect(find.text(_sameCardLabel), findsOneWidget);

      await _elapse(tester, const Duration(minutes: 1)); // no callbacks at all
      expect(find.text(_sameCardLabel), findsOneWidget, reason: 'silence does not withdraw it');
      expect(plays, ['A'], reason: 'and the lock is still in place');
    });

    _iosTest('a "not a JamTime QR" label hides the offer while it is shown, then it is back',
        (tester) async {
      final device = await rescanAfterPlayingA(tester);
      device.detect(_whitelistedUrl);
      await _elapse(tester, _cadence);
      expect(find.text(_sameCardLabel), findsOneWidget);

      device.detect(_foreignUrl);
      await _elapse(tester, _tick);
      expect(find.text(_notJamTimeLabel), findsOneWidget);
      expect(find.text(_sameCardLabel), findsNothing, reason: 'only while the scanner is idle');

      await _elapse(tester, _labelHold + _fade);
      expect(find.text(_idleLabel), findsOneWidget);
      expect(find.text(_sameCardLabel), findsOneWidget, reason: 'the sighting still counts');
    });

    // Another card is accepted: the earlier sighting of the locked card is history.
    // If that card then fails, the offer must not pop up again by itself.
    _iosTest('after another card was tried, the offer needs a new sighting of the locked card',
        (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      device.detect(_whitelistedUrl);
      await _elapse(tester, _cadence);
      expect(find.text(_sameCardLabel), findsOneWidget);

      device.sdk = (_) => _silent(); // Spotify stops answering: card B cannot play
      device.detect(_otherWhitelistedUrl);
      await _elapse(tester, _tick);
      expect(find.text(_connectingLabel), findsOneWidget);
      expect(find.text(_sameCardLabel), findsNothing);

      await _elapse(tester, _giveUpAfter + _labelHold + const Duration(seconds: 1));
      await _elapse(tester, _fade);
      expect(find.text(_idleLabel), findsOneWidget, reason: 'recovered');
      expect(find.text(_sameCardLabel), findsNothing, reason: 'the old sighting is gone');

      device.detect(_whitelistedUrl); // the locked card shows up again
      await _elapse(tester, _cadence);
      expect(find.text(_sameCardLabel), findsOneWidget);
    });

    _iosTest('a long silence is NOT read as "card removed"', (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      device.detect(_whitelistedUrl);
      await _elapse(tester, _cadence);

      await _elapse(tester, const Duration(seconds: 30)); // no callbacks at all
      device.detect(_whitelistedUrl); // the same card reappears (or never left)
      await _elapse(tester, _tick);
      await _elapse(tester, const Duration(seconds: 1));

      expect(plays, ['A'], reason: 'still locked after a long gap in the callbacks');
      expect(find.byType(ScannerScreen), findsOneWidget);
    });

    _iosTest('another valid card plays immediately while the lock is active',
        (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      for (var i = 0; i < 3; i++) {
        device.detect(_whitelistedUrl);
        await _elapse(tester, _cadence);
      }
      expect(plays, ['A']);

      await _scanUntilSongMode(tester, device, _otherWhitelistedUrl);
      expect(plays, ['A', 'B']);
    });

    _iosTest('"Aynı kartı tekrar tara" releases the lock: the next detection plays the card',
        (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      device.detect(_whitelistedUrl);
      await _elapse(tester, _cadence);
      expect(plays, ['A']);

      await tester.tap(find.text(_sameCardLabel));
      await _elapse(tester, _tick);
      expect(find.text(_sameCardLabel), findsNothing, reason: 'lock released, action gone');

      await _scanUntilSongMode(tester, device, _whitelistedUrl);
      expect(plays, ['A', 'A'], reason: 'the same card plays on purpose');
    });

    _iosTest('a scanner opened from Home has no lock and offers no extra action',
        (tester) async {
      final plays = <String>[];
      final device = await _installHome(tester);
      _answerSdk(device, plays: plays);
      await _openScannerFromHome(tester);
      expect(find.text(_sameCardLabel), findsNothing);

      await _scanUntilSongMode(tester, device, _whitelistedUrl);
      expect(plays, ['A']);
    });

    _iosTest('only the card that played last is locked', (tester) async {
      final plays = <String>[];
      final device = await rescanAfterPlayingA(tester, plays: plays);
      await _scanUntilSongMode(tester, device, _otherWhitelistedUrl); // B plays
      await tester.tap(find.text(_rescanLabel));
      await _elapse(tester, _tick);
      await _waitForScanner(tester, device); // now locked on B

      await _scanUntilSongMode(tester, device, _whitelistedUrl); // A is free again
      expect(plays, ['A', 'B', 'A']);
    });

    _iosTest('logs never contain QR contents', (tester) async {
      final lines = <String>[];
      final original = debugPrint;
      // flutter_test checks debugPrint BEFORE the tear-downs run: restore it here.
      debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
      try {
        final device = await rescanAfterPlayingA(tester);
        for (var i = 0; i < 6; i++) {
          device.detect(_whitelistedUrl); // ignored, locked
          await _elapse(tester, _cadence);
        }
        await tester.tap(find.text(_sameCardLabel));
        await _elapse(tester, _tick);
        await _scanUntilSongMode(tester, device, _whitelistedUrl);
      } finally {
        debugPrint = original;
      }

      final idA = Uri.parse(_whitelistedUrl).pathSegments.last;
      expect(lines, isNotEmpty, reason: 'the diagnostics did log something');
      for (final line in lines) {
        expect(line, isNot(contains(idA)));
        expect(line, isNot(contains('open.spotify.com')));
        expect(line, isNot(contains('spotify:track')));
      }

      // The measurement lines exist and carry numbers / state names only.
      final stats = RegExp(r'lock stats \(released\) hits=6 gaps\(ms\) min=\d+ max=\d+ avg=\d+$');
      expect(lines.where(stats.hasMatch), hasLength(1),
          reason: 'detection cadence of the locked card, numbers only');
      final accepted = RegExp(
          r'scan accepted lastConn=\w+\([^)]*\) lastLifecycle=\S+\([^)]*\)$');
      expect(lines.where(accepted.hasMatch), isNotEmpty,
          reason: 'known connection state + age at every accepted scan');
    });
  });
}
