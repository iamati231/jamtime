import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/player_mode/song_mode_screen.dart';

// Regression: "Durdur ve çık" wartete auf SpotifySdk.pause(), BEVOR der Screen
// verlassen wurde. Antwortet das iOS-Plugin nie (kein Callback), blieb man fuer
// immer im Song-Mode (PopScope(canPop: false) blockt auch die Zurueck-Geste), und
// jedes weitere Tippen stapelte einen neuen haengenden pause()-Aufruf.

const _sdk = MethodChannel('spotify_sdk');
const _playerState = MethodChannel('player_state_subscription');
const _stopLabel = 'Durdur ve çık';
const _rescanLabel = 'Durdur ve yeniden tara';
const _hint = "Müzik durmamış olabilir. Gerekirse Spotify'dan durdurun.";
const _rootLabel = 'open song mode';

/// Fake-Zeit, nach der ein stummes pause() sicher ins Timeout gelaufen ist.
/// Kommt aus dem Service, damit das spaetere Tunen die Tests nicht bricht.
final _afterPauseTimeout =
    SpotifyAuthService.pauseTimeout + const Duration(seconds: 1);

/// Future, das nie abgeschlossen wird = "native Seite antwortet nicht".
Future<Object?> _silent() => Completer<Object?>().future;

/// Mockt spotify_sdk (+ den EventChannel fuer den Player-State) und liefert die
/// Liste der eingegangenen SDK-Methodenaufrufe.
List<String> _mockSdk(Future<Object?>? Function(MethodCall call) onCall) {
  final calls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_sdk, (call) {
    calls.add(call.method);
    return onCall(call);
  });
  // SongModeScreen abonniert den Player-State (EventChannel 'listen'/'cancel').
  messenger.setMockMethodCallHandler(_playerState, (call) async => null);
  addTearDown(() {
    messenger.setMockMethodCallHandler(_sdk, null);
    messenger.setMockMethodCallHandler(_playerState, null);
  });
  return calls;
}

int _pauseCount(List<String> calls) => calls.where((c) => c == 'pause').length;

/// Oeffnet den SongModeScreen ueber einem Root-Screen (wie HomeScreen im echten
/// Ablauf), damit "Rueckkehr" pruefbar ist.
Future<void> _openSongMode(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532); // iPhone-aehnlich, 3x
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SongModeScreen()),
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
  // Kein pumpAndSettle: der Puls-Controller wiederholt sich endlos.
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.text(_stopLabel), findsOneWidget);
}

void main() {
  testWidgets('double tap on stop pauses once and still leaves when the SDK is silent',
      (tester) async {
    final calls = _mockSdk((call) => _silent());
    await _openSongMode(tester);

    await tester.tap(find.text(_stopLabel));
    await tester.pump();
    await tester.tap(find.text(_stopLabel));
    await tester.pump();

    expect(_pauseCount(calls), 1, reason: 'second tap must be ignored');
    expect(find.text(_stopLabel), findsOneWidget,
        reason: 'still inside the pause timeout');

    await tester.pump(_afterPauseTimeout);
    await tester.pump(const Duration(milliseconds: 500)); // pop transition

    expect(find.text(_stopLabel), findsNothing);
    expect(find.text(_rootLabel), findsOneWidget);
    expect(_pauseCount(calls), 1);
  });

  testWidgets('system back while already stopping does not pause again',
      (tester) async {
    final calls = _mockSdk((call) => _silent());
    await _openSongMode(tester);

    await tester.tap(find.text(_stopLabel));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(_pauseCount(calls), 1);

    await tester.pump(_afterPauseTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(_rootLabel), findsOneWidget);
  });

  testWidgets('system back alone runs stop-and-leave and gets out of a silent SDK',
      (tester) async {
    final calls = _mockSdk((call) => _silent());
    await _openSongMode(tester);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_pauseCount(calls), 1);

    await tester.pump(_afterPauseTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(_rootLabel), findsOneWidget);
  });

  testWidgets('leaves right after pause when the SDK answers', (tester) async {
    final calls = _mockSdk((call) async => true);
    await _openSongMode(tester);

    await tester.tap(find.text(_stopLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(_rootLabel), findsOneWidget);
    expect(_pauseCount(calls), 1);
  });

  testWidgets('leaves even when pause throws', (tester) async {
    final calls = _mockSdk(
      (call) async => throw PlatformException(code: 'PlayerAPI Error'),
    );
    await _openSongMode(tester);

    await tester.tap(find.text(_stopLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(_rootLabel), findsOneWidget);
    expect(_pauseCount(calls), 1);
  });

  // "Durdur ve çık" (and the back gesture) with a pause that was NOT confirmed: the
  // target page (Home) must say so; with a confirmed pause it must not.
  group('stop and exit: warning when the pause is not confirmed', () {
    testWidgets('silent SDK: the hint is visible on the target page', (tester) async {
      _mockSdk((call) => _silent());
      await _openSongMode(tester);

      await tester.tap(find.text(_stopLabel));
      await tester.pump();
      await tester.pump(_afterPauseTimeout);
      await tester.pump(const Duration(milliseconds: 600)); // pop transition + snack bar

      expect(find.text(_rootLabel), findsOneWidget, reason: 'target page');
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('pause error: the hint is visible on the target page', (tester) async {
      _mockSdk((call) async => throw PlatformException(code: 'PlayerAPI Error'));
      await _openSongMode(tester);

      await tester.tap(find.text(_stopLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text(_rootLabel), findsOneWidget);
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('back gesture counts as "Durdur ve çık": same hint', (tester) async {
      _mockSdk((call) => _silent());
      await _openSongMode(tester);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(_afterPauseTimeout);
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text(_rootLabel), findsOneWidget);
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('confirmed pause: no hint', (tester) async {
      _mockSdk((call) async => true);
      await _openSongMode(tester);

      await tester.tap(find.text(_stopLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text(_rootLabel), findsOneWidget);
      expect(find.text(_hint), findsNothing);
    });
  });

  // Three actions need more room than the old two: no overflow on a small iPhone.
  testWidgets('the layout fits a small phone (375x667) without overflow', (tester) async {
    _mockSdk((call) async => true);
    await _openSongMode(tester);
    tester.view.physicalSize = const Size(750, 1334); // iPhone SE like, 2x
    tester.view.devicePixelRatio = 2;
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull, reason: 'RenderFlex overflow or similar');
    expect(find.text(_rescanLabel), findsOneWidget);
    expect(find.text(_stopLabel), findsOneWidget);
    expect(find.text("Spotify'a git"), findsOneWidget);
    // all three actions are really on screen (not pushed below the fold)
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final label in [_rescanLabel, _stopLabel, "Spotify'a git"]) {
      expect(tester.getBottomLeft(find.text(label)).dy, lessThanOrEqualTo(screen.height));
    }
  });

  testWidgets('all actions are enabled at first and disabled while leaving', (tester) async {
    _mockSdk((call) => _silent());
    await _openSongMode(tester);

    TextButton exit() => tester.widget(find.widgetWithText(TextButton, _stopLabel));
    OutlinedButton spotify() => tester.widget(find.bySubtype<OutlinedButton>());
    GestureDetector primary() => tester.widget(find
        .ancestor(of: find.text(_rescanLabel), matching: find.byType(GestureDetector))
        .first);

    expect(exit().onPressed, isNotNull);
    expect(spotify().onPressed, isNotNull);
    expect(primary().onTap, isNotNull, reason: 're-scan is the main action and available');

    await tester.tap(find.text(_stopLabel));
    await tester.pump();

    expect(exit().onPressed, isNull);
    expect(spotify().onPressed, isNull);
    expect(primary().onTap, isNull);

    await tester.pump(_afterPauseTimeout); // let the pause timeout and the pop finish
    await tester.pump(const Duration(milliseconds: 600));
  });
}
