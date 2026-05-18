import 'package:flutter/foundation.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import '../../config/spotify_config.dart';

class SpotifyAuthService {
  // ─── App Remote bağlantısı ──────────────────────────────────────────────────
  // İlk bağlantıda Spotify kısa bir izin ekranı gösterebilir.
  // Bağlanır bağlanmaz pause atıyoruz ki son çalan şarkı otomatik başlamasın.
  static Future<bool> connect({bool pauseAfter = true}) async {
    try {
      final result = await SpotifySdk.connectToSpotifyRemote(
        clientId: SpotifyConfig.clientId,
        redirectUrl: SpotifyConfig.redirectUrl,
      );
      debugPrint('[Spotify] connected: $result');

      // Son çalan parçayı otomatik resume etmesini engelle
      if (result && pauseAfter) {
        try {
          await SpotifySdk.pause();
          debugPrint('[Spotify] paused after connect');
        } catch (_) {
          // Pause zaten paused durumdaysa hata atabilir, sorun değil
        }
      }
      return result;
    } catch (e) {
      debugPrint('[Spotify] connect error: $e');
      return false;
    }
  }

  // ─── Sessiz reconnect — app açılışında kullan ───────────────────────────────
  // Mevcut bir session varsa hızlıca bağlan, yoksa false dön.
  // Pause atar (auto-play engellemek için).
  static Future<bool> trySilentConnect() async {
    return await connect(pauseAfter: true);
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
  // Cagri sirasinda baglanti dusmusse bir kez reconnect denenir.
  // Bool: basarili (true) / basarisiz (false).
  static Future<bool> playTrack(String spotifyUrl) async {
    final uri = _toUri(spotifyUrl);

    try {
      await SpotifySdk.play(spotifyUri: uri);
      return true;
    } catch (e) {
      debugPrint('[Spotify] play error (first try): $e');
    }

    // Baglanti dustuyse tek bir reconnect dene (pauseAfter=false — hemen calacak)
    try {
      final ok = await connect(pauseAfter: false);
      if (!ok) return false;
      await SpotifySdk.play(spotifyUri: uri);
      return true;
    } catch (e) {
      debugPrint('[Spotify] play error (retry): $e');
      return false;
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
