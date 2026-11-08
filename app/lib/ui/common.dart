import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/interpreter.dart';
import '../core/models.dart';
import '../core/vault.dart';
import '../core/workflow_intel.dart';

const supportEmail = 'redreishilife+clinicbridge@gmail.com';
const brandNavy = Color(0xFF0B2545);
const brandTeal = Color(0xFF13838F);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: brandTeal, primary: brandNavy, secondary: brandTeal);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(backgroundColor: brandNavy, foregroundColor: Colors.white),
    cardTheme: const CardThemeData(margin: EdgeInsets.symmetric(horizontal: 12, vertical: 5)),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

/// Dependencies shared by every screen.
class Services extends InheritedWidget {
  const Services({
    super.key,
    required this.state,
    required this.vault,
    required this.pin,
    required this.translator,
    required this.biometric,
    required this.onLock,
    required super.child,
  });

  final AppState state;
  final Vault vault;
  final PinGuard pin;
  final TranslationService translator;
  final Future<bool> Function()? biometric;
  final VoidCallback onLock;

  static Services of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<Services>()!;

  @override
  bool updateShouldNotify(Services old) => false;
}

Color provenanceColor(Provenance p) => switch (p) {
      Provenance.patientReported => Colors.orange.shade700,
      Provenance.clinicianObserved => Colors.green.shade700,
      Provenance.imported => Colors.blueGrey,
      Provenance.aiGenerated => Colors.purple,
      Provenance.translated => Colors.indigo,
      Provenance.clinicianApproved => Colors.teal.shade700,
    };

IconData provenanceIcon(Provenance p) => switch (p) {
      Provenance.patientReported => Icons.record_voice_over,
      Provenance.clinicianObserved => Icons.visibility,
      Provenance.imported => Icons.download,
      Provenance.aiGenerated => Icons.auto_awesome,
      Provenance.translated => Icons.translate,
      Provenance.clinicianApproved => Icons.verified,
    };

Color severityColor(AlertSeverity s) => switch (s) {
      AlertSeverity.critical => Colors.red.shade700,
      AlertSeverity.warning => Colors.orange.shade800,
      AlertSeverity.info => Colors.blueGrey,
    };

IconData severityIcon(AlertSeverity s) => switch (s) {
      AlertSeverity.critical => Icons.error,
      AlertSeverity.warning => Icons.warning_amber,
      AlertSeverity.info => Icons.info_outline,
    };

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
        ]),
      );
}

class SyntheticBadge extends StatelessWidget {
  const SyntheticBadge({super.key});
  @override
  Widget build(BuildContext context) =>
      const Pill('SYNTHETIC DEMO', color: Colors.deepPurple, icon: Icons.science_outlined);
}

String fmtTime(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

String fmtDate(DateTime t) => fmtTime(t).substring(0, 10);

Future<void> guarded(BuildContext context, Future<void> Function() action, {String? success}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (success != null) messenger.showSnackBar(SnackBar(content: Text(success)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700));
  }
}

Future<String?> promptText(BuildContext context, String title, {String hint = '', String initial = '', int lines = 1}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, maxLines: lines, decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

String languageName(String code) => languageByCode(code).code == code ? languageByCode(code).name : code;

const clinicalDisclaimer =
    'ClinicBridge AI supports documentation, communication and handoff. It does not diagnose, prescribe, '
    'change doses, approve documentation or transfer responsibility on its own. The clinician remains '
    'responsible for every clinical decision. Machine translation and machine-drafted content can be wrong '
    'and stay labelled until a clinician reviews them. For consent, serious news and any doubt, use a '
    'qualified human interpreter. Demo builds contain synthetic data only — never enter real patient data '
    'in a demo or test build.';
