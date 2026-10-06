import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';

// ONE central subscription to the plugin's connection status stream. The iOS plugin
// keeps a single event sink (StatusHandler.eventSink), so a second
// subscribeConnectionStatus() would silently cut the first one off.

const _channelName = 'connection_status_subscription';
const _failFast = Timeout(Duration(seconds: 10));

class _EventSource {
  _EventSource() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    _messenger = messenger;
    messenger.setMockMethodCallHandler(const MethodChannel(_channelName), (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(const MethodChannel(_channelName), null));
  }

  late final TestDefaultBinaryMessenger _messenger;
  final List<String> calls = <String>[];

  int get listens => calls.where((c) => c == 'listen').length;

  /// The plugin sends the status as a JSON STRING (iOS: ConnectionStatusHandler).
  void emit(String json) {
    _messenger.handlePlatformMessage(
      _channelName,
      const StandardMethodCodec().encodeSuccessEnvelope(json),
      null,
    );
  }
}

void main() {
  setUp(() async {
    await SpotifyConnectionMonitor.debugReset();
  });

  tearDown(() async {
    await SpotifyConnectionMonitor.debugReset();
  });

  test('debugReset() returns to the "no connection" state of a fresh process', () {
    expect(SpotifyConnectionMonitor.link.value, SpotifyLink.disconnected);
    expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);
    expect(SpotifyConnectionMonitor.isConnected, isFalse);
  });

  testWidgets('install() subscribes exactly once, however often it is called',
      (tester) async {
    final source = _EventSource();
    SpotifyConnectionMonitor.install();
    SpotifyConnectionMonitor.install();
    SpotifyConnectionMonitor.install();
    await tester.pump();
    expect(source.listens, 1);
  }, timeout: _failFast);

  testWidgets('plugin events set connected / disconnected', (tester) async {
    final source = _EventSource();
    SpotifyConnectionMonitor.install();
    await tester.pump();

    source.emit('{"connected": true}'); // what iOS sends on success
    await tester.pump();
    expect(SpotifyConnectionMonitor.isConnected, isTrue);

    source.emit('{"connected": false, "errorCode": "-1001", "errorDetails": "dropped"}');
    await tester.pump();
    expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);

    source.emit('{"connected": false}'); // plain disconnect without an error
    await tester.pump();
    expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);

    source.emit('{"connected": true}');
    await tester.pump();
    expect(SpotifyConnectionMonitor.isConnected, isTrue);
  }, timeout: _failFast);

  testWidgets('a broken event is ignored and the state is kept', (tester) async {
    final source = _EventSource();
    SpotifyConnectionMonitor.install();
    await tester.pump();
    source.emit('{"connected": true}');
    await tester.pump();

    source.emit('this is not json');
    await tester.pump();
    expect(SpotifyConnectionMonitor.isConnected, isTrue);

    source.emit('{"connected": false}'); // and the stream still works afterwards
    await tester.pump();
    expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);
  }, timeout: _failFast);

  test('own actions: reportConnected / reportDisconnected notify listeners once per change',
      () {
    final seen = <SpotifyLink>[];
    void listener() => seen.add(SpotifyConnectionMonitor.link.value);
    SpotifyConnectionMonitor.link.addListener(listener);
    addTearDown(() => SpotifyConnectionMonitor.link.removeListener(listener));

    SpotifyConnectionMonitor.reportDisconnected(); // already disconnected: no change
    SpotifyConnectionMonitor.reportConnected();
    SpotifyConnectionMonitor.reportConnected(); // no change
    SpotifyConnectionMonitor.reportDisconnected();

    expect(seen, [SpotifyLink.connected, SpotifyLink.disconnected]);
  });
}
