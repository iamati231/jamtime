import 'package:flutter/material.dart';
import 'app.dart';
import 'diagnostics/diag_log.dart';
import 'features/auth/spotify_connection_monitor.dart';
import 'features/scanner/track_whitelist.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installDiagnostics(); // GECICI: cihaz testi icin tani loglari
  SpotifyConnectionMonitor.install(); // Baglanti durumuna TEK abonelik (sadece dinler)
  await TrackWhitelist.load();
  runApp(const JamTimeApp());
}
