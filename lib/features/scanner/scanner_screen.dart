import 'dart:math';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../config/jamtime_colors.dart';
import '../auth/spotify_auth_service.dart';
import '../player_mode/song_mode_screen.dart';
import '../permissions/permission_service.dart';
import 'qr_handler.dart';
import 'scan_overlay_painter.dart';

enum _ScanState { idle, validDetected, invalidDetected }

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController();
  CameraPermissionResult _permission = CameraPermissionResult.denied;
  _ScanState _scanState = _ScanState.idle;
  bool _connectFailed = false; // bağlantı hata mesajı için
  late final Color _borderColor;

  @override
  void initState() {
    super.initState();
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
      setState(() => _scanState = _ScanState.idle);
      // Settings'ten donulmus olabilir, izin durumunu yeniden kontrol et
      _refreshPermissionIfMissing();
    }
  }

  Future<void> _refreshPermissionIfMissing() async {
    if (_permission == CameraPermissionResult.granted) return;
    final result = await PermissionService.checkCamera();
    if (mounted) setState(() => _permission = result);
  }

  Future<void> _onQrDetected(String value) async {
    if (_scanState != _ScanState.idle) return;

    if (QrHandler.isAllowed(value)) {
      setState(() {
        _scanState = _ScanState.validDetected;
        _connectFailed = false;
      });

      // App Remote bağlantısı kur
      final connected = await SpotifyAuthService.connect();
      if (!mounted) return;

      if (!connected) {
        // Spotify yüklü değil veya giriş yapılmamış
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
        return;
      }

      // Çal — müzik 1-2 saniye içinde başlar
      await SpotifyAuthService.playTrack(value);
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SongModeScreen()),
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
              final barcode = capture.barcodes.firstOrNull;
              if (barcode?.rawValue != null) {
                _onQrDetected(barcode!.rawValue!);
              }
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
                        _ScanState.validDetected => const Text(
                            'Spotify\'a bağlanıyor...',
                            key: ValueKey('valid'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: JamTimeColors.cyan,
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 1.5,
                            ),
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
