import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';

// Deliberately a file of its own: every test file runs in a fresh isolate, so the
// monitor here is still in the state of a freshly started app. The other monitor
// tests reset it in setUp and therefore cannot see the real initial value.
//
// Why it matters: a fresh process has never called connect, so no App Remote
// connection can exist. "Disconnected" is what makes the first scan connect first
// (instead of a doomed play), announces the Spotify switch, and makes the Spotify
// menu say "not connected" after a start with the setup marker.
void main() {
  test('a freshly started app knows no connection: the link starts as "disconnected"', () {
    expect(SpotifyConnectionMonitor.link.value, SpotifyLink.disconnected);
    expect(SpotifyConnectionMonitor.isKnownDisconnected, isTrue);
    expect(SpotifyConnectionMonitor.isConnected, isFalse);
  });
}
