import 'package:flutter/material.dart';
import 'app.dart';
import 'diagnostics/diag_log.dart';
import 'features/scanner/track_whitelist.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installDiagnostics(); // GECICI: cihaz testi icin tani loglari
  await TrackWhitelist.load();
  runApp(const JamTimeApp());
}
