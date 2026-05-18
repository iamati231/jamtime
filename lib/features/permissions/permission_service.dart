import 'package:permission_handler/permission_handler.dart';

enum CameraPermissionResult {
  /// Izin verildi, kamerayi acabiliriz.
  granted,

  /// Kullanici reddetti ama tekrar istenebilir (ilk red).
  denied,

  /// Kullanici "Don't ask again" / iOS kalici red.
  /// Bu durumda sistem dialog'u bir daha gozukmez,
  /// kullaniciyi Settings'e yonlendirmek gerek.
  permanentlyDenied,

  /// iOS Restricted (Screen Time vb) — sistemden disabled.
  restricted,
}

class PermissionService {
  /// Kamera iznini ister. Detayli sonuc doner ki UI ne yapacagina karar versin.
  static Future<CameraPermissionResult> requestCamera() async {
    final status = await Permission.camera.request();

    if (status.isGranted) return CameraPermissionResult.granted;
    if (status.isPermanentlyDenied) return CameraPermissionResult.permanentlyDenied;
    if (status.isRestricted) return CameraPermissionResult.restricted;
    return CameraPermissionResult.denied;
  }

  /// Mevcut izin durumunu kontrol et (istemeden).
  static Future<CameraPermissionResult> checkCamera() async {
    final status = await Permission.camera.status;

    if (status.isGranted) return CameraPermissionResult.granted;
    if (status.isPermanentlyDenied) return CameraPermissionResult.permanentlyDenied;
    if (status.isRestricted) return CameraPermissionResult.restricted;
    return CameraPermissionResult.denied;
  }

  /// iOS/Android sistem ayarlarini ac (kalici red durumunda).
  static Future<bool> openSettings() async {
    return await openAppSettings();
  }
}
