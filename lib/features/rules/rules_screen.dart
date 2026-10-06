import 'package:flutter/material.dart';
import '../../config/jamtime_colors.dart';
import 'rules_content.dart';

const _cardColor = Color.fromRGBO(18, 30, 66, 1);
const _bodyStyle = TextStyle(color: Colors.white70, fontSize: 15, height: 1.45);
const _leadStyle = TextStyle(color: Colors.white, fontWeight: FontWeight.bold);

/// "Oyun kurallari": tamamen yerel, kaydirilabilir bilgi sayfasi. Hicbir servisi cagirmaz
/// (Spotify, kamera, izin, link, WebView yok): acmak ve kapatmak baska hicbir seyi
/// degistirmez. Metin rules_content.dart'tan gelir; bu dosya sadece cizer.
class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JamTimeColors.background,
      appBar: AppBar(
        backgroundColor: JamTimeColors.background,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white70,
        title: const Text(
          RulesContent.screenTitle,
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: const _RulesBody(),
            ),
          ),
        ),
      ),
    );
  }
}

class _RulesBody extends StatelessWidget {
  const _RulesBody();

  Color _accent(int index) =>
      JamTimeColors.borderColors[index % JamTimeColors.borderColors.length];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Heading(RulesContent.heading, size: 24),
        const SizedBox(height: 12),
        const Text(RulesContent.intro, style: _bodyStyle),
        const SizedBox(height: 28),
        const _Heading(RulesContent.stepsTitle, size: 20),
        const SizedBox(height: 12),
        for (var i = 0; i < RulesContent.steps.length; i++) ...[
          _StepCard(number: i + 1, accent: _accent(i), step: RulesContent.steps[i]),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 12),
        const _Heading(RulesContent.tokensTitle, size: 20),
        const SizedBox(height: 12),
        const Text(RulesContent.tokensIntro, style: _bodyStyle),
        const SizedBox(height: 12),
        const _NoteBox(RulesContent.tokensNote),
        const SizedBox(height: 16),
        const Text(RulesContent.tokenUsesIntro, style: _bodyStyle),
        const SizedBox(height: 12),
        for (var i = 0; i < RulesContent.tokenUses.length; i++) ...[
          _TokenUseCard(number: i + 1, accent: _accent(i), item: RulesContent.tokenUses[i]),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final double size;

  const _Heading(this.text, {required this.size});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: size,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Kenarlikli kart (Baglan ekranindaki rehber karti ile ayni dil).
class _Card extends StatelessWidget {
  final Color accent;
  final EdgeInsetsGeometry padding;
  final Widget child;

  const _Card({
    required this.accent,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: _cardColor,
        border: Border.all(color: accent.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

/// Numara rozeti: yazi buyudukce kendisi de buyur (sabit boyut yok, tasma olmaz).
class _Badge extends StatelessWidget {
  final int number;
  final Color color;

  const _Badge(this.number, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Text(
        '$number',
        style: const TextStyle(
          color: JamTimeColors.background,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Kalin giris + devam metni tek paragrafta; duz metin tam olarak [RulesItem.text].
class _RichLine extends StatelessWidget {
  final RulesItem item;

  const _RichLine(this.item);

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: _bodyStyle,
        children: [
          if (item.lead.isNotEmpty) TextSpan(text: item.lead, style: _leadStyle),
          TextSpan(text: item.lead.isEmpty ? item.body : ' ${item.body}'),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int number;
  final Color accent;
  final RulesStep step;

  const _StepCard({required this.number, required this.accent, required this.step});

  @override
  Widget build(BuildContext context) {
    return _Card(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Badge(number, accent),
              const SizedBox(width: 12),
              Expanded(child: _Heading(step.title, size: 18)),
            ],
          ),
          const SizedBox(height: 12),
          Text(step.body, style: _bodyStyle),
          if (step.note != null) ...[
            const SizedBox(height: 12),
            _NoteBox(step.note!),
          ],
          if (step.goal != null) ...[
            const SizedBox(height: 12),
            Text(step.goal!, style: _bodyStyle),
          ],
          for (final outcome in step.outcomes) ...[
            const SizedBox(height: 10),
            _Bullet(outcome, accent),
          ],
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final RulesItem item;
  final Color color;

  const _Bullet(this.item, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Text('•', style: _bodyStyle.copyWith(color: color)),
        ),
        const SizedBox(width: 10),
        Expanded(child: _RichLine(item)),
      ],
    );
  }
}

class _TokenUseCard extends StatelessWidget {
  final int number;
  final Color accent;
  final RulesItem item;

  const _TokenUseCard({required this.number, required this.accent, required this.item});

  @override
  Widget build(BuildContext context) {
    return _Card(
      accent: accent,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Badge(number, accent),
          const SizedBox(width: 12),
          Expanded(child: _RichLine(item)),
        ],
      ),
    );
  }
}

/// Vurgulu not kutusu (Premium notu, "Dikkat:" notu).
class _NoteBox extends StatelessWidget {
  final RulesItem item;

  const _NoteBox(this.item);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: JamTimeColors.cyan.withValues(alpha: 0.08),
        border: Border.all(color: JamTimeColors.cyan.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(
            child: Icon(Icons.info_outline, size: 20, color: JamTimeColors.cyan),
          ),
          const SizedBox(width: 10),
          Expanded(child: _RichLine(item)),
        ],
      ),
    );
  }
}
