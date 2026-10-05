import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import '../../config/spotify_config.dart';
import '../../diagnostics/diag_log.dart';

/// Bir "sarki cal" denemesi. Her yeni deneme kendi generation'ini alir; yeni bir
/// deneme basladiginda eskileri otomatik eski (stale) olur. [cancel] sadece BU
/// denemeyi iptal eder — baska bir ekranin daha yeni denemesini etkilemez.
/// Eski bir deneme yeni SDK cagrisi (reconnect / retry) baslatmaz.
class PlaybackAttempt {
  PlaybackAttempt._(this._generation);

  final int _generation;
  bool _cancelled = false;

  /// Iptal edilmedi ve daha yeni bir deneme baslamadi.
  bool get isCurrent =>
      !_cancelled && _generation == SpotifyAuthService._latestGeneration;

  /// Ekran kapanirken cagrilir; yalnizca bu denemeyi gecersiz kilar.
  void cancel() => _cancelled = true;
}

class SpotifyAuthService {
  // Hata loglarinda exception mesaji/details yazilmaz: Android'de Spotify URI'si
  // (calan sarki) icerebilir. Sadece tip ve PlatformException.code loglanir.
  static String _errText(Object e) =>
      e is PlatformException ? 'PlatformException(${e.code})' : '${e.runtimeType}';

  // ─── Zaman asimlari ─────────────────────────────────────────────────────────
  // iOS plugin'de play/pause icin callback hic donmeyebilir (baglanti dustuyse
  // playerAPI nil olur, sonuc hic bildirilmez). Sonsuza kadar beklemek yerine
  // zaman asimina dusup hata yolunu calistiriyoruz. Baslangic degerleri —
  // cihaz loglarina ([JT-diag]) gore ayarlanacak; testler bu sabitleri
  // kullanir, yani ayarlayinca testler kendiliginden uyum saglar.
  @visibleForTesting
  static const pauseTimeout = Duration(seconds: 2);
  @visibleForTesting
  static const playTimeout = Duration(seconds: 4);
  // QR taramasi sirasindaki reconnect (Spotify'a gecis dahil).
  @visibleForTesting
  static const reconnectTimeout = Duration(seconds: 15);
  // AuthScreen'deki ilk giris: kullanici Spotify'da izin verirken uzun surebilir;
  // reconnect'ten cok daha uzun (yine de sonsuz degil).
  @visibleForTesting
  static const loginTimeout = Duration(seconds: 90);

  // ─── App Remote bağlantısı ──────────────────────────────────────────────────
  // İlk bağlantıda Spotify kısa bir izin ekranı gösterebilir.
  // Bağlanır bağlanmaz pause atıyoruz ki son çalan şarkı otomatik başlamasın.
  //
  // BILINEN SINIR: Generation-guard sadece eski denemelerin YENI SDK cagrisi
  // baslatmasini engeller; calisan bir connect'i iptal edemez. Paralel
  // connectToSpotifyRemote cagrilari bu yuzden mumkun kalir (iOS plugin'de tek
  // connectionResult slot'u: sadece en yeni connect cevaplanir, her connect ayri
  // bir Spotify gecisi yapar). Kucuk cozum — single-flight (calisan connect'e
  // ikinci cagri katilir, slot timeout'ta da serbest kalir) — simdilik
  // ERTELENDI; cihaz testi ve loglardan sonra karar verilecek.
  static Future<bool> connect({
    bool pauseAfter = true,
    Duration timeout = loginTimeout,
  }) async {
    try {
      final result = await diagTimed(
        'connect',
        () => SpotifySdk.connectToSpotifyRemote(
          clientId: SpotifyConfig.clientId,
          redirectUrl: SpotifyConfig.redirectUrl,
        ).timeout(timeout),
      );
      debugPrint('[Spotify] connected: $result');

      // Son çalan parçayı otomatik resume etmesini engelle
      if (result && pauseAfter) {
        try {
          await diagTimed(
            'pause(after connect)',
            () => SpotifySdk.pause().timeout(pauseTimeout),
          );
          debugPrint('[Spotify] paused after connect');
        } catch (_) {
          // Pause zaten paused durumdaysa hata atabilir, sorun değil
        }
      }
      return result;
    } catch (e) {
      debugPrint('[Spotify] connect error: ${_errText(e)}');
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
      await diagTimed('pause', () => SpotifySdk.pause().timeout(pauseTimeout));
    } catch (e) {
      debugPrint('[Spotify] pause error: ${_errText(e)}');
    }
  }

  // ─── App Remote bağlantısını kapat ──────────────────────────────────────────
  // Playback durmaz; sadece kontrol kanalı kapanır.
  static Future<void> disconnect() async {
    try {
      await SpotifySdk.disconnect();
    } catch (e) {
      debugPrint('[Spotify] disconnect error: ${_errText(e)}');
    }
  }

  // ─── Deneme (generation) takibi ─────────────────────────────────────────────
  static int _latestGeneration = 0;

  /// Yeni bir calma denemesi baslatir; daha onceki denemeler eski (stale) olur.
  static PlaybackAttempt beginAttempt() => PlaybackAttempt._(++_latestGeneration);

  // ─── Parçayı çal ────────────────────────────────────────────────────────────
  // Cagri sirasinda baglanti dusmusse bir kez reconnect denenir.
  // Bool: basarili (true) / basarisiz (false).
  // [attempt] bu denemenin kimligi: her await'ten sonra ve reconnect/retry'dan
  // hemen once kontrol edilir. Eski (stale) bir deneme yeni SDK cagrisi baslatmaz;
  // aksi halde gec donen bir deneme daha yeni bir kartin calmasini ezebilir.
  static Future<bool> playTrack(
    String spotifyUrl, {
    PlaybackAttempt? attempt,
  }) async {
    attempt ??= beginAttempt();
    if (!attempt.isCurrent) {
      diag('play skipped: stale attempt');
      return false;
    }
    final uri = _toUri(spotifyUrl);

    try {
      await diagTimed(
        'play',
        () => SpotifySdk.play(spotifyUri: uri).timeout(playTimeout),
      );
      return true;
    } catch (e) {
      debugPrint('[Spotify] play error (first try): ${_errText(e)}');
    }

    // Beklerken ekran kapandi veya daha yeni bir deneme basladi: reconnect yok.
    if (!attempt.isCurrent) {
      diag('reconnect skipped: stale attempt');
      return false;
    }

    // Baglanti dustuyse (veya cevap gelmediyse) tek bir reconnect dene
    // (pauseAfter=false — hemen calacak)
    try {
      final ok = await connect(pauseAfter: false, timeout: reconnectTimeout);
      if (!ok) return false;
      if (!attempt.isCurrent) {
        diag('retry skipped: stale attempt');
        return false;
      }
      await diagTimed(
        'play(retry)',
        () => SpotifySdk.play(spotifyUri: uri).timeout(playTimeout),
      );
      return true;
    } catch (e) {
      debugPrint('[Spotify] play error (retry): ${_errText(e)}');
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
