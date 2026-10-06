// JamTime oyun kurallari: TUM metin burada (yerel ve sabit; ag, link veya WebView yok).
// rules_screen.dart sadece bunu cizer; metin degisikligi icin ekrana dokunmak gerekmez.
//
// Metin, kullanici tarafindan saglanan ve onaylanan JamTime kural taslagidir. Baska
// kaynaklarin kural metnini yayinlama izni DOGRULANMADI. Onaylanan farklar:
//  - "Spotify ucretsiz surum / DJ" paragrafi YOK (JamTime'da boyle bir mod yok); yerine
//    Premium notu var (Spotify SDK: tek sarkiyi URI ile calmak Premium ister).
//  - Amac cumlesi "10 karttan" der ("10 yildan" degil).
// Baska kural EKLENMEZ.

/// Kalin bir giris ([lead], ornegin "Kart doğru yerdeyse:") ve devam metni ([body]).
/// Tek paragraf olarak cizilir; [text] orijinal metindir (iki nokta dahil).
class RulesItem {
  const RulesItem(this.body, {this.lead = ''});

  final String lead;
  final String body;

  String get text => lead.isEmpty ? body : '$lead $body';
}

/// "Üç basit adım" bolumunun bir adimi.
class RulesStep {
  const RulesStep({
    required this.title,
    required this.body,
    this.note,
    this.goal,
    this.outcomes = const <RulesItem>[],
  });

  final String title;
  final String body;

  /// Vurgulu not (varsa).
  final RulesItem? note;

  /// Oyunun amaci (varsa).
  final String? goal;

  /// Madde madde sonuclar (varsa).
  final List<RulesItem> outcomes;
}

class RulesContent {
  const RulesContent._();

  static const screenTitle = 'Oyun kuralları';
  static const heading = 'JamTime nasıl oynanır?';
  static const intro =
      'JamTime, herkesin kolayca öğrenebileceği üç basit adımda oynanır: QR kodu tara, '
      'kartı yerleştir ve kartı aç. JamTime jetonları ise oyunun gidişatını '
      'değiştirebilir. İşte bilmen gereken temel kurallar!';

  static const stepsTitle = 'Üç basit adım';
  static const steps = <RulesStep>[
    RulesStep(
      title: 'QR kodu tara',
      body: 'Kapalı desteden bir müzik kartı çek, ancak kartı henüz çevirme! '
          'Kartın arkasındaki QR kodu JamTime uygulamasıyla tara. '
          'Tarama tamamlandığında Spotify şarkıyı çalar. '
          'Şarkının bilgilerine gizlice bakmak yok!',
      note: RulesItem(
        "JamTime'da QR kodla seçilen şarkıları çalmak için Spotify Premium gerekir.",
      ),
    ),
    RulesStep(
      title: 'Kartı yerleştir',
      body: 'Şarkı çalmaya başladığında kartı çevirmeden, zaman çizelgende doğru '
          'olduğunu düşündüğün yere yerleştir. Yeni kartı, önceden yerleştirdiğin '
          'kartların arasına veya yanına koyabilirsin.',
      goal: 'Amaç, eskiden yeniye doğru sıralanmış 10 karttan oluşan bir müzik zaman '
          'çizelgesi oluşturmak.',
    ),
    RulesStep(
      title: 'Kartı aç',
      body: 'Kartını yerleştirdikten sonra çevir ve yılını kontrol et.',
      outcomes: <RulesItem>[
        RulesItem(
          'Tebrikler! Zaman çizelgen büyür ve kart sende kalır.',
          lead: 'Kart doğru yerdeyse:',
        ),
        RulesItem(
          'Kartı oyun dışına ayrılan kartların bulunduğu desteye koy. Başka bir oyuncu '
          'JamTime jetonunu doğru kullandıysa kartı o kazanır ve kendi zaman '
          'çizelgesine ekleyebilir.',
          lead: 'Kart yanlış yerdeyse:',
        ),
      ],
    ),
  ];

  static const tokensTitle = 'JamTime jetonları';
  static const tokensIntro =
      'Her oyuncu oyuna 2 JamTime jetonuyla başlar. Şarkının adını ve sanatçısını doğru '
      'tahmin ederek ek jeton kazanabilirsin. Aynı anda en fazla 5 jetonun olabilir.';
  static const tokensNote = RulesItem(
    'Yılı yanlış tahmin etsen bile şarkının adını ve sanatçısını doğru bilirsen bir '
    'jeton kazanırsın.',
    lead: 'Dikkat:',
  );
  static const tokenUsesIntro = 'Jetonlarını üç şekilde kullanabilirsin:';
  static const tokenUses = <RulesItem>[
    RulesItem(
      'Şarkıyı tanımıyor musun? Bir jeton ver, mevcut kartı oyun dışına ayır ve yeni '
      'bir kart çek.',
      lead: 'Kendi sıranda yeni kart çekmek:',
    ),
    RulesItem(
      'Diğer oyuncunun kartı yanlış yere koyduğunu mu düşünüyorsun? Kart açılmadan önce '
      '“JAMTIME!” diye seslen. Bir jetonunu, kartın doğru olduğunu düşündüğün yere koy. '
      'Tahminin doğruysa kartı sen kazanırsın.',
      lead: 'Başka bir oyuncunun kartını kazanmak:',
    ),
    RulesItem(
      'İstediğin zaman 3 jeton vererek bir müzik kartı satın alabilir ve yılını tahmin '
      'etmek zorunda kalmadan doğrudan zaman çizelgene yerleştirebilirsin.',
      lead: 'Kart satın almak:',
    ),
  ];
}
