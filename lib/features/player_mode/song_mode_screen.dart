import 'dart:async';
import 'package:flutter/material.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/jamtime_colors.dart';
import '../auth/spotify_auth_service.dart';

class SongModeScreen extends StatefulWidget {
  const SongModeScreen({super.key});

  @override
  State<SongModeScreen> createState() => _SongModeScreenState();
}

class _SongModeScreenState extends State<SongModeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  StreamSubscription? _playerSub;
  bool _isPlaying = true;

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

  /// Müziği durdurur (pause) ve HomeScreen'e döner.
  /// SDK baglantisini KORUR ki sonraki QR scan reconnect'siz calsin.
  Future<void> _stopAndReturn() async {
    _playerSub?.cancel();
    _playerSub = null;
    await SpotifyAuthService.pause();
    // disconnect ETMIYORUZ — bir sonraki QR scan icin baglanti hazir kalsin.
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
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
        if (!didPop) _stopAndReturn();
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
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 36),
                child: Column(
                  children: [
                    // Spotify'a git — outlined, dikkat çekici ama spoilersız
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openSpotify,
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

                    // Durdur ve çık — kasıtlı olarak soluk
                    TextButton(
                      onPressed: _stopAndReturn,
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
            ],
          ),
        ),
      ),
    );
  }
}
