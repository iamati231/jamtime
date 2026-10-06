import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import '../rules/rules_screen.dart';
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
                  const SizedBox(height: 20),
                  // Nebenaktion: sadece bilgi sayfasini acar (kamera ve Spotify'a dokunmaz)
                  _RulesButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RulesScreen()),
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

/// "Oyun kurallari": NEBEN aksiyon (outlined, cyan); ana aksiyon "QR Tara" kalir.
/// Etiket buyuk yazida alt satira sarilir (Flexible), tasmaz.
class _RulesButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _RulesButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: JamTimeColors.cyan, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, size: 18, color: JamTimeColors.cyan),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Oyun kuralları',
              style: TextStyle(color: JamTimeColors.cyan, letterSpacing: 1),
            ),
          ),
        ],
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
