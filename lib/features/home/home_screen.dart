import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import '../scanner/scanner_screen.dart';
import 'spotify_sheet.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JamTimeColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Spotify menusu: durum + "Baglantiyi kes" / "Hesabi degistir"
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton.icon(
                  onPressed: () => showSpotifySheet(context),
                  icon: const Icon(Icons.headphones, size: 18, color: Colors.white54),
                  label: const Text(
                    'Spotify',
                    style: TextStyle(color: Colors.white54, letterSpacing: 1),
                  ),
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/logo.png',
                    width: MediaQuery.of(context).size.width * 0.9,
                  ),
                  const SizedBox(height: 48),
                  _GradientButton(
                    label: 'QR Tara',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ScannerScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _GradientButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 16),
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
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}
