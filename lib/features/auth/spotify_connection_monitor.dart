import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import '../../diagnostics/diag_log.dart';

/// Spotify App Remote baglantisinin BILINEN durumu. Bu bir "oturum" degildir:
/// kalici isaretle (SpotifySessionStore) karismamali.
enum SpotifyLink { connected, disconnected }

/// Baglanti durumunun TEK kaynagi. Native event akisina (connection_status_
/// subscription) tam BIR abonelik; iOS plugin'in tek bir event sink'i vardir ve
/// ikinci bir `subscribeConnectionStatus()` onu EZERDI. Bu yuzden uygulamada baska
/// hicbir yerde bu akisa abone olunmaz.
///
/// Baslangic durumu `disconnected`: taze bir surecte hic connect cagrilmamistir,
/// yani baglanti VAR olamaz (iOS plugin'de appRemote nil). Durum sadece
/// (1) native event'lerle, (2) kendi basarili connect'imizle (connected) ve
/// (3) kendi bilincli "baglantiyi kes" eylemimizle (disconnected) degisir. Bir
/// play hatasi durumu DEGISTIRMEZ: URI/parca hatasi baglantinin dustugu anlamina
/// gelmez ve gereksiz bir Spotify gecisine yol acardi.
class SpotifyConnectionMonitor {
  SpotifyConnectionMonitor._();

  static final ValueNotifier<SpotifyLink> link =
      ValueNotifier<SpotifyLink>(SpotifyLink.disconnected);

  static bool get isConnected => link.value == SpotifyLink.connected;

  /// Durum ACIKCA "bagli degil": ilk play'i atlamak guvenlidir.
  static bool get isKnownDisconnected => link.value == SpotifyLink.disconnected;

  static StreamSubscription<Object?>? _subscription;

  /// Uygulama basinda bir kez cagrilir (main). Tekrar cagrilarda abonelik acilmaz.
  /// Sadece dinler; hicbir sey tetiklemez / baglanmaz.
  static void install() {
    if (_subscription != null) return;
    try {
      _subscription = SpotifySdk.subscribeConnectionStatus().listen(
        (status) {
          diagRecordConnection(status.connected);
          diag('spotify connection connected=${status.connected} '
              'errorCode=${status.errorCode}');
          _set(status.connected ? SpotifyLink.connected : SpotifyLink.disconnected);
        },
        onError: (Object e) => diag('spotify connection stream error:${e.runtimeType}'),
      );
    } catch (e) {
      diag('spotify connection subscribe failed:${e.runtimeType}');
    }
  }

  /// Kendi connect ucusumuz basariyla bitti.
  static void reportConnected() => _set(SpotifyLink.connected);

  /// Kendi bilincli "baglantiyi kes" eylemimiz.
  static void reportDisconnected() => _set(SpotifyLink.disconnected);

  static void _set(SpotifyLink value) {
    if (link.value != value) link.value = value;
  }

  /// Sadece testler: aboneligi kapatir ve durumu `disconnected`a (taze surec)
  /// ya da verilen degere ceker.
  @visibleForTesting
  static Future<void> debugReset({SpotifyLink to = SpotifyLink.disconnected}) async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    link.value = to;
  }
}
