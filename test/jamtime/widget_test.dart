import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/app.dart';

void main() {
  testWidgets('JamTimeApp başlatılıyor ve AuthScreen görünüyor',
      (WidgetTester tester) async {
    // TrackWhitelist.load() gerektiren main() yerine doğrudan JamTimeApp kullan.
    await tester.pumpWidget(const JamTimeApp());
    await tester.pump();

    // Spotify bağlantı butonu AuthScreen'de mevcut olmalı.
    expect(find.text('Spotify ile Bağlan'), findsOneWidget);
  });
}
