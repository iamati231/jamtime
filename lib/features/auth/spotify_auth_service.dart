import 'package:flutter/foundation.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import '../../config/spotify_config.dart';

class SpotifyAuthService {
  // ─── App Remote bağlantısı ──────────────────────────────────────────────────
  // İlk bağlantıda Spotify kısa bir izin ekranı gösterebilir.
  static Future<bool> connect() async {
    try {
      final result = await SpotifySdk.connectToSpotifyRemote(
        clientId: SpotifyConfig.clientId,
        redirectUrl: SpotifyConfig.redirectUrl,
      );
      debugPrint('[Spotify] connected: $result');
      return result;
    } catch (e) {
      debugPrint('[Spotify] connect error: $e');
      return false;
    }
  }

  // ─── Playback durdur ────────────────────────────────────────────────────────
  static Future<void> pause() async {
    try {
      await SpotifySdk.pause();
    } catch (e) {
      debugPrint('[Spotify] pause error: $e');
    }
  }

  // ─── App Remote bağlantısını kapat ──────────────────────────────────────────
  // Playback durmaz; sadece kontrol kanalı kapanır.
  static Future<void> disconnect() async {
    try {
      await SpotifySdk.disconnect();
    } catch (e) {
      debugPrint('[Spotify] disconnect error: $e');
    }
  }

  // ─── Parçayı çal ────────────────────────────────────────────────────────────
  static Future<void> playTrack(String spotifyUrl) async {
    try {
      await SpotifySdk.play(spotifyUri: _toUri(spotifyUrl));
    } catch (e) {
      debugPrint('[Spotify] play error: $e');
    }
  }

  // https://open.spotify.com/track/ID?si=xxx  →  spotify:track:ID
  static String _toUri(String url) {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments;
    if (segments.length >= 2) {
      return 'spotify:${segments[0]}:${segments[1]}';
    }
    return url;
  }
}
