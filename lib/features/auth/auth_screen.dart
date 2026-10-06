import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import 'open_spotify.dart';
import 'spotify_auth_service.dart';
import '../home/home_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.switchAccount = false, this.onOpenSpotify});

  /// "Spotify hesabini degistir" akisinin ikinci adimi: yerel kurulum silindi, bu
  /// ekran kullaniciyi Spotify'da hesabi degistirmeye yonlendirir. Hesabi uygulama
  /// secemez: JamTime Spotify uygulamasinda acik olan hesabi kullanir.
  final bool switchAccount;

  /// Sadece testler icin. Varsayilan: Spotify uygulamasini ac.
  final Future<bool> Function()? onOpenSpotify;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isConnecting = false;
  String? _errorMessage;

  Future<void> _connect() async {
    if (_isConnecting) return;
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    final success = await SpotifyAuthService.connect();

    if (!mounted) return;

    if (success) {
      // Spotify bagli — QR Tara butonlu ana ekrana gec
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      setState(() {
        _isConnecting = false;
        _errorMessage = 'Bağlantı kurulamadı.\nSpotify\'ı açıp giriş yaptıktan sonra tekrar dene.';
      });
    }
  }

  Future<void> _openSpotify() async {
    final opened = await (widget.onOpenSpotify ?? openSpotifyApp)();
    if (!mounted || opened) return;
    setState(() => _errorMessage = 'Spotify uygulaması bulunamadı.');
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: JamTimeColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/logo.png',
                  width: width * (widget.switchAccount ? 0.5 : 0.9),
                ),
                SizedBox(height: widget.switchAccount ? 24 : 48),
                if (widget.switchAccount) ...[
                  _SwitchAccountGuide(onOpenSpotify: _openSpotify),
                  const SizedBox(height: 24),
                ],
                if (_isConnecting)
                  const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation(JamTimeColors.cyan),
                  )
                else
                  _SpotifyButton(onPressed: _connect),
                const SizedBox(height: 16),
                // Kacinilmaz Spotify gecisini onceden acikla (iOS'ta Spotify acilir).
                const Text(
                  'Bağlanırken Spotify kısa süre açılabilir.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 14,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hesap degistirme yonlendirmesi: hesabi Spotify uygulamasinda degistir, geri don,
/// yeniden bagla.
class _SwitchAccountGuide extends StatelessWidget {
  final VoidCallback onOpenSpotify;

  const _SwitchAccountGuide({required this.onOpenSpotify});

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(color: Colors.white70, fontSize: 14, height: 1.4);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: JamTimeColors.cyan.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Spotify hesabını değiştir',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'JamTime, Spotify uygulamasında açık olan hesabı kullanır.',
            style: body,
          ),
          const SizedBox(height: 8),
          const Text(
            '1. Spotify\'ı aç ve hesabını değiştir (çıkış yap, diğer hesapla giriş yap).',
            style: body,
          ),
          const Text('2. Buraya dön.', style: body),
          const Text('3. "Spotify ile Bağlan"a dokun.', style: body),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onOpenSpotify,
            icon: const Icon(Icons.open_in_new, size: 16, color: JamTimeColors.cyan),
            label: const Text(
              'Spotify\'ı aç',
              style: TextStyle(color: JamTimeColors.cyan, letterSpacing: 1),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: JamTimeColors.cyan, width: 1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotifyButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _SpotifyButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [JamTimeColors.pink, JamTimeColors.purple, JamTimeColors.cyan],
          ),
          borderRadius: BorderRadius.circular(32),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones, color: Colors.white, size: 20),
            SizedBox(width: 10),
            // Flexible: grosse Yazi boyutunda (Dynamic Type) satir kirilir, tasmaz.
            Flexible(
              child: Text(
                'Spotify ile Bağlan',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
