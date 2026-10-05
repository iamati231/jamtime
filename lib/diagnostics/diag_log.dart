import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:spotify_sdk/spotify_sdk.dart';

// GECICI: iPhone cihaz testi icin tani loglari. Filtre: "[JT-diag]".
// Token, kisisel veri ve QR/sarki icerigi ASLA loglanmaz — sadece olay adi,
// sure ve sonuc turu. Cihaz testi bitince bu dosya ve tum diag*/
// installDiagnostics cagrilari kaldirilacak.
void diag(String message) {
  debugPrint('[JT-diag] ${DateTime.now().toIso8601String()} $message');
}

/// [call]'in suresini ve sonuc turunu (ok / TIMEOUT / hata tipi) loglar,
/// sonucu veya hatayi aynen iletir. PlatformException icin sadece `code`
/// loglanir (ornek "Connection Error" = AppRemote yok, "PlayerAPI Error");
/// message/details loglanmaz.
Future<T> diagTimed<T>(String label, Future<T> Function() call) async {
  final sw = Stopwatch()..start();
  try {
    final result = await call();
    diag('$label ok ${sw.elapsedMilliseconds}ms');
    return result;
  } catch (e) {
    final kind = e is TimeoutException
        ? 'TIMEOUT'
        : e is PlatformException
            ? 'error:PlatformException(${e.code})'
            : 'error:${e.runtimeType}';
    diag('$label $kind ${sw.elapsedMilliseconds}ms');
    rethrow;
  }
}

/// Uygulama yasam dongusu ve Spotify baglanti durumu degisimlerini loglar.
/// Sadece dinler, hicbir sey tetiklemez / yeniden baglanmaz.
void installDiagnostics() {
  WidgetsBinding.instance.addObserver(_LifecycleLogger());
  try {
    SpotifySdk.subscribeConnectionStatus().listen(
      (s) => diag('spotify connection connected=${s.connected} '
          'errorCode=${s.errorCode}'),
      onError: (Object e) => diag('spotify connection stream error:${e.runtimeType}'),
    );
  } catch (e) {
    diag('spotify connection subscribe failed:${e.runtimeType}');
  }
}

class _LifecycleLogger with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    diag('lifecycle $state');
  }
}
