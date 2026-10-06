import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// GECICI: iPhone cihaz testi icin tani loglari. Filtre: "[JT-diag]".
// Token, kisisel veri ve QR/sarki icerigi ASLA loglanmaz — sadece olay adi,
// sure ve sonuc turu. Cihaz testi bitince bu dosya ve tum diag*/
// installDiagnostics cagrilari kaldirilacak.
void diag(String message) {
  debugPrint('[JT-diag] ${DateTime.now().toIso8601String()} $message');
}

/// Hata turu (TIMEOUT / hata tipi). PlatformException icin sadece `code`
/// (ornek "Connection Error" = AppRemote yok, "PlayerAPI Error"); message/details
/// ASLA yazilmaz.
String diagErrorKind(Object e) => e is TimeoutException
    ? 'TIMEOUT'
    : e is PlatformException
        ? 'error:PlatformException(${e.code})'
        : 'error:${e.runtimeType}';

/// [call]'in suresini ve sonuc turunu (ok / TIMEOUT / hata tipi) loglar,
/// sonucu veya hatayi aynen iletir (bkz. [diagErrorKind]).
Future<T> diagTimed<T>(String label, Future<T> Function() call) async {
  final sw = Stopwatch()..start();
  try {
    final result = await call();
    diag('$label ok ${sw.elapsedMilliseconds}ms');
    return result;
  } catch (e) {
    diag('$label ${diagErrorKind(e)} ${sw.elapsedMilliseconds}ms');
    rethrow;
  }
}

// ─── Son bilinen durum ──────────────────────────────────────────────────────
// "Baglanti kontrolu": SDK'ya HICBIR cagri yapmadan, durum akisindan ogrenilen
// son durum ve yasi. Scan aninda loglanir; ilk play'in sonucuyla karsilastirilir
// (ayrilmis oldugu biliniyorsa yine de 4 sn'lik play zaman asimina giriyor mu?).
bool? _lastConnected;
DateTime? _lastConnectedAt;
String? _lastLifecycle;
DateTime? _lastLifecycleAt;

/// SpotifyConnectionMonitor cagirir (tek event aboneligi); testler `at` verebilir.
void diagRecordConnection(bool connected, {DateTime? at}) {
  _lastConnected = connected;
  _lastConnectedAt = at ?? DateTime.now();
}

@visibleForTesting
void diagRecordLifecycle(String name, {DateTime? at}) {
  _lastLifecycle = name;
  _lastLifecycleAt = at ?? DateTime.now();
}

@visibleForTesting
void diagResetState() {
  _lastConnected = null;
  _lastConnectedAt = null;
  _lastLifecycle = null;
  _lastLifecycleAt = null;
}

/// Ornek: `lastConn=disconnected(63.2s) lastLifecycle=resumed(12.4s)`.
/// `unknown` / `-`: henuz hic olay gelmedi. Sadece durum ve sure; icerik yok.
/// [now] sadece testler icin.
String diagStateSummary({DateTime? now}) {
  final t = now ?? DateTime.now();
  String age(DateTime? at) =>
      at == null ? '-' : '${(t.difference(at).inMilliseconds / 1000).toStringAsFixed(1)}s';
  final conn = _lastConnected == null
      ? 'unknown'
      : (_lastConnected! ? 'connected' : 'disconnected');
  return 'lastConn=$conn(${age(_lastConnectedAt)}) '
      'lastLifecycle=${_lastLifecycle ?? '-'}(${age(_lastLifecycleAt)})';
}

/// Ayni kodun art arda gelen algilamalari arasindaki farklari (ms) sayar — SADECE
/// sayilar, kod icerigi yok. Soru: "Goruntudeki bir kart duzenli tekrar
/// bildiriliyor mu?" (Cihazda olculmeden kart cekildi sayilmaz.)
class DiagGapStats {
  DiagGapStats({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Bu degerden buyuk bir aralik hemen ayri bir satir olarak loglanir.
  static const bigGapMs = 1000;

  final DateTime Function() _now;
  DateTime? _last;
  int hits = 0;
  int _min = 0;
  int _max = 0;
  int _sum = 0;

  void hit() {
    final t = _now();
    final last = _last;
    _last = t;
    hits++;
    if (last == null) return;
    final gap = t.difference(last).inMilliseconds;
    _sum += gap;
    if (hits == 2 || gap < _min) _min = gap;
    if (gap > _max) _max = gap;
    if (gap > bigGapMs) diag('detection gap ${gap}ms');
  }

  /// Ornek: `hits=21 gaps(ms) min=240 max=1730 avg=262`.
  String summary() => hits < 2
      ? 'hits=$hits'
      : 'hits=$hits gaps(ms) min=$_min max=$_max avg=${_sum ~/ (hits - 1)}';

  void reset() {
    _last = null;
    hits = 0;
    _min = 0;
    _max = 0;
    _sum = 0;
  }
}

/// Uygulama yasam dongusu degisimlerini loglar. Sadece dinler, hicbir sey
/// tetiklemez / yeniden baglanmaz. (Spotify baglanti durumu artik
/// SpotifyConnectionMonitor'un TEK aboneligi uzerinden gelir; iOS plugin'in tek bir
/// event sink'i var, ikinci bir abonelik onu ezerdi. Monitor
/// diagRecordConnection()/diag() cagirir, yani loglar ayni kaldi.)
void installDiagnostics() {
  WidgetsBinding.instance.addObserver(_LifecycleLogger());
}

class _LifecycleLogger with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    diagRecordLifecycle(state.name);
    diag('lifecycle $state');
  }
}
