import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import '../auth/auth_screen.dart';
import '../auth/spotify_auth_service.dart';
import '../home/home_screen.dart';

/// Uygulamanin ilk ekrani. Kalici "kurulum yapildi" isaretine bakar:
///  - isaret VAR  -> dogrudan HomeScreen. Burada HICBIR Spotify cagrisi yapilmaz ve
///    Spotify'a gecilmez; baglanti ancak bilincli bir calma (QR) ya da baglanti
///    eyleminde kurulur. (Acilista otomatik baglanma Spotify'i her acilista aciyordu;
///    5813e07'de eklendi, cb58cdd'de geri alindi.)
///  - isaret YOK ya da okunamadi -> AuthScreen.
/// Isaret "su an bagli" veya "token gecerli" anlamina GELMEZ.
class StartGate extends StatefulWidget {
  const StartGate({super.key});

  @override
  State<StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<StartGate> {
  late final Future<bool> _setupDone = SpotifyAuthService.hasCompletedSetup();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _setupDone,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Isaret okunurken sadece arka plan (yerel okuma, milisaniyeler).
          return const Scaffold(backgroundColor: JamTimeColors.background);
        }
        return snapshot.data == true ? const HomeScreen() : const AuthScreen();
      },
    );
  }
}
