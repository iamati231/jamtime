import 'package:flutter/material.dart';
import 'app.dart';
import 'features/scanner/track_whitelist.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TrackWhitelist.load();
  runApp(const JamTimeApp());
}
