import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import 'spotify_auth_service.dart';
import '../scanner/scanner_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isConnecting = false;
  String? _errorMessage;

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    final success = await SpotifyAuthService.connect();

    if (!mounted) return;

    if (success) {
      // Spotify bagli — direkt QR tarama ekranina gec
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ScannerScreen()),
      );
    } else {
      setState(() {
        _isConnecting = false;
        _errorMessage = 'Bağlantı kurulamadı.\nSpotify\'ı açıp giriş yaptıktan sonra tekrar dene.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JamTimeColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/logo.png',
                  width: MediaQuery.of(context).size.width * 0.9,
                ),
                const SizedBox(height: 48),
                if (_isConnecting)
                  const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation(JamTimeColors.cyan),
                  )
                else
                  _SpotifyButton(onPressed: _connect),
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
            Text(
              'Spotify ile Bağlan',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
