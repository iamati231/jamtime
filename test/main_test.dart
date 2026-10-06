import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

// The real entry point wires the ONE central subscription to the plugin's connection
// status stream (SpotifyConnectionMonitor). The iOS plugin keeps a single event sink:
// a missing or a second subscription would silently break the known connection state.
// Its own file: every test file has a fresh isolate, so main() runs on a clean slate.

const _channel = MethodChannel('connection_status_subscription');

void main() {
  testWidgets('main() subscribes to the connection status stream exactly once',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));

    await tester.runAsync(() async {
      app.main(); // loads the track whitelist from the asset bundle (real async)
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(calls.where((c) => c == 'listen'), hasLength(1));
  });
}
