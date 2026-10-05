import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jamtime/diagnostics/diag_log.dart';

// Reine Mess-Hilfen (GECICI): sie duerfen nichts ausser Zustandsnamen, Zahlen und
// Dauern ausgeben. Diese Tests pruefen Format und Rechnung; ob ein sichtbarer
// Code auf dem iPhone regelmaessig gemeldet wird, zeigt erst die Gerätemessung.

List<String> _captureLogs(void Function() body) {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
  try {
    body();
  } finally {
    debugPrint = original;
  }
  return lines;
}

void main() {
  tearDown(diagResetState);

  group('diagStateSummary', () {
    test('is "unknown" before any event arrived', () {
      expect(diagStateSummary(), 'lastConn=unknown(-) lastLifecycle=-(-)');
    });

    test('reports the last connection state and lifecycle event with their age', () {
      final t0 = DateTime(2026, 1, 1, 12);
      diagRecordConnection(false, at: t0);
      diagRecordLifecycle('resumed', at: t0.add(const Duration(seconds: 50)));

      expect(
        diagStateSummary(now: t0.add(const Duration(seconds: 63, milliseconds: 200))),
        'lastConn=disconnected(63.2s) lastLifecycle=resumed(13.2s)',
      );
    });

    test('a newer event replaces the older one', () {
      final t0 = DateTime(2026, 1, 1, 12);
      diagRecordConnection(false, at: t0);
      diagRecordConnection(true, at: t0.add(const Duration(seconds: 10)));

      expect(
        diagStateSummary(now: t0.add(const Duration(seconds: 12))),
        'lastConn=connected(2.0s) lastLifecycle=-(-)',
      );
    });

    test('contains only state names and numbers', () {
      final t0 = DateTime(2026, 1, 1, 12);
      diagRecordConnection(true, at: t0);
      diagRecordLifecycle('paused', at: t0);

      expect(
        diagStateSummary(now: t0.add(const Duration(seconds: 1))),
        matches(RegExp(r'^lastConn=(unknown|connected|disconnected)\([-0-9.]+s?\) '
            r'lastLifecycle=[a-z-]+\([-0-9.]+s?\)$')),
      );
    });
  });

  group('DiagGapStats', () {
    /// A fake clock that advances by the given offsets on every hit.
    DiagGapStats statsFor(List<int> hitOffsetsMs) {
      final t0 = DateTime(2026, 1, 1);
      var i = 0;
      return DiagGapStats(now: () => t0.add(Duration(milliseconds: hitOffsetsMs[i++])));
    }

    test('a single hit has no gap yet', () {
      final stats = statsFor([0])..hit();
      expect(stats.summary(), 'hits=1');
    });

    test('min / max / avg of the gaps between consecutive hits', () {
      final stats = statsFor([0, 250, 500, 2230]);
      for (var i = 0; i < 4; i++) {
        stats.hit();
      }
      // gaps: 250, 250, 1730
      expect(stats.summary(), 'hits=4 gaps(ms) min=250 max=1730 avg=743');
    });

    test('a long gap is logged at once, as a number only', () {
      final stats = statsFor([0, 250, 2250]);
      final lines = _captureLogs(() {
        stats
          ..hit()
          ..hit()
          ..hit(); // 2000 ms gap
      });

      final gapLines = lines.where((l) => l.contains('detection gap')).toList();
      expect(gapLines, hasLength(1));
      expect(gapLines.single, endsWith('detection gap 2000ms'));
    });

    test('gaps up to the threshold are not logged individually', () {
      final stats = statsFor([0, 250, 1250]); // gaps 250 and 1000 (== threshold)
      final lines = _captureLogs(() {
        stats
          ..hit()
          ..hit()
          ..hit();
      });
      expect(lines.where((l) => l.contains('detection gap')), isEmpty);
    });

    test('reset starts over', () {
      final stats = statsFor([0, 250, 1000, 1250]);
      stats
        ..hit()
        ..hit()
        ..reset()
        ..hit()
        ..hit();
      expect(stats.summary(), 'hits=2 gaps(ms) min=250 max=250 avg=250');
    });
  });
}
