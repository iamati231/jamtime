import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import '../auth/auth_screen.dart';
import '../auth/spotify_auth_service.dart';
import '../home/home_screen.dart';

/// App acilisinda gosterilen splash.
/// Spotify oturumu varsa otomatik HomeScreen'e gecer,
/// yoksa AuthScreen'e dusuruyor.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Splash en az yarim saniye gozuksun (UX icin)
    final delay = Future.delayed(const Duration(milliseconds: 600));
    final connected = await SpotifyAuthService.trySilentConnect();
    await delay;

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => connected ? const HomeScreen() : const AuthScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JamTimeColors.background,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/logo.png',
                width: MediaQuery.of(context).size.width * 0.75,
              ),
              const SizedBox(height: 32),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(JamTimeColors.cyan),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
