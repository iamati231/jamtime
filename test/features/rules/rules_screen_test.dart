import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/features/auth/spotify_auth_service.dart';
import 'package:jamtime/features/auth/spotify_connection_monitor.dart';
import 'package:jamtime/features/auth/spotify_session_store.dart';
import 'package:jamtime/features/rules/rules_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/channel_guard.dart';

// The "Oyun kuralları" page: local, scrollable, the text exactly as approved, and it
// touches nothing (no Spotify, camera, permission or link service).

const _failFast = Timeout(Duration(seconds: 10));
final _markerKey = PrefsSpotifySessionStore.key;

const _title = 'Oyun kuralları';

// ─── The approved text, word for word. This is the oracle: the page must show exactly
// this, nothing more (no extra rules) and nothing changed. ──────────────────────────
const _headings = <String>[
  'JamTime nasıl oynanır?',
  'Üç basit adım',
  'QR kodu tara',
  'Kartı yerleştir',
  'Kartı aç',
  'JamTime jetonları',
];

const _premiumNote = "JamTime'da QR kodla seçilen şarkıları çalmak için Spotify Premium gerekir.";
const _goal =
    'Amaç, eskiden yeniye doğru sıralanmış 10 karttan oluşan bir müzik zaman çizelgesi '
    'oluşturmak.';

const _paragraphs = <String>[
  // intro
  'JamTime, herkesin kolayca öğrenebileceği üç basit adımda oynanır: QR kodu tara, kartı '
      'yerleştir ve kartı aç. JamTime jetonları ise oyunun gidişatını değiştirebilir. İşte '
      'bilmen gereken temel kurallar!',
  // step 1
  'Kapalı desteden bir müzik kartı çek, ancak kartı henüz çevirme! Kartın arkasındaki QR '
      'kodu JamTime uygulamasıyla tara. Tarama tamamlandığında Spotify şarkıyı çalar. '
      'Şarkının bilgilerine gizlice bakmak yok!',
  _premiumNote,
  // step 2
  'Şarkı çalmaya başladığında kartı çevirmeden, zaman çizelgende doğru olduğunu '
      'düşündüğün yere yerleştir. Yeni kartı, önceden yerleştirdiğin kartların arasına '
      'veya yanına koyabilirsin.',
  _goal,
  // step 3
  'Kartını yerleştirdikten sonra çevir ve yılını kontrol et.',
  'Kart doğru yerdeyse: Tebrikler! Zaman çizelgen büyür ve kart sende kalır.',
  'Kart yanlış yerdeyse: Kartı oyun dışına ayrılan kartların bulunduğu desteye koy. Başka '
      'bir oyuncu JamTime jetonunu doğru kullandıysa kartı o kazanır ve kendi zaman '
      'çizelgesine ekleyebilir.',
  // tokens
  'Her oyuncu oyuna 2 JamTime jetonuyla başlar. Şarkının adını ve sanatçısını doğru tahmin '
      'ederek ek jeton kazanabilirsin. Aynı anda en fazla 5 jetonun olabilir.',
  'Dikkat: Yılı yanlış tahmin etsen bile şarkının adını ve sanatçısını doğru bilirsen bir '
      'jeton kazanırsın.',
  'Jetonlarını üç şekilde kullanabilirsin:',
  'Kendi sıranda yeni kart çekmek: Şarkıyı tanımıyor musun? Bir jeton ver, mevcut kartı '
      'oyun dışına ayır ve yeni bir kart çek.',
  'Başka bir oyuncunun kartını kazanmak: Diğer oyuncunun kartı yanlış yere koyduğunu mu '
      'düşünüyorsun? Kart açılmadan önce “JAMTIME!” diye seslen. Bir jetonunu, kartın doğru '
      'olduğunu düşündüğün yere koy. Tahminin doğruysa kartı sen kazanırsın.',
  'Kart satın almak: İstediğin zaman 3 jeton vererek bir müzik kartı satın alabilir ve '
      'yılını tahmin etmek zorunda kalmadan doğrudan zaman çizelgene yerleştirebilirsin.',
];

// Decoration only (the step / use numbers and the bullet of the two outcomes).
const _decoration = <String>['1', '2', '3', '•'];

Widget _app(Widget home, {double textScale = 1}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

/// The rules page as the only route, on a screen of [size] logical pixels.
Future<void> _show(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double ratio = 3,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(size.width * ratio, size.height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(const RulesScreen(), textScale: textScale));
  await tester.pumpAndSettle();
}

Finder _text(String text) => find.text(text, findRichText: true);

void main() {
  setUp(() async {
    SpotifyAuthService.debugReset();
    await SpotifyConnectionMonitor.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('content', () {
    testWidgets('shows the title, the headings and every approved paragraph exactly once',
        (tester) async {
      await _show(tester);

      expect(find.text(_title), findsOneWidget, reason: 'app bar title');
      for (final heading in _headings) {
        expect(find.text(heading), findsOneWidget, reason: heading);
      }
      for (final paragraph in _paragraphs) {
        expect(_text(paragraph), findsOneWidget, reason: paragraph);
      }
    }, timeout: _failFast);

    testWidgets('shows nothing but the approved text (no extra rules)', (tester) async {
      await _show(tester);

      final approved = <String>{_title, ..._headings, ..._paragraphs, ..._decoration};
      final shown = <String>[
        for (final element in find.byType(Text, skipOffstage: false).evaluate())
          () {
            final text = element.widget as Text;
            return text.data ?? text.textSpan!.toPlainText();
          }(),
      ];
      expect(shown.where((t) => !approved.contains(t)), isEmpty,
          reason: 'every text on the page must be part of the approved text');
    }, timeout: _failFast);

    testWidgets('has the Premium note and nothing about Free, a DJ, clips or "10 yıl"',
        (tester) async {
      await _show(tester);

      expect(_text(_premiumNote), findsOneWidget);
      expect(find.textContaining('Premium', findRichText: true), findsOneWidget,
          reason: 'one single Premium note');
      for (final banned in ['ücretsiz', 'Free', 'DJ', 'klip', 'Clip', '10 yıl', 'Hitster']) {
        expect(find.textContaining(banned, findRichText: true), findsNothing, reason: banned);
      }
      expect(_text(_goal), findsOneWidget, reason: 'the goal says "10 karttan"');
    }, timeout: _failFast);

    testWidgets('has no links (no tappable text, no web view)', (tester) async {
      await _show(tester);

      expect(find.byType(InkWell), findsNothing, reason: 'only the back arrow may be tappable');
      expect(find.byType(GestureDetector).evaluate().where((e) {
        final detector = e.widget as GestureDetector;
        return detector.onTap != null || detector.onTapUp != null;
      }), isEmpty);
    }, timeout: _failFast);
  });

  group('layout', () {
    testWidgets('on a small phone every part can be scrolled into view', (tester) async {
      await _show(tester, size: const Size(320, 568), ratio: 2);

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
            of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0),
          reason: 'the page is longer than the screen, so it must scroll');

      // The test font (Ahem) is much wider than a real one, so a paragraph can be taller
      // than the screen here: what counts is that its beginning can be scrolled into view,
      // inside the screen sideways, and that the end of the page can be reached.
      for (final paragraph in _paragraphs) {
        await tester.ensureVisible(_text(paragraph));
        await tester.pump();
        final rect = tester.getRect(_text(paragraph));
        expect(rect.left >= 0 && rect.right <= 320 && rect.top >= 0 && rect.top < 568, isTrue,
            reason: 'reachable inside the screen: $paragraph (rect $rect)');
      }
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      expect(tester.getRect(_text(_paragraphs.last)).bottom, lessThanOrEqualTo(568),
          reason: 'the end of the page is reachable');
    }, timeout: _failFast);

    // Small phones and large system fonts: no overflow, nothing cut off sideways, and the
    // last paragraph can still be reached.
    const cases = <(Size, double)>[
      (Size(320, 568), 1.0),
      (Size(320, 568), 2.0),
      (Size(375, 667), 3.0),
    ];
    for (final (size, scale) in cases) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} with text x$scale: '
          'no overflow, scrolls to the end', (tester) async {
        await _show(tester, size: size, ratio: 2, textScale: scale);
        expect(tester.takeException(), isNull, reason: 'RenderFlex overflow or similar');

        expect(
          tester.widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView)),
          everyElement(predicate<SingleChildScrollView>(
              (w) => w.scrollDirection == Axis.vertical,
              'scrolls vertically only')),
        );

        for (final paragraph in [..._paragraphs].reversed) {
          await tester.ensureVisible(_text(paragraph));
          await tester.pump();
          final rect = tester.getRect(_text(paragraph));
          expect(rect.left >= 0 && rect.right <= size.width, isTrue,
              reason: 'not cut off sideways: $paragraph');
        }
        expect(tester.takeException(), isNull);
      }, timeout: _failFast);
    }
  });

  group('navigation', () {
    Future<void> showRoot(WidgetTester tester) async {
      await tester.pumpWidget(_app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RulesScreen()),
                ),
                child: const Text('root'),
              ),
            ),
          ),
        ),
      ));
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('root'));
      await tester.pumpAndSettle();
      expect(find.byType(RulesScreen), findsOneWidget);
      expect(find.text('root'), findsNothing, reason: 'the rules page is on top');
    }

    testWidgets('the back arrow returns to the previous page', (tester) async {
      await showRoot(tester);
      await open(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(RulesScreen), findsNothing);
      expect(find.text('root'), findsOneWidget);
    }, timeout: _failFast);

    testWidgets('the system back (Android) returns to the previous page', (tester) async {
      await showRoot(tester);
      await open(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(RulesScreen), findsNothing);
      expect(find.text('root'), findsOneWidget);
    }, timeout: _failFast);
  });

  group('no side effects', () {
    testWidgets(
        'opening and closing touches no Spotify, camera, permission or link service and '
        'changes neither the connection state, the marker nor a running attempt',
        (tester) async {
      final guard = ChannelGuard.install();
      SharedPreferences.setMockInitialValues(<String, Object>{_markerKey: true});
      await SpotifyConnectionMonitor.debugReset(to: SpotifyLink.connected);
      final attempt = SpotifyAuthService.beginAttempt(); // a playback that is still current

      await tester.pumpWidget(_app(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RulesScreen()),
            ),
            child: const Text('root'),
          ),
        ),
      ));
      await tester.tap(find.text('root'));
      await tester.pumpAndSettle();
      expect(find.byType(RulesScreen), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(RulesScreen), findsNothing);

      expect(guard.calls, isEmpty, reason: 'no platform call at all');
      expect(SpotifyConnectionMonitor.isConnected, isTrue, reason: 'connection state kept');
      expect(attempt.isCurrent, isTrue, reason: 'a running playback attempt is not invalidated');
      expect((await SharedPreferences.getInstance()).getBool(_markerKey), isTrue,
          reason: 'the stored setup marker is untouched');
    }, timeout: _failFast);
  });
}
