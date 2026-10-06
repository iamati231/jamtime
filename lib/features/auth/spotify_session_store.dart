import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sensitif OLMAYAN isaret: "Spotify baglantisi daha once bir kez basariyla yapildi".
///
/// Isaret ne "su an bagli" ne de "token gecerli" demektir; uygulamaya sadece
/// "Baglan ekraniyla baslamak zorunda degilsin" der. Burada Token, hesap veya
/// kisisel veri SAKLANMAZ (Token kalicilastirma bu isin kapsami disinda).
abstract class SpotifySessionStore {
  /// Kayitli (gercekten saklanan) durum.
  Future<bool> readSetupDone();
  Future<void> writeSetupDone();
  Future<void> clear();
}

/// Depo yazmayi/silmeyi reddetti (native cagri `false` dondurdu).
class SpotifySessionStoreException implements Exception {
  const SpotifySessionStoreException(this.operation);
  final String operation;

  @override
  String toString() => 'SpotifySessionStoreException($operation)';
}

/// [SharedPreferences] ile gercek depo. Tek bir bool deger.
///
/// SharedPreferences (eski API) degeri ONCE kendi onbellegine yazar ve native cagriyi
/// sonra yapar; `false` donerse kayit basarisizdir ama onbellek zaten degismistir.
/// Bu yuzden: set/remove `false` donerse hata sayilir ve okuma onbellege degil
/// `reload()` ile gercekten saklanan duruma bakar.
class PrefsSpotifySessionStore implements SpotifySessionStore {
  const PrefsSpotifySessionStore();

  @visibleForTesting
  static const key = 'jamtime.spotify_setup_done';

  @override
  Future<bool> readSetupDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(key) ?? false;
  }

  @override
  Future<void> writeSetupDone() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(key, true)) {
      throw const SpotifySessionStoreException('write');
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(key)) {
      throw const SpotifySessionStoreException('clear');
    }
  }
}
