import 'package:url_launcher/url_launcher.dart';

/// Spotify uygulamasini deeplink ile acar. Uygulama bulunamazsa/acilamazsa false.
/// (Song-Mode'daki "Spotify'a git" ile ayni mekanizma: spotify:// + externalApplication.)
Future<bool> openSpotifyApp() async {
  final uri = Uri.parse('spotify://');
  if (!await canLaunchUrl(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
