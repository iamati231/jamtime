import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import '../auth/auth_screen.dart';
import '../auth/spotify_auth_service.dart';
import '../auth/spotify_connection_monitor.dart';

/// Home'daki "Spotify" menusu: bilinen durum + bilincli eylemler
/// ("Baglantiyi kes", "Hesabi degistir"). Hicbiri Spotify'daki uygulama iznini
/// geri almaz; arayuz bunu IDDIA ETMEZ. Kayitli baglanti bilgisinin silindigi
/// DOGRULANMADIYSA da "silindi" denmez: Home'da kalinir ve hata gosterilir.
Future<void> showSpotifySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: JamTimeColors.background,
    showDragHandle: true,
    builder: (sheetContext) => _SpotifySheet(home: context),
  );
}

enum _Action { disconnect, switchAccount }

/// Onay penceresinin sonucu.
enum _Outcome { cancelled, done, notForgotten }

class _SpotifySheet extends StatelessWidget {
  const _SpotifySheet({required this.home});

  /// Home'un context'i: sheet kapandiktan sonra da yasar (dialog ve gezinme icin).
  final BuildContext home;

  Future<void> _start(BuildContext sheetContext, _Action action) async {
    final navigator = Navigator.of(home);
    final messenger = ScaffoldMessenger.of(home);
    Navigator.of(sheetContext).pop(); // sheet'i kapat
    final outcome = await showDialog<_Outcome>(
      context: home,
      barrierDismissible: false,
      builder: (_) => _ConfirmDialog(action: action),
    );
    if (outcome == _Outcome.done) {
      // Tum gezinme yigini gider: kayit silindi, Baglan ekrani yeni kok olur.
      navigator.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => AuthScreen(switchAccount: action == _Action.switchAccount),
        ),
        (route) => false,
      );
    } else if (outcome == _Outcome.notForgotten) {
      // Ucus/denemeler gecersiz kilindi ve SDK baglantisi kapatilmaya calisildi, ama kayitli
      // bilginin silindigi dogrulanamadi: "silindi" demeden Home'da kal, tekrar denenebilsin.
      // ("silinemedi" demek de fazla olurdu: sadece DOGRULANAMADI.)
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Bağlantı bilgisinin silindiği doğrulanamadı. Lütfen tekrar deneyin.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Spotify',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<SpotifyLink>(
              valueListenable: SpotifyConnectionMonitor.link,
              builder: (_, link, _) {
                final connected = link == SpotifyLink.connected;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? "Spotify'a bağlı" : "Spotify'a bağlı değil",
                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                    if (!connected)
                      const Text(
                        'QR kod tarandığında yeniden bağlanır.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            _SheetButton(
              label: 'Spotify bağlantısını kes',
              onPressed: () => _start(context, _Action.disconnect),
            ),
            const SizedBox(height: 8),
            _SheetButton(
              label: 'Spotify hesabını değiştir',
              onPressed: () => _start(context, _Action.switchAccount),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _SheetButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: JamTimeColors.cyan, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Text(
        label,
        style: const TextStyle(color: JamTimeColors.cyan, letterSpacing: 1),
      ),
    );
  }
}

/// Onay + calisma gostergesi: "Bağlantıyı kes" / "Devam" ucusu ve denemeleri gecersiz
/// kilar, kayitli baglanti bilgisini silmeyi dener (dogrular), SDK baglantisini kapatmayi
/// dener (sinirli sure); o sirada butonlar kapali.
class _ConfirmDialog extends StatefulWidget {
  final _Action action;

  const _ConfirmDialog({required this.action});

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    var forgotten = false;
    try {
      forgotten = await SpotifyAuthService.disconnectAndForget();
    } catch (e) {
      // Beklenmez (alt cagrilar hatalari kendisi yakalar); yine de pencere takili kalmasin.
      debugPrint('[Spotify] disconnect flow error: ${e.runtimeType}');
    }
    if (mounted) {
      Navigator.of(context).pop(forgotten ? _Outcome.done : _Outcome.notForgotten);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disconnect = widget.action == _Action.disconnect;
    // Calisirken (en fazla birkac saniye) ne geri tusu ne de baska bir sey pencereyi
    // kapatir: kayit silinirken Home'da yari yarim kalinmasin.
    return PopScope(
      canPop: !_busy,
      child: _dialog(disconnect),
    );
  }

  AlertDialog _dialog(bool disconnect) {
    return AlertDialog(
      backgroundColor: const Color.fromRGBO(18, 30, 66, 1),
      title: Text(
        disconnect
            ? 'Spotify bağlantısı kesilsin mi?'
            : 'Spotify hesabını değiştirmek istiyor musunuz?',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: Text(
        disconnect
            ? "JamTime'ın bu cihazda hatırladığı bağlantı bilgisi silinir ve Spotify "
                'bağlantısı kesilmeye çalışılır. '
                "Spotify'da JamTime'a verdiğiniz izin kaldırılmaz. "
                'Bu izni Spotify hesap ayarlarından kaldırabilirsiniz.'
            : 'JamTime, Spotify uygulamasında açık olan hesabı kullanır. '
                'Önce mevcut bağlantı bilgisi silinir. '
                "Ardından Spotify'da hesabınızı değiştirip JamTime'a dönerek yeniden "
                'bağlanın. '
                "Spotify'da JamTime'a verdiğiniz izin kaldırılmaz.",
        style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(_Outcome.cancelled),
          child: const Text('Vazgeç'),
        ),
        TextButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(disconnect ? 'Bağlantıyı kes' : 'Devam'),
        ),
      ],
    );
  }
}
