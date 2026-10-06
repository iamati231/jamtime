import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every platform-channel call of the services that an informational page must
/// NOT touch: the Spotify SDK (and its status streams), the camera, permissions and the
/// link launcher. Every channel answers `null`. Installed handlers are removed again at
/// the end of the test.
class ChannelGuard {
  ChannelGuard._();

  static const channels = <String>[
    'spotify_sdk',
    'connection_status_subscription',
    'player_state_subscription',
    'dev.steenbakker.mobile_scanner/scanner/method',
    'dev.steenbakker.mobile_scanner/scanner/event',
    'dev.steenbakker.mobile_scanner/scanner/deviceOrientation',
    'flutter.baseflow.com/permissions/methods',
    'plugins.flutter.io/url_launcher',
  ];

  /// "channel:method", in call order. Empty means: nothing was touched.
  final List<String> calls = <String>[];

  static ChannelGuard install() {
    final guard = ChannelGuard._();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        guard.calls.add('$name:${call.method}');
        return null;
      });
    }
    addTearDown(() {
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
    return guard;
  }
}
