import 'dart:async';
import 'package:flutter/material.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/jamtime_colors.dart';
import '../../diagnostics/diag_log.dart';
import '../auth/spotify_auth_service.dart';
import '../scanner/scanner_screen.dart';

/// Song-Mode'dan cikis sekilleri.
enum _LeaveTarget { rescan, exit }

class SongModeScreen extends StatefulWidget {
  const SongModeScreen({super.key, this.playedCode});

  /// Calan kartin QR degeri. Sadece bellekte tutulur, asla loglanmaz. "Durdur ve
  /// yeniden tara" ile acilan scanner'da AYNI kartin (hala goruntudeyken)
  /// yanlislikla tekrar calmasini engellemek icin o scanner'a verilir.
  final String? playedCode;

  @override
  State<SongModeScreen> createState() => _SongModeScreenState();
}

class _SongModeScreenState extends State<SongModeScreen>
    with SingleTickerProviderStateMixin {
  static const _pauseUnconfirmedHint =
      "Müzik durmamış olabilir. Gerekirse Spotify'dan durdurun.";

  late final AnimationController _pulse;
  StreamSubscription? _playerSub;
  bool _isPlaying = true;
  // Iki aksiyon ve geri hareketi icin ORTAK koruma: cift dokunma / farkli buton /
  // geri hareketi ikinci bir pause veya ikinci bir navigasyon baslatmasin.
  bool _leaving = false;

  // ─── init ───────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _subscribeToPlayerState();
  }

  void _subscribeToPlayerState() {
    _playerSub?.cancel();
    _playerSub = SpotifySdk.subscribePlayerState().listen(
      (state) {
        // SADECE isPaused kullanılıyor — track/artist/album asla render edilmiyor
        if (mounted) setState(() => _isPlaying = !state.isPaused);
      },
      onError: (_) {},
    );
  }

  // NOT: Burada lifecycle observer YOK!
  // Daha onceki versiyonda app paused olunca SpotifySdk.disconnect(),
  // resume olunca connect() cagrilirdi → Spotify ile JamTime arasinda
  // SONSUZ DONGU yaratiyordu. Artik:
  //  - Spotify'a git: SDK baglantisi acik kalir, geri donulunce stream
  //    devam eder
  //  - Background/Foreground gecisleri SDK tarafindan otomatik handle
  //    ediliyor, bizim mudahalemize gerek yok

  // ─── actions ────────────────────────────────────────────────────────────────

  /// Muzigi durdurur (pause) ve [target]'a gecer:
  ///  - rescan: bu ekran yeni bir Scanner ile DEGISTIRILIR (pushReplacement), yani
  ///    navigator stack'i turlar boyunca buyumez;
  ///  - exit  : HomeScreen'e doner.
  /// SDK baglantisini KORUR ki sonraki QR scan reconnect'siz calsin.
  /// pause() zaman asimina dusebilir (SDK cevap vermezse); hata veya zaman
  /// asiminda da ekrandan cikilir. Pause onaylanmadiysa kullaniciya muzigin
  /// durmamis olabilecegi soylenir (hedef sayfada gorunur) — "durdu" denmez.
  Future<void> _leave(_LeaveTarget target) async {
    if (_leaving) {
      diag('leave ignored (already leaving)');
      return;
    }
    setState(() => _leaving = true); // butonlar devre disi
    diag('leave begin ($target)');
    _playerSub?.cancel();
    _playerSub = null;
    // Context'e bagli nesneleri await'ten ONCE al.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    var paused = false;
    try {
      paused = await SpotifyAuthService.pause();
      // disconnect ETMIYORUZ — bir sonraki QR scan icin baglanti hazir kalsin.
    } finally {
      diag('leave done (paused=$paused, mounted=$mounted)');
      if (mounted) {
        switch (target) {
          case _LeaveTarget.rescan:
            unawaited(navigator.pushReplacement(
              MaterialPageRoute(
                builder: (_) => ScannerScreen(lockedCode: widget.playedCode),
              ),
            ));
          case _LeaveTarget.exit:
            navigator.popUntil((r) => r.isFirst);
        }
        if (!paused) {
          messenger.showSnackBar(const SnackBar(
            content: Text(_pauseUnconfirmedHint),
            duration: Duration(seconds: 6),
          ));
        }
      }
    }
  }

  /// Kullanıcıyı Spotify uygulamasına deeplink ile yönlendirir.
  /// Track adı/sanatçı bilgisi gösterilmez — sadece uygulama açılır.
  Future<void> _openSpotify() async {
    final uri = Uri.parse('spotify://');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ─── dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _pulse.dispose();
    _playerSub?.cancel();
    super.dispose();
  }

  // ─── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Geri hareketi = "Durdur ve çık"
        if (!didPop) _leave(_LeaveTarget.exit);
      },
      child: Scaffold(
        backgroundColor: JamTimeColors.background,
        body: SafeArea(
          child: Column(
            children: [
              // ── Merkez içerik ─────────────────────────────────────────────
              // Expanded + Center: SafeArea padding'inden bağımsız gerçek merkez
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo — spoiler yok
                      Image.asset(
                        'assets/images/logo.png',
                        width: width * 0.65,
                      ),

                      const SizedBox(height: 48),

                      // Nabız animasyonu
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, child) => Opacity(
                          opacity:
                              _isPlaying ? 0.45 + _pulse.value * 0.55 : 0.25,
                          child: const Icon(
                            Icons.music_note_rounded,
                            size: 80,
                            color: JamTimeColors.cyan,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Oynatma durumu — şarkı adı/sanatçı/kapak asla gösterilmiyor
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        child: Text(
                          _isPlaying ? '♪  Müzik çalıyor' : '⏸  Duraklatıldı',
                          key: ValueKey(_isPlaying),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                            letterSpacing: 2.5,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Alt butonlar ──────────────────────────────────────────────
              // Durdurulurken (max. pause zaman asimi kadar) hepsi devre disi.
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 36),
                child: Opacity(
                  opacity: _leaving ? 0.5 : 1,
                  child: Column(
                    children: [
                      // Durdur ve yeniden tara — ANA aksiyon: durdurur, dogrudan
                      // hazir scanner'a gecer (ek "QR Tara" dokunusu gerekmez)
                      _GradientButton(
                        label: 'Durdur ve yeniden tara',
                        enabled: !_leaving,
                        onPressed: () => _leave(_LeaveTarget.rescan),
                      ),

                      const SizedBox(height: 12),

                      // Spotify'a git — outlined, dikkat çekici ama spoilersız
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _leaving ? null : _openSpotify,
                          icon: const Icon(
                            Icons.open_in_new,
                            size: 16,
                            color: JamTimeColors.cyan,
                          ),
                          label: const Text(
                            'Spotify\'a git',
                            style: TextStyle(
                              color: JamTimeColors.cyan,
                              letterSpacing: 1,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: JamTimeColors.cyan,
                              width: 1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Durdur ve çık — NEBEN aksiyon, kasıtlı olarak soluk
                      TextButton(
                        onPressed: _leaving ? null : () => _leave(_LeaveTarget.exit),
                        child: const Text(
                          'Durdur ve çık',
                          style: TextStyle(
                            color: Colors.white30,
                            fontSize: 14,
                            letterSpacing: 1,
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
      ),
    );
  }
}

/// Ana aksiyon butonu (HomeScreen'deki gradient butonla ayni gorunum).
class _GradientButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  const _GradientButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [JamTimeColors.pink, JamTimeColors.purple, JamTimeColors.cyan],
            ),
            borderRadius: BorderRadius.circular(32),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
