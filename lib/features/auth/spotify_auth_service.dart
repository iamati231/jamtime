import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import '../../config/spotify_config.dart';
import '../../diagnostics/diag_log.dart';
import 'spotify_connection_monitor.dart';
import 'spotify_session_store.dart';

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

/// Bir connect ucusunun neden basarisiz oldugu. SADECE [authRequired] kesindir
/// (kurulum isareti silinir); zaman asimi ve gecici hatalar isareti ASLA silmez.
enum ConnectFailure {
  /// Zaman limiti doldu (native connect hala surebilir).
  timeout,

  /// Spotify yetkiyi vermedi/geri cekti ya da kullanici Spotify'dan cikis yapmis.
  authRequired,

  /// Spotify uygulamasi bulunamadi.
  spotifyMissing,

  /// Diger / gecici hata (Spotify arka planda degil, bilinmeyen kod, ...).
  temporary,

  /// "Baglantiyi kes" / hesap degisimi bu ucusu gecersiz kildi.
  invalidated,
}

/// Calisan tek bir native connect (Single-Flight slot'unun sahibi).
class _ConnectFlight {
  _ConnectFlight(this.id, {required this.pauseAfter});

  final int id;

  /// Baglandiktan sonra pause atilsin mi? Ucusa katilan HERHANGI bir cagri isterse true.
  bool pauseAfter;

  final Stopwatch watch = Stopwatch()..start();
  Timer? timer;
  final Completer<ConnectFailure?> _done = Completer<ConnectFailure?>();

  bool get isDone => _done.isCompleted;

  /// `null` = baglandi; aksi halde neden.
  Future<ConnectFailure?> get result => _done.future;

  void complete(ConnectFailure? failure) => _done.complete(failure);
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
  // AuthScreen'deki ilk giris ve "Yeniden bagla": kullanici Spotify'da izin
  // verirken uzun surebilir; reconnect'ten cok daha uzun (yine de sonsuz degil).
  @visibleForTesting
  static const loginTimeout = Duration(seconds: 90);
  // "Baglantiyi kes": yerel disconnect cagrisi (daha once sinirsizdi, cagiran yoktu).
  @visibleForTesting
  static const disconnectTimeout = Duration(seconds: 2);
  // Kurulum isareti OKUMA ve SILME (yerel depo; normalde milisaniyeler). Depo hic cevap
  // vermezse uygulama bos ekranda ya da "Baglantiyi kes" penceresi takili kalmasin.
  // (Yazma hic beklenmez, bu yuzden limiti yok.)
  @visibleForTesting
  static const setupMarkerTimeout = Duration(seconds: 3);

  // ─── App Remote baglantisi: Single-Flight ───────────────────────────────────
  // Ayni anda EN FAZLA BIR calisan UCUS (ucus basina bir native connect): calisan bir
  // ucusa gelen ikinci cagri yeni connectToSpotifyRemote BASLATMAZ, ucusa katilir ve
  // sonucunu paylasir. Ucusun zaman limiti ilk cagriningir: katilan cagri onu UZATAMAZ,
  // ama kendi daha kisa limitinden fazla da beklemez. Ucus bitince slot serbest kalir ve
  // her ucus SADECE KENDI slot'unu serbest birakir: DART tarafinda eski bir ucusun gec
  // sonucu yeni ucusu etkilemez ve slot'unu silemez (native taraf icin bkz. 2. ve 3.).
  //
  // Bagli olunca (ve isteniyorsa) pause atilir ki Spotify'in baglanirken basladigi
  // son sarki calmasin. Kurulum isareti SADECE basarili bir ucustan sonra yazilir.
  //
  // KALAN SINIRLAR (native sonuc slot'u — Dart tarafindan cozulemez; KABUL gerektirir):
  //  1. "En fazla bir" ISLEM basina degil UCUS basina gecerlidir. Dart zaman asimi,
  //     bilincli iptal ("Baglantiyi kes" / hesap degisimi: [disconnectAndForget]) ve
  //     plugin'in hata vermesi (3.) native connect'i IPTAL ETMEZ (plugin'de iptal yok).
  //     Ucus biter ve slot serbest kalir; sonraki cagri YENI bir native connect (ve
  //     Spotify gecisi) baslatir, eskisi o sirada hala surebilir. Her zaman asimi bir
  //     native connect daha birakabilir.
  //  2. iOS: plugin'de TEK bir `connectionResult` slot'u ve tek bir delegate var. Yeni
  //     connect slot'un uzerine yazar; eski cagrinin Dart future'i HIC cevaplanmaz
  //     (zararsiz sizinti). Her connect yeni bir SPTAppRemote kurar ve ayri bir Spotify
  //     gecisi baslatir; eski bir gecisin geri donusu YENI ucusa atfedilebilir (yeni
  //     ucus onun yuzunden basarili ya da basarisiz olabilir). Dart bunu ayirt edemez.
  //  3. iOS: plugin, bekleyen bir connect varken uygulamaya gelen HER yabanci URL'de ve
  //     web olmayan kullanici etkinliginde hata verir ve slot'u bosaltir. URL'den gelen
  //     `authenticationTokenError` [ConnectFailure.authRequired] sayilir ve isareti
  //     siler (etkisi sinirli: bir sonraki soguk baslangicta Baglan ekrani).
  //  4. Android: slot yok, her cagrinin kendi callback'i var; eski bir connect gec
  //     basarili olabilir.
  //  5. Gec basari (zaman asimindan ya da "Baglantiyi kes"ten sonra): Dart tarafi gec
  //     sonucu yok sayar (isaret yazmaz; play/pause/connect/disconnect cagirmaz;
  //     gezinmez). Plugin baglantisi yine de kurulabilir ve Spotify tarafi
  //     (authorizeAndPlayURI, bos URI = son sarki) calmaya baslayabilir ya da
  //     surdurebilir. Gercek durumu SpotifyConnectionMonitor gosterir (event akisi
  //     "connected" der). Isaret ancak bir sonraki basarili connect'te yazilir; "Baglantiyi
  //     kes"ten sonra baglanti kendiliginden kapanmaz.
  static _ConnectFlight? _flight;
  static int _flightCounter = 0;

  /// true: baglandi (ve gerekiyorsa pause atildi). Ucusun zaman limiti [timeout];
  /// calisan bir ucusa katilirsa onun limiti gecerlidir.
  static Future<bool> connect({
    bool pauseAfter = true,
    Duration timeout = loginTimeout,
  }) async =>
      await _joinOrStartFlight(pauseAfter: pauseAfter, timeout: timeout) == null;

  static Future<ConnectFailure?> _joinOrStartFlight({
    required bool pauseAfter,
    required Duration timeout,
  }) {
    final running = _flight;
    if (running != null && !running.isDone) {
      running.pauseAfter = running.pauseAfter || pauseAfter;
      diag('connect joined flight #${running.id}');
      // Katilan cagri ucusun limitini UZATAMAZ; ama kendi (daha kisa) limitinden fazla
      // da BEKLEMEZ: sadece kendi beklemesi biter, ucus devam eder.
      return running.result.timeout(timeout, onTimeout: () => ConnectFailure.timeout);
    }
    final flight = _ConnectFlight(++_flightCounter, pauseAfter: pauseAfter);
    _flight = flight;
    flight.timer = Timer(timeout, () {
      diag('connect TIMEOUT ${flight.watch.elapsedMilliseconds}ms');
      debugPrint('[Spotify] connect error: TimeoutException');
      _finish(flight, ConnectFailure.timeout);
    });
    unawaited(_runFlight(flight));
    return flight.result;
  }

  static Future<void> _runFlight(_ConnectFlight flight) async {
    Object? error;
    bool? connected;
    try {
      connected = await SpotifySdk.connectToSpotifyRemote(
        clientId: SpotifyConfig.clientId,
        redirectUrl: SpotifyConfig.redirectUrl,
      );
    } catch (e) {
      error = e;
    }
    final ms = flight.watch.elapsedMilliseconds;

    if (flight.isDone) {
      // Ucus zaten bitti (zaman asimi / gecersiz kilindi). Native connect iptal
      // edilemedigi icin gec bir cevap gelebilir: sadece logla, hicbir sey
      // degistirme (yeni ucusu etkilemez, slot'una dokunmaz).
      diag('connect late ${error == null ? 'ok' : diagErrorKind(error)} ${ms}ms '
          '(flight already ended)');
      return;
    }

    flight.timer?.cancel(); // native cevap verdi: ucusun zaman limiti artik gecerli degil
    if (error != null) {
      diag('connect ${diagErrorKind(error)} ${ms}ms');
      debugPrint('[Spotify] connect error: ${_errText(error)}');
      _finish(flight, classifyConnectError(error));
      return;
    }
    diag('connect ok ${ms}ms');
    debugPrint('[Spotify] connected: $connected');
    if (connected != true) {
      _finish(flight, ConnectFailure.temporary);
      return;
    }

    // Native baglanti kuruldu: bilinen durum HEMEN "bagli" olur (pause fazindan ONCE; bu
    // sirada gelen bir "bagli degil" eventi sonradan ezilmesin).
    SpotifyConnectionMonitor.reportConnected();

    // Son calan parcayi otomatik resume etmesini engelle
    if (flight.pauseAfter) {
      try {
        await diagTimed(
          'pause(after connect)',
          () => SpotifySdk.pause().timeout(pauseTimeout),
        );
        debugPrint('[Spotify] paused after connect');
      } catch (_) {
        // Pause zaten paused durumdaysa hata atabilir, sorun degil
      }
    }
    // Pause sirasinda "Baglantiyi kes" gelmis olabilir: _finish bitmis ucusu yok sayar.
    _finish(flight, null);
  }

  /// Ucusu bitirir; bir ucus yalnizca BIR kez biter (gec cevaplar `isDone` ile
  /// elenir) ve SADECE KENDI slot'unu serbest birakir.
  static void _finish(_ConnectFlight flight, ConnectFailure? failure) {
    if (flight.isDone) return;
    flight.timer?.cancel();
    if (identical(_flight, flight)) _flight = null;

    if (failure == null) {
      unawaited(_rememberSetup()); // isaret SADECE basarili kurulumdan sonra
    } else if (failure == ConnectFailure.authRequired) {
      unawaited(_forgetSetup()); // kesin: yetki yok / geri cekilmis
    }
    flight.complete(failure);
  }

  /// Native hatanin siniflandirmasi. Sadece plugin'in KENDI kodlari kesin sayilir;
  /// iOS SDK'nin sayisal hata kodlari belgelenmemis oldugu icin "gecici" kalir.
  @visibleForTesting
  static ConnectFailure classifyConnectError(Object e) {
    if (e is TimeoutException) return ConnectFailure.timeout;
    if (e is PlatformException) {
      switch (e.code) {
        case 'authenticationTokenError': // iOS: Spotify token vermedi / redirect hatasi
        case 'UserNotAuthorizedException': // Android: kullanici yetki vermedi
        case 'AuthenticationFailedException': // Android: kimlik dogrulama basarisiz
        case 'NotLoggedInException': // Android: Spotify'dan cikis yapilmis
          return ConnectFailure.authRequired;
        case 'spotifyNotInstalled': // iOS
        case 'CouldNotFindSpotifyApp': // Android (+ iOS yedegi)
          return ConnectFailure.spotifyMissing;
      }
    }
    return ConnectFailure.temporary;
  }

  // ─── Kurulum isareti (kalici, sensitif degil) ───────────────────────────────
  // "Kurulum daha once basariyla yapildi" — ne "su an bagli" ne "token gecerli".
  // Gecici hatalar ve zaman asimlari isareti SILMEZ; sadece bilincli "baglantiyi
  // kes" / hesap degisimi ve kesin yetki hatasi ([ConnectFailure.authRequired]).
  @visibleForTesting
  static SpotifySessionStore sessionStore = const PrefsSpotifySessionStore();

  /// Kurulum daha once yapildi mi? Okunamazsa false (guvenli yol: Baglan ekrani).
  static Future<bool> hasCompletedSetup() async {
    try {
      return await sessionStore.readSetupDone().timeout(
            setupMarkerTimeout,
            onTimeout: () => false,
          );
    } catch (e) {
      debugPrint('[Spotify] setup marker read error: ${_errText(e)}');
      return false;
    }
  }

  // Yazma/silme YARISI: Depo islemlerinin hangi SIRAYLA bittigi garanti degildir; gec
  // biten bir yazma, sonradan verilen silmeyi ezebilir. Bu yuzden
  //  1. her islem bittiginde EN SON KARAR ile karsilastirilir, farkliysa o karar tekrar
  //     uygulanir ("son karar kazanir"; en fazla birkac tur, kararlar kullanici eylemi);
  //  2. "unutuldu" ancak silme basarili, daha once baslamis islemler bitmis VE geri
  //     okuma (gercekten saklanan durum) "yok" dediginde bildirilir. Hata ya da zaman
  //     asimi asla "kesin unutuldu" demek degildir.
  // SINIR: Hic bitmeyen (asili kalan) bir yazma gec de olsa depoya inebilir; bunu Dart
  // tarafi bilemez. O durumda silme "dogrulanamadi" olarak bildirilir.
  static bool _markerWanted = false; // son karar: true = hatirla, false = unut
  static final Set<Future<Object?>> _markerOps = <Future<Object?>>{};

  static Future<T> _trackMarkerOp<T>(Future<T> Function() op) {
    final future = op();
    _markerOps.add(future);
    future.whenComplete(() => _markerOps.remove(future)).ignore();
    return future;
  }

  /// [state] kararini uygular; bittiginde baska bir karar gelmisse (EN SON KARAR) onu da
  /// uygular (en fazla 4 tur). Hata firlatmaz. Doner: son uygulanan islem basarili VE son
  /// uygulanan durum son karara esit. 4 turda yakinsamazsa false: "yakinsadi" iddia edilmez.
  /// Yazma (state == true) burada SINIRSIZ beklenir (isaret yazimi hic beklenmez); sinir
  /// bu islemi bekleyen yerlerdedir ([disconnectAndForget] ve [_forgetSetup]).
  static Future<bool> _applyMarker(bool state) async {
    var lastOk = false;
    var converged = false;
    for (var round = 0; round < 4; round++) {
      try {
        if (state) {
          await sessionStore.writeSetupDone();
        } else {
          await sessionStore.clear().timeout(setupMarkerTimeout);
        }
        lastOk = true;
      } catch (e) {
        lastOk = false;
        debugPrint('[Spotify] setup marker ${state ? 'write' : 'clear'} error: ${_errText(e)}');
      }
      if (_markerWanted == state) {
        converged = true; // son uygulanan durum = son karar
        break;
      }
      state = _markerWanted; // arada baska bir karar geldi: onu uygula
    }
    return converged && lastOk;
  }

  static Future<void> _rememberSetup() {
    _markerWanted = true;
    return _trackMarkerOp(() => _applyMarker(true));
  }

  /// true: silme DOGRULANDI. false: hata, zaman asimi, geri okuma "hala var" dedi ya da
  /// baska bir karar geldi — "unutuldu" denemez.
  static Future<bool> _forgetSetup() async {
    _markerWanted = false;
    final earlier = _markerOps.toList(); // ornegin hala bekleyen bir yazma
    var confirmed = await _trackMarkerOp(() => _applyMarker(false));
    try {
      // Daha once baslamis bir islem silmeden SONRA depoya inebilir: bitmesini (sinirli)
      // bekle. Bittiginde son karari ("unut") kendisi tekrar uygular.
      if (earlier.isNotEmpty) await Future.wait(earlier).timeout(setupMarkerTimeout);
      // Siralamaya ve depoya guvenme: kayitli durumu GERI OKU.
      if (confirmed) {
        confirmed = !await sessionStore.readSetupDone().timeout(setupMarkerTimeout);
      }
    } catch (e) {
      debugPrint('[Spotify] setup marker could not be verified: ${_errText(e)}');
      return false;
    }
    return confirmed && !_markerWanted;
  }

  // ─── Playback durdur ────────────────────────────────────────────────────────
  // true: SDK pause'u onayladi. false: zaman asimi veya hata — muzigin durdugu
  // KESIN DEGIL (arayuz buna gore uyarir, "durdu" demez).
  static Future<bool> pause() async {
    try {
      await diagTimed('pause', () => SpotifySdk.pause().timeout(pauseTimeout));
      return true;
    } catch (e) {
      debugPrint('[Spotify] pause error: ${_errText(e)}');
      return false;
    }
  }

  // ─── App Remote bağlantısını kapat ──────────────────────────────────────────
  // Playback durmaz; sadece kontrol kanalı kapanır. Spotify'daki yetki GERI ALINMAZ.
  static Future<void> disconnect() async {
    try {
      await SpotifySdk.disconnect().timeout(disconnectTimeout);
    } catch (e) {
      debugPrint('[Spotify] disconnect error: ${_errText(e)}');
    }
  }

  /// Bilincli kullanici eylemi "Baglantiyi kes" (ve hesap degisiminin ilk adimi):
  /// calisan connect ucusunu ve tum calma denemelerini gecersiz kilar, kayitli
  /// baglanti bilgisini (isaret) siler, durumu "bagli degil" yapar ve SDK baglantisini
  /// kapatmayi dener. Spotify'daki yetkiyi GERI ALMAZ (plugin'de boyle bir cagri yok).
  ///
  /// Doner: true = isaretin silindigi DOGRULANDI. false = silme hata verdi, zaman
  /// asimina ugradi ya da dogrulanamadi — "unutuldu" denemez (arayuz bunu soyler).
  /// Ucus/denemeler ve SDK baglantisi her durumda ele alinir.
  static Future<bool> disconnectAndForget() async {
    _invalidateEverything();
    // Karar HEMEN kaydedilir; depo isi paralel yurur ve TOPLAMDA sinirlidir (depo ya da
    // arada gelen yeni bir yazma asilirsa arayuz sonsuza kadar beklemesin).
    final forgotten = _forgetSetup().timeout(
      setupMarkerTimeout * 3,
      onTimeout: () => false,
    );
    SpotifyConnectionMonitor.reportDisconnected();
    await disconnect();
    return forgotten;
  }

  /// Eski her seyi gecersiz kilar: eski PlaybackAttempt'ler (reconnect/retry
  /// baslatmaz) ve calisan ucus (sonucu `invalidated`; native connect sonradan
  /// basarili olsa bile ucus bitmistir, gec cevap yok sayilir).
  static void _invalidateEverything() {
    _latestGeneration++;
    final flight = _flight;
    if (flight != null && !flight.isDone) _finish(flight, ConnectFailure.invalidated);
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

    if (SpotifyConnectionMonitor.isKnownDisconnected) {
      // Durum ACIKCA "bagli degil" (taze surec, event ya da bilincli kesme): ilk
      // play ya hemen hata verir ya da zaman asimina kadar bekletirdi. Direkt baglan.
      diag('play skipped: connection known to be down');
    } else {
      try {
        await diagTimed(
          'play',
          () => SpotifySdk.play(spotifyUri: uri).timeout(playTimeout),
        );
        return true;
      } catch (e) {
        debugPrint('[Spotify] play error (first try): ${_errText(e)}');
      }
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

  /// Sadece testler: statik durumu temizler (calisan ucus, depo). Deneme sayaci
  /// bilerek geri sarilmaz.
  @visibleForTesting
  static void debugReset() {
    _flight?.timer?.cancel();
    _flight = null;
    _markerOps.clear();
    _markerWanted = false;
    sessionStore = const PrefsSpotifySessionStore();
  }
}
