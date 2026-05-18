import 'track_whitelist.dart';

class QrHandler {
  static bool isAllowed(String value) {
    return value.startsWith('https://open.spotify.com/') &&
        TrackWhitelist.isAllowed(value);
  }
}
