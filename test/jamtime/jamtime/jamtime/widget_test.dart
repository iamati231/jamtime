import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('JamTimeApp başlatılıyor ve AuthScreen görünüyor',
      (WidgetTester tester) async {
    // Kurulum işareti yok: uygulama Bağlan ekranıyla başlar. (İşaret varsa doğrudan
    // HomeScreen açılır; bkz. test/features/start/start_gate_test.dart)
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // TrackWhitelist.load() gerektiren main() yerine doğrudan JamTimeApp kullan.
    await tester.pumpWidget(const JamTimeApp());
    await tester.pump(); // işaret okunur
    await tester.pump();

    // Spotify bağlantı butonu AuthScreen'de mevcut olmalı.
    expect(find.text('Spotify ile Bağlan'), findsOneWidget);
  });
}
