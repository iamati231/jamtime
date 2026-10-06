import 'package:flutter/material.dart';
import 'config/jamtime_colors.dart';
import 'features/start/start_gate.dart';

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
      home: const StartGate(),
    );
  }
}
