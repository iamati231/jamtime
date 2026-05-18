import 'package:flutter/material.dart';
import 'config/jamtime_colors.dart';
import 'features/launcher/splash_screen.dart';

class JamTimeApp extends StatelessWidget {
  const JamTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JamTime',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: JamTimeColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: JamTimeColors.purple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Splash, Spotify session varsa otomatik HomeScreen'e geciyor
      home: const SplashScreen(),
    );
  }
}
