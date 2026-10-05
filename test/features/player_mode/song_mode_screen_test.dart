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
}
