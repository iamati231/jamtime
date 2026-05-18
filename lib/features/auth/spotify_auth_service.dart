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
  // QR koddan gelen parçayı çalmak icin kullaniyoruz - pauseAfter=false ile
  // connect'i sayfayi tasridan onceki adimda guvenli olmasi icin yapiyoruz.
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
