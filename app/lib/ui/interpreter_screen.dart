import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/interpreter.dart';
import '../core/models.dart';
import '../core/rbac.dart';
import 'common.dart';

class _Turn {
  _Turn(this.byPatient, this.result);
  final bool byPatient;
  final InterpretationResult result;
  String understanding = 'not checked';
  bool saved = false;
}

const quickPhrases = [
  'What is your full name and date of birth?',
  'Do you have any allergies to medicines? What happens when you take them?',
  'Which medicines do you take, and how much of each?',
  'Where is the pain? On a scale from 0 to 10, how bad is it?',
  'When did this start?',
  'Are you pregnant, or could you be pregnant?',
  'Please tell me in your own words what we just discussed.',
  'I am going to call a professional interpreter to make sure we understand each other.',
];

class InterpreterScreen extends StatefulWidget {
  const InterpreterScreen({super.key, required this.encounterId});
  final String encounterId;

  @override
  State<InterpreterScreen> createState() => _InterpreterScreenState();
}

class _InterpreterScreenState extends State<InterpreterScreen> {
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  final _input = TextEditingController();
  final _turns = <_Turn>[];
  late String _patientLang;
  late Dialect _patientDialect;
  Dialect _clinicianDialect = interpreterLanguages.first.dialects.first;
  bool _patientSpeaking = false;
  bool _listening = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final s = context.getInheritedWidgetOfExactType<Services>()!.state;
    final p = s.patient(s.encounter(widget.encounterId).patientId);
    _patientLang = p.preferredLanguage == 'en' ? 'es' : p.preferredLanguage;
    _patientDialect = languageByCode(_patientLang).dialects.first;
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  String get _from => _patientSpeaking ? _patientLang : 'en';
  String get _to => _patientSpeaking ? 'en' : _patientLang;

  Future<void> _listen() async {
    if (_listening) {
      await _speech.stop();
      return setState(() => _listening = false);
    }
    final ok = await _speech.initialize(onStatus: (st) {
      if (st == 'done' || st == 'notListening') setState(() => _listening = false);
    });
    if (!ok) return setState(() => _status = 'Speech recognition unavailable — type instead.');
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) => setState(() => _input.text = r.recognizedWords),
      listenOptions: SpeechListenOptions(
        localeId: (_patientSpeaking ? _patientDialect : _clinicianDialect).locale.replaceAll('-', '_'),
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  Future<void> _translate() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Translating on device (first use downloads the language model)…';
    });
    final svc = Services.of(context);
    try {
      final r = await InterpreterEngine(svc.translator).interpret(text, from: _from, to: _to);
      setState(() {
        _turns.insert(0, _Turn(_patientSpeaking, r));
        _input.clear();
        _status = null;
      });
      svc.state.log('interpretation', widget.encounterId,
          '$_from→$_to risk:${r.risk.name} agreement:${(r.confidence * 100).round()}% issues:${r.issues.length}');
    } catch (e) {
      setState(() => _status = 'Translation failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _speak(_Turn t) async {
    final d = t.byPatient ? _clinicianDialect : _patientDialect;
    await _tts.setLanguage(d.locale);
    await _tts.speak(t.result.translation);
  }

  Future<void> _callInterpreter() async {
    final s = Services.of(context).state;
    s.log('human-interpreter-escalation', widget.encounterId, _patientLang);
    await s.commit();
    final phone = s.settings.interpreterServicePhone;
    if (phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Escalation logged. Set your site\'s interpreter line in Settings to call it from here.')));
      }
      return;
    }
    await launchUrl(Uri(scheme: 'tel', path: phone));
  }

  Future<void> _save(_Turn t) async {
    final s = Services.of(context).state;
    final cat = await showDialog<ItemCategory>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Save to record as…'),
        children: [
          for (final c in [ItemCategory.complaint, ItemCategory.history, ItemCategory.allergy, ItemCategory.medication, ItemCategory.note])
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c), child: Text(c.label)),
        ],
      ),
    );
    if (cat == null || !mounted) return;
    await guarded(context, () async {
      final englishText = t.byPatient ? t.result.translation : t.result.original;
      final original = t.byPatient ? t.result.original : t.result.translation;
      await s.record(
        encounterId: widget.encounterId,
        category: cat,
        label: cat.label,
        value: englishText,
        provenance: Provenance.translated,
        source: 'Interpreter session (${t.result.from.toUpperCase()}→${t.result.to.toUpperCase()}), teach-back: ${t.understanding}',
        language: t.byPatient ? t.result.from : t.result.to,
        originalText: original,
        confidence: t.result.confidence,
      );
      setState(() => t.saved = true);
    }, success: 'Saved as translated — awaits clinician approval.');
  }

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final lang = languageByCode(_patientLang);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Medical interpreter'),
        actions: [
          IconButton(tooltip: 'Call qualified interpreter', icon: const Icon(Icons.support_agent), onPressed: _callInterpreter),
        ],
      ),
      body: Column(children: [
        Container(
          color: brandNavy.withValues(alpha: 0.06),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _patientLang,
                  decoration: const InputDecoration(labelText: 'Patient language', isDense: true),
                  items: [for (final l in interpreterLanguages.where((l) => l.code != 'en')) DropdownMenuItem(value: l.code, child: Text(l.name))],
                  onChanged: (v) => setState(() {
                    _patientLang = v ?? _patientLang;
                    _patientDialect = languageByCode(_patientLang).dialects.first;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _patientDialect.locale,
                  decoration: const InputDecoration(labelText: 'Dialect / region', isDense: true),
                  items: [for (final d in lang.dialects) DropdownMenuItem(value: d.locale, child: Text('${d.name} (${d.locale})'))],
                  onChanged: (v) => setState(() => _patientDialect = lang.dialects.firstWhere((d) => d.locale == v)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _clinicianDialect.locale,
                  decoration: const InputDecoration(labelText: 'Clinician English', isDense: true),
                  items: [for (final d in interpreterLanguages.first.dialects) DropdownMenuItem(value: d.locale, child: Text(d.name))],
                  onChanged: (v) => setState(() => _clinicianDialect = interpreterLanguages.first.dialects.firstWhere((d) => d.locale == v)),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Clinician'), icon: Icon(Icons.medical_services_outlined)),
                  ButtonSegment(value: true, label: Text('Patient'), icon: Icon(Icons.person_outline)),
                ],
                selected: {_patientSpeaking},
                onSelectionChanged: (v) => setState(() => _patientSpeaking = v.first),
              ),
            ]),
          ]),
        ),
        if (!_patientSpeaking)
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), children: [
              for (final q in quickPhrases)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(label: Text(q, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => _input.text = q)),
                ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(children: [
            IconButton.filled(
              tooltip: 'Speak',
              onPressed: _listen,
              style: IconButton.styleFrom(backgroundColor: _listening ? Colors.red : brandTeal),
              icon: Icon(_listening ? Icons.stop : Icons.mic),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: _patientSpeaking ? 'Patient speaks ${languageName(_patientLang)}…' : 'Clinician speaks English…',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(tooltip: 'Translate', onPressed: _busy ? null : _translate, icon: const Icon(Icons.translate)),
          ]),
        ),
        if (_status != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(_status!, style: const TextStyle(color: Colors.black54))),
        Expanded(
          child: _turns.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Speech and translation run on the device. Each translation is back-translated and checked for '
                      'numbers, medicine names, units and negation. Use a qualified interpreter for consent, serious news or any doubt.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54)),
                ))
              : ListView(children: [for (final t in _turns) _turnCard(t, s.can(Permission.addEntry))]),
        ),
      ]),
    );
  }

  Widget _turnCard(_Turn t, bool canSave) {
    final r = t.result;
    final pct = (r.confidence * 100).round();
    return Card(
      color: t.byPatient ? Colors.indigo.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(t.byPatient ? 'PATIENT' : 'CLINICIAN', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(width: 8),
            Pill(r.risk.label, color: r.risk.level >= 3 ? Colors.red.shade700 : (r.risk.level == 2 ? Colors.orange.shade800 : Colors.blueGrey)),
            const Spacer(),
            Pill('Agreement $pct%', color: pct >= 75 ? Colors.green.shade700 : (pct >= 50 ? Colors.orange.shade800 : Colors.red.shade700)),
          ]),
          const SizedBox(height: 8),
          Text('Original (${r.from}): ${r.original}', style: const TextStyle(color: Colors.black87)),
          const SizedBox(height: 4),
          Text('Translation (${r.to}): ${r.translation}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Back-translation: ${r.backTranslation}', style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.black54)),
          for (final i in r.issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(i.severity == IssueSeverity.critical ? Icons.error : Icons.warning_amber,
                    size: 16, color: i.severity == IssueSeverity.critical ? Colors.red : Colors.orange),
                const SizedBox(width: 4),
                Expanded(child: Text(i.message, style: const TextStyle(fontSize: 13))),
              ]),
            ),
          if (r.requiresHumanInterpreter)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.support_agent, color: Colors.red),
                const SizedBox(width: 8),
                const Expanded(child: Text('Qualified human interpreter recommended for this message.')),
                TextButton(onPressed: _callInterpreter, child: const Text('Call')),
              ]),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(onPressed: () => _speak(t), icon: const Icon(Icons.volume_up, size: 18), label: const Text('Speak')),
            if (!t.byPatient) ...[
              const Text('Teach-back:'),
              ChoiceChip(
                label: const Text('Understood'),
                selected: t.understanding == 'confirmed',
                onSelected: (_) => setState(() => t.understanding = 'confirmed'),
              ),
              ChoiceChip(
                label: const Text('Not understood'),
                selected: t.understanding == 'not understood',
                onSelected: (_) => setState(() => t.understanding = 'not understood'),
              ),
            ],
            if (canSave)
              TextButton.icon(
                onPressed: t.saved ? null : () => _save(t),
                icon: Icon(t.saved ? Icons.check : Icons.save_alt, size: 18),
                label: Text(t.saved ? 'Saved' : 'Save to record'),
              ),
          ]),
        ]),
      ),
    );
  }
}
