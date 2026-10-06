import 'dart:math';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../config/jamtime_colors.dart';
import '../../diagnostics/diag_log.dart';
import '../auth/spotify_auth_service.dart';
import '../auth/spotify_connection_monitor.dart';
import '../player_mode/song_mode_screen.dart';
import '../permissions/permission_service.dart';
import 'qr_handler.dart';
import 'scan_overlay_painter.dart';

enum _ScanState { idle, validDetected, invalidDetected }

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.lockedCode});

  /// "Durdur ve yeniden tara" sonrasi: az once calan kartin QR degeri. Bu kod
  /// goruntudeyken otomatik TEKRAR calmaz (kart cekilmis sayilmaz — eksik callback
  /// "kart yok" demek degildir). Baska bir gecerli kart hemen calar; ayni kart
  /// ancak "Aynı kartı tekrar tara" ile acilir — bu aksiyon da sadece kilitli kart
  /// gercekten tekrar algilandiktan sonra gorunur. Sadece bellekte, asla loglanmaz.
  final String? lockedCode;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController();
  CameraPermissionResult _permission = CameraPermissionResult.denied;
  _ScanState _scanState = _ScanState.idle;
  bool _connectFailed = false; // bağlantı hata mesajı için
  late final Color _borderColor;
  PlaybackAttempt? _attempt; // bu ekranin son calma denemesi; dispose'da iptal edilir
  // Kilitli kartlar: az once calan kart ("Durdur ve yeniden tara" sonrasi,
  // widget.lockedCode) ve calmayi BASARAMAYAN her kart. Kilitli bir kart gorunur kalsa
  // da otomatik tekrar denenmez (her deneme bir Spotify gecisi demektir). TEK kod
  // degil KUME: iki kart birlikte gorunurse biri digerini acmasin ve kilitli kart
  // kilitli olmayani gizlemesin (bkz. onDetect). Sadece bellekte, asla loglanmaz.
  final Set<String> _lockedCodes = <String>{};
  // _lockedCodes'in calmayi BASARAMAYAN kartlar olan alt kumesi ("Yeniden bagla" basarili
  // olunca SADECE bunlar acilir; "az once calan" kart kilitli kalir).
  final Set<String> _failedCodes = <String>{};
  // Kilitli kartlardan en son tekrar algilanan. Ancak o zaman "Aynı kartı tekrar tara"
  // gosterilir ve SADECE bu kodu acar. Zamanlayici yok; "kart cekildi" cikarimi yok
  // (callback gelmemesi belirsiz) — bu yuzden teklif kendiliginden kalkmaz.
  String? _seenLockedCode;
  // Baglanti BILINEN sekilde yoksa kacinilmaz Spotify gecisini onceden acikla
  // ("Spotify'a baglaniyor" altinda "Spotify kisa sure acilabilir").
  bool _hopHint = false;
  // Son calma denemesi basarisiz oldu: "Yeniden bagla" (interaktif, login zaman
  // asimi 90 sn) teklif edilir. Otomatik tarama reconnect'i 15 sn'de KALIR.
  bool _needsReconnect = false;
  final DiagGapStats _lockStats = DiagGapStats(); // GECICI tani: sadece sayilar

  @override
  void initState() {
    super.initState();
    final locked = widget.lockedCode;
    if (locked != null) _lockedCodes.add(locked);
    WidgetsBinding.instance.addObserver(this);
    _borderColor = JamTimeColors.borderColors[Random().nextInt(JamTimeColors.borderColors.length)];
    _requestPermission();
  }

  Future<void> _requestPermission() async {
    final result = await PermissionService.requestCamera();
    if (mounted) setState(() => _permission = result);
  }

  Future<void> _openSettingsAndRecheck() async {
    await PermissionService.openSettings();
    // Settings'ten geri donunce didChangeAppLifecycleState resumed tetiklenecek
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ONEMLI: _scanState'i RESET ETME — bir QR yakalandiysa
      // Spotify'dan donus sirasinda tekrar tetiklenmesin.
      // Sadece kamera izni Settings'ten donulmus olabilir, onu kontrol et.
      _refreshPermissionIfMissing();
    }
  }

  Future<void> _refreshPermissionIfMissing() async {
    if (_permission == CameraPermissionResult.granted) return;
    final result = await PermissionService.checkCamera();
    if (mounted) setState(() => _permission = result);
  }

  /// Kilitli kart icin kullanici bilincli olarak "tekrar tara" dedi: SADECE bu kartin
  /// kilidi kalkar, sonraki algilamasi normal calar. Diger kilitli kartlar kilitli kalir.
  void _unlockSameCard() {
    final code = _seenLockedCode;
    if (code == null) return;
    diag('same-card lock released by user');
    _logLockStats('released');
    setState(() {
      _lockedCodes.remove(code);
      _failedCodes.remove(code);
      _seenLockedCode = null;
    });
  }

  /// GECICI tani: kilitli kartin algilama aralik istatistigi (sadece sayilar).
  void _logLockStats(String why) {
    if (_lockStats.hits == 0) return;
    diag('lock stats ($why) ${_lockStats.summary()}');
    _lockStats.reset();
  }

  /// "Yeniden bagla": kullanicinin BILINCLI eylemi. Interaktif baglanti, login
  /// zaman asimini (90 sn) kullanir; kullanici Spotify'da izin/giris yapiyor olabilir.
  /// Basarili olursa kilitli BASARISIZ kartlar acilir: gorunur kart simdi calar.
  /// ("Az once calan" kart, widget.lockedCode, kilitli kalir.)
  /// Calisirken tarama durumu "baglaniyor"dur, yani yeni algilamalar yok sayilir.
  Future<void> _reconnectInteractively() async {
    if (_scanState != _ScanState.idle) return;
    setState(() {
      _scanState = _ScanState.validDetected;
      _hopHint = true;
      _connectFailed = false;
    });
    // connect()'in varsayilan zaman limiti login zaman asimidir (90 sn).
    final ok = await SpotifyAuthService.connect();
    if (!mounted) return;
    if (ok) {
      setState(() {
        _scanState = _ScanState.idle;
        _hopHint = false;
        _needsReconnect = false;
        _lockedCodes.removeAll(_failedCodes);
        _failedCodes.clear();
        _seenLockedCode = null;
      });
      return;
    }
    setState(() {
      _scanState = _ScanState.invalidDetected;
      _connectFailed = true;
    });
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) {
      setState(() {
        _scanState = _ScanState.idle;
        _connectFailed = false;
      });
    }
  }

  Future<void> _onQrDetected(String value) async {
    if (_scanState != _ScanState.idle) return;

    // Az once calan ya da calamayan kart: otomatik tekrar deneme. Burada "kart
    // cekildi" cikarimi YAPILMAZ (mobile_scanner kod kaybolunca olay gondermez; eksik
    // callback bulaniklik/isik/odak da olabilir). Baska bir kart bu kontrolden gecer.
    if (_lockedCodes.contains(value)) {
      _lockStats.hit(); // GECICI tani
      // Kilitli kart gercekten tekrar algilandi: simdi (ve ancak simdi) teklif et.
      if (_seenLockedCode != value) setState(() => _seenLockedCode = value);
      return;
    }

    if (QrHandler.isAllowed(value)) {
      setState(() {
        _scanState = _ScanState.validDetected;
        _connectFailed = false;
        _seenLockedCode = null; // baska kart kabul edildi: eski gorus gecersiz
        _hopHint = !SpotifyConnectionMonitor.isConnected;
      });
      // Onceki "muzik durmamis olabilir" uyarisi yeni kartin arayuzune tasinmasin.
      ScaffoldMessenger.of(context).clearSnackBars();

      diag('scan accepted ${diagStateSummary()}');
      // Her gecerli tarama kendi denemesini alir; kamera durdurulurken ekran
      // kapanirsa playTrack hic SDK cagrisi baslatmaz.
      final attempt = SpotifyAuthService.beginAttempt();
      _attempt = attempt;

      // KRITIK: Scanner'i hemen durdur ki Spotify'a gecip donulunce
      // ayni QR tekrar tetiklenmesin (sonsuz dongu fix).
      try {
        await diagTimed('camera.stop', () => _controller.stop());
      } catch (_) {}

      // Sarki cal — connect() AuthScreen'de yapildi, burada tekrar yapmaya
      // gerek yok (her connect Spotify app'ini aciyor). Direkt play.
      // playTrack zaman asimina duser ve hatalari kendisi yakalar; yine de
      // beklenmedik bir hatada state "validDetected"da takili kalmasin.
      var played = false;
      final sw = Stopwatch()..start();
      try {
        played = await SpotifyAuthService.playTrack(value, attempt: attempt);
      } catch (e) {
        debugPrint('[Scanner] playTrack unexpected error: ${e.runtimeType}');
      }
      diag('playTrack played=$played ${sw.elapsedMilliseconds}ms');
      if (!mounted) return;

      if (!played) {
        // Baglanti dustu/sarki calmadi — kullaniciya bildir. Karti KILITLE: kamera
        // yeniden basladiginda hala gorunen bir QR otomatik yeni bir reconnect (ve
        // Spotify gecisi) dongusu baslatmasin; ayni kart ancak acik eylemle yeniden
        // denenir ("Aynı kartı tekrar tara" / "Yeniden bağla"). Baska kart hemen calar.
        setState(() {
          _scanState = _ScanState.invalidDetected;
          _connectFailed = true;
          _lockedCodes.add(value);
          _failedCodes.add(value);
          _seenLockedCode = null;
          _needsReconnect = true;
        });
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) {
          setState(() {
            _scanState = _ScanState.idle;
            _connectFailed = false;
          });
          // Scanner'i tekrar baslat (yeniden denenebilsin)
          try { await _controller.start(); } catch (_) {}
          diag('scanner restarted running=${_controller.value.isRunning} '
              'error=${_controller.value.error?.errorCode.name}');
        }
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => SongModeScreen(playedCode: value)),
      );
    } else if (value.startsWith('https://')) {
      setState(() {
        _scanState = _ScanState.invalidDetected;
        _connectFailed = false;
      });
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) setState(() => _scanState = _ScanState.idle);
    }
  }

  Color get _activeBorderColor => switch (_scanState) {
        _ScanState.validDetected => JamTimeColors.cyan,
        _ScanState.invalidDetected => Colors.redAccent,
        _ScanState.idle => _borderColor,
      };

  @override
  void dispose() {
    // Sadece KENDI denemesini iptal et; baska bir ekranin daha yeni denemesi
    // (ornegin yeni acilan scanner) etkilenmez.
    _attempt?.cancel();
    _logLockStats('dispose');
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_permission != CameraPermissionResult.granted) {
      return _PermissionScreen(
        permission: _permission,
        onRequest: _requestPermission,
        onOpenSettings: _openSettingsAndRecheck,
        onBack: () => Navigator.of(context).pop(),
      );
    }

    return Scaffold(
      backgroundColor: JamTimeColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final scanSize = size.width * 0.65;
          final scanWindow = Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 2 - 40),
            width: scanSize,
            height: scanSize,
          );

          return MobileScanner(
            controller: _controller,
            scanWindow: scanWindow,
            onDetect: (capture) {
              // Bir karede birden fazla kod olabilir. Kilitli bir kart listede ilk sirada
              // olsa da kilitli OLMAYAN karti gizlemesin: once kilitli olmayan ilk kodu al;
              // hepsi kilitliyse ilkini (kilitli kartin "tekrar algilandi" bilgisi icin).
              final values = [
                for (final barcode in capture.barcodes)
                  if (barcode.rawValue != null) barcode.rawValue!,
              ];
              if (values.isEmpty) return;
              _onQrDetected(
                values.firstWhere((v) => !_lockedCodes.contains(v), orElse: () => values.first),
              );
            },
            overlayBuilder: (context, constraints) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: ScanOverlayPainter(
                        scanWindow: scanWindow,
                        borderColor: _activeBorderColor,
                      ),
                    ),
                  ),

                  // Logo + başlık (üst)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 16,
                    left: 0,
                    right: 0,
                    child: Column(
                      children: [
                        Image.asset('assets/images/logo.png', width: 160),
                      ],
                    ),
                  ),

                  // Geri butonu
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 8,
                    left: 4,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 24),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),

                  // Durum mesajı
                  Positioned(
                    top: scanWindow.bottom + 28,
                    left: 0,
                    right: 0,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: switch (_scanState) {
                        _ScanState.idle => Text(
                            'Kartı okutun',
                            key: const ValueKey('idle'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _borderColor.withValues(alpha: 0.85),
                              fontSize: 16,
                              letterSpacing: 1.5,
                            ),
                          ),
                        _ScanState.validDetected => Column(
                            key: const ValueKey('valid'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Spotify\'a bağlanıyor...',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: JamTimeColors.cyan,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              // Kacinilmaz Spotify gecisini onceden acikla.
                              if (_hopHint)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Text(
                                    'Spotify kısa süre açılabilir.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white54, fontSize: 13),
                                  ),
                                ),
                            ],
                          ),
                        _ScanState.invalidDetected => Text(
                            _connectFailed
                                ? 'Spotify bağlantısı kurulamadı'
                                : 'Bu bir JamTime QR kodu değil',
                            key: const ValueKey('invalid'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      },
                    ),
                  ),

                  // Bilincli eylemler (sadece bosta iken):
                  //  - "Yeniden bağla": son deneme basarisiz oldu (interaktif, 90 sn).
                  //  - "Aynı kartı tekrar tara": kilitli kart tekrar algilandi; az
                  //    once calan veya calamayan kart otomatik tekrar denenmez.
                  // Normal taramada ekran bunlardan bos kalir.
                  if (_scanState == _ScanState.idle &&
                      (_needsReconnect || _seenLockedCode != null))
                    Positioned(
                      top: scanWindow.bottom + 72,
                      left: 0,
                      right: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_needsReconnect)
                            TextButton(
                              onPressed: _reconnectInteractively,
                              child: const Text(
                                'Yeniden bağla',
                                style: TextStyle(
                                  color: JamTimeColors.cyan,
                                  fontSize: 14,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          if (_seenLockedCode != null)
                            TextButton(
                              onPressed: _unlockSameCard,
                              child: const Text(
                                'Aynı kartı tekrar tara',
                                style: TextStyle(
                                  color: JamTimeColors.cyan,
                                  fontSize: 14,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================================
// IZIN EKRANI
// ============================================================================
class _PermissionScreen extends StatelessWidget {
  final CameraPermissionResult permission;
  final VoidCallback onRequest;
  final VoidCallback onOpenSettings;
  final VoidCallback onBack;

  const _PermissionScreen({
    required this.permission,
    required this.onRequest,
    required this.onOpenSettings,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    // Kalici red veya restricted -> sadece Settings'ten cozulebilir
    final mustOpenSettings = permission == CameraPermissionResult.permanentlyDenied ||
        permission == CameraPermissionResult.restricted;

    final title = mustOpenSettings
        ? 'Ayarlardan izin verin'
        : 'Kamera izni gerekli';

    final subtitle = mustOpenSettings
        ? 'iPhone Ayarlar > JamTime menusunden kamera iznini aciniz.\nAyarlar uygulamasi acilacak.'
        : 'QR kodlari taramak icin kamera izni gerekli.';

    final buttonLabel = mustOpenSettings ? 'Ayarlari Ac' : 'Izin Ver';
    final buttonAction = mustOpenSettings ? onOpenSettings : onRequest;

    return Scaffold(
      backgroundColor: JamTimeColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white70),
                onPressed: onBack,
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset('assets/images/logo.png', width: 140),
                    const SizedBox(height: 32),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 32),
                    GestureDetector(
                      onTap: buttonAction,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              JamTimeColors.pink,
                              JamTimeColors.purple,
                              JamTimeColors.cyan,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(32),
                        ),
                        child: Text(
                          buttonLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
