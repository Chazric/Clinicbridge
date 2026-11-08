import 'drug_knowledge.dart';

class Dialect {
  const Dialect(this.locale, this.name);

  /// BCP-47 locale used for speech recognition and text-to-speech.
  final String locale;
  final String name;
}

class InterpreterLanguage {
  const InterpreterLanguage(this.code, this.name, this.dialects);

  /// ISO 639-1 code used by the on-device translation model.
  final String code;
  final String name;
  final List<Dialect> dialects;
}

const interpreterLanguages = <InterpreterLanguage>[
  InterpreterLanguage('en', 'English', [Dialect('en-US', 'US'), Dialect('en-GB', 'UK'), Dialect('en-AU', 'Australia'), Dialect('en-IN', 'India')]),
  InterpreterLanguage('es', 'Spanish', [Dialect('es-MX', 'Mexico'), Dialect('es-US', 'US'), Dialect('es-ES', 'Spain'), Dialect('es-CO', 'Colombia'), Dialect('es-AR', 'Argentina')]),
  InterpreterLanguage('fr', 'French', [Dialect('fr-FR', 'France'), Dialect('fr-CA', 'Canada'), Dialect('fr-BE', 'Belgium')]),
  InterpreterLanguage('pt', 'Portuguese', [Dialect('pt-BR', 'Brazil'), Dialect('pt-PT', 'Portugal')]),
  InterpreterLanguage('ar', 'Arabic', [Dialect('ar-SA', 'Saudi Arabia'), Dialect('ar-EG', 'Egypt'), Dialect('ar-AE', 'UAE')]),
  InterpreterLanguage('zh', 'Chinese (Mandarin)', [Dialect('zh-CN', 'Mainland'), Dialect('zh-TW', 'Taiwan')]),
  InterpreterLanguage('hi', 'Hindi', [Dialect('hi-IN', 'India')]),
  InterpreterLanguage('ru', 'Russian', [Dialect('ru-RU', 'Russia')]),
  InterpreterLanguage('uk', 'Ukrainian', [Dialect('uk-UA', 'Ukraine')]),
  InterpreterLanguage('vi', 'Vietnamese', [Dialect('vi-VN', 'Vietnam')]),
  InterpreterLanguage('ko', 'Korean', [Dialect('ko-KR', 'Korea')]),
  InterpreterLanguage('tl', 'Tagalog', [Dialect('fil-PH', 'Philippines')]),
  InterpreterLanguage('ht', 'Haitian Creole', [Dialect('ht-HT', 'Haiti')]),
  InterpreterLanguage('de', 'German', [Dialect('de-DE', 'Germany'), Dialect('de-AT', 'Austria'), Dialect('de-CH', 'Switzerland')]),
  InterpreterLanguage('it', 'Italian', [Dialect('it-IT', 'Italy')]),
  InterpreterLanguage('pl', 'Polish', [Dialect('pl-PL', 'Poland')]),
  InterpreterLanguage('tr', 'Turkish', [Dialect('tr-TR', 'Turkey')]),
  InterpreterLanguage('fa', 'Persian (Farsi)', [Dialect('fa-IR', 'Iran')]),
  InterpreterLanguage('bn', 'Bengali', [Dialect('bn-BD', 'Bangladesh'), Dialect('bn-IN', 'India')]),
  InterpreterLanguage('ur', 'Urdu', [Dialect('ur-PK', 'Pakistan')]),
  InterpreterLanguage('sw', 'Swahili', [Dialect('sw-KE', 'Kenya'), Dialect('sw-TZ', 'Tanzania')]),
  InterpreterLanguage('ja', 'Japanese', [Dialect('ja-JP', 'Japan')]),
];

InterpreterLanguage languageByCode(String code) =>
    interpreterLanguages.firstWhere((l) => l.code == code, orElse: () => interpreterLanguages.first);

abstract class TranslationService {
  Future<String> translate(String text, {required String from, required String to});
}

enum ClinicalRisk {
  consent('Consent / procedure', 3),
  medication('Medication / dosing', 3),
  allergy('Allergy', 3),
  badNews('Diagnosis / serious news', 3),
  discharge('Discharge instructions', 2),
  symptom('Symptoms / history', 1),
  general('General', 0);

  const ClinicalRisk(this.label, this.level);
  final String label;
  final int level;
}

enum IssueSeverity { critical, warning }

class TranslationIssue {
  TranslationIssue(this.severity, this.message);
  final IssueSeverity severity;
  final String message;
}

class InterpretationResult {
  InterpretationResult({
    required this.original,
    required this.translation,
    required this.backTranslation,
    required this.from,
    required this.to,
    required this.confidence,
    required this.risk,
    required this.issues,
  });

  final String original;
  final String translation;
  final String backTranslation;
  final String from;
  final String to;

  /// 0–1 agreement between the original and its back-translation. A heuristic,
  /// not a validated accuracy score.
  final double confidence;
  final ClinicalRisk risk;
  final List<TranslationIssue> issues;

  bool get hasCritical => issues.any((i) => i.severity == IssueSeverity.critical);

  /// Escalate to a qualified human interpreter.
  bool get requiresHumanInterpreter =>
      risk == ClinicalRisk.consent ||
      risk == ClinicalRisk.badNews ||
      hasCritical ||
      (risk.level >= 2 && confidence < 0.6) ||
      confidence < 0.4;
}

class InterpreterEngine {
  InterpreterEngine(this.translator);
  final TranslationService translator;

  Future<InterpretationResult> interpret(String text, {required String from, required String to}) async {
    final translation = await translator.translate(text, from: from, to: to);
    final back = await translator.translate(translation, from: to, to: from);
    return TranslationSafety.assess(
        original: text, translation: translation, backTranslation: back, from: from, to: to);
  }
}

class TranslationSafety {
  static const _units = ['mg', 'mcg', 'g', 'kg', 'ml', 'l', 'units', 'mmol', 'meq', '%'];

  static const _negations = {
    'en': ['no', 'not', 'never', 'none', 'without', "don't", "doesn't", "didn't", "can't", 'cannot', 'deny', 'denies', 'nothing', 'nor', "isn't", "aren't", "won't"],
    'es': ['no', 'nunca', 'sin', 'ningún', 'ninguna', 'nada', 'jamás', 'tampoco'],
    'fr': ['ne', 'pas', 'jamais', 'sans', 'aucun', 'aucune', 'rien', 'non', "n'"],
    'pt': ['não', 'nunca', 'sem', 'nenhum', 'nenhuma', 'nada'],
    'de': ['nicht', 'kein', 'keine', 'nie', 'niemals', 'ohne', 'nein'],
    'it': ['non', 'mai', 'senza', 'nessun', 'nessuna', 'niente'],
  };

  static const _numberWords = {
    'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7,
    'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13,
    'fourteen': 14, 'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
    'nineteen': 19, 'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50, 'sixty': 60,
    'seventy': 70, 'eighty': 80, 'ninety': 90, 'hundred': 100, 'half': -1,
  };

  static const _teenTy = {
    'thirteen': 'thirty', 'fourteen': 'forty', 'fifteen': 'fifty', 'sixteen': 'sixty',
    'seventeen': 'seventy', 'eighteen': 'eighty', 'nineteen': 'ninety',
  };

  static List<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^\p{L}\p{N}'%]+", unicode: true), ' ')
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList();

  /// Digits, plus English number words when the text is English.
  static List<num> numbers(String s, {String lang = 'en'}) {
    final out = <num>[
      for (final m in RegExp(r'\d+(?:[.,]\d+)?').allMatches(s)) num.parse(m.group(0)!.replaceAll(',', '.')),
    ];
    if (lang == 'en') {
      final toks = _tokens(s);
      for (var i = 0; i < toks.length; i++) {
        final v = _numberWords[toks[i]];
        if (v == null || v < 0) continue;
        if (v >= 20 && v % 10 == 0 && v < 100 && i + 1 < toks.length) {
          final next = _numberWords[toks[i + 1]];
          if (next != null && next > 0 && next < 10) {
            out.add(v + next);
            i++;
            continue;
          }
        }
        out.add(v);
      }
    }
    return out;
  }

  static bool hasNegation(String s, String lang) {
    final words = _negations[lang];
    if (words == null) return false;
    final lower = s.toLowerCase();
    final toks = _tokens(s).toSet();
    return words.any((w) => w.endsWith("'") ? lower.contains(w) : toks.contains(w));
  }

  static double similarity(String a, String b) {
    final ta = _tokens(a).toSet(), tb = _tokens(b).toSet();
    if (ta.isEmpty && tb.isEmpty) return 1;
    final inter = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    return union == 0 ? 0 : inter / union;
  }

  static List<String> drugMentions(String s) {
    final lower = s.toLowerCase();
    final all = <String>{
      for (final l in DrugKnowledge.therapeuticClasses.values) ...l,
      for (final l in DrugKnowledge.highAlert.values) ...l,
      for (final l in DrugKnowledge.allergyClasses.values) ...l,
    };
    return all.where((d) => RegExp('\\b${RegExp.escape(d)}\\b').hasMatch(lower)).toList();
  }

  static ClinicalRisk classify(String s) {
    final t = s.toLowerCase();
    bool any(List<String> w) => w.any((x) => RegExp('\\b$x').hasMatch(t));
    if (any(['consent', 'sign', 'surgery', 'procedure', 'operation', 'anesthe', 'anaesthe', 'risks', 'blood transfusion'])) {
      return ClinicalRisk.consent;
    }
    if (any(['cancer', 'tumou?r', 'malignan', 'terminal', 'died', 'passed away', 'resuscitat', 'palliative', 'hospice', 'miscarriage'])) {
      return ClinicalRisk.badNews;
    }
    if (any(['allerg', 'reaction', 'rash', 'anaphyla', 'swelling', 'hives'])) return ClinicalRisk.allergy;
    if (drugMentions(t).isNotEmpty ||
        RegExp(r'\d+\s*(mg|mcg|ml|units?|tablets?|pills?|puffs?|drops?)\b').hasMatch(t) ||
        any(['dose', 'medication', 'medicine', 'tablet', 'pill', 'injection', 'insulin', 'take ', 'times a day', 'every \\d'])) {
      return ClinicalRisk.medication;
    }
    if (any(['discharge', 'go home', 'come back', 'return if', 'follow.up', 'appointment', 'call 911', 'emergency'])) {
      return ClinicalRisk.discharge;
    }
    if (any(['pain', 'fever', 'breath', 'cough', 'vomit', 'bleed', 'dizz', 'hurt', 'since', 'days?', 'weeks?'])) {
      return ClinicalRisk.symptom;
    }
    return ClinicalRisk.general;
  }

  static InterpretationResult assess({
    required String original,
    required String translation,
    required String backTranslation,
    required String from,
    required String to,
  }) {
    final issues = <TranslationIssue>[];

    // Numbers (doses, times, durations) must survive the round trip.
    final srcNums = numbers(original, lang: from);
    final outNums = {...numbers(translation, lang: to), ...numbers(backTranslation, lang: from)};
    final lost = srcNums.where((n) => !outNums.contains(n)).toSet();
    if (lost.isNotEmpty) {
      issues.add(TranslationIssue(IssueSeverity.critical,
          'Number(s) ${lost.join(', ')} not found in the translation. Confirm by read-back.'));
    }
    final extra = numbers(translation, lang: to).where((n) => !srcNums.contains(n)).toSet();
    if (extra.isNotEmpty && srcNums.isNotEmpty) {
      issues.add(TranslationIssue(IssueSeverity.critical,
          'Translation contains number(s) ${extra.join(', ')} that were not in the original.'));
    }
    if (from == 'en') {
      final toks = _tokens(original);
      for (final w in toks) {
        if (_teenTy.containsKey(w) || _teenTy.containsValue(w)) {
          issues.add(TranslationIssue(IssueSeverity.warning,
              '"$w" is easily misheard (e.g. fifteen/fifty). Say the digits ("one-five") and confirm.'));
          break;
        }
      }
    }

    // Negation flips are among the most dangerous errors ("no allergy" → "allergy").
    final srcNeg = hasNegation(original, from);
    if (_negations.containsKey(from) && srcNeg != hasNegation(backTranslation, from)) {
      issues.add(TranslationIssue(IssueSeverity.critical,
          srcNeg ? 'Negation may have been lost ("not"/"no").' : 'A negation appeared that was not in the original.'));
    }

    // Drug names and units should be preserved.
    for (final d in drugMentions(original)) {
      final stem = d.length > 5 ? d.substring(0, 5) : d;
      if (!translation.toLowerCase().contains(stem) && !backTranslation.toLowerCase().contains(stem)) {
        issues.add(TranslationIssue(IssueSeverity.critical, 'Medication name "$d" was not preserved.'));
      }
    }
    final lowerOrig = original.toLowerCase();
    for (final u in _units) {
      if (RegExp('\\d\\s*${RegExp.escape(u)}\\b').hasMatch(lowerOrig) &&
          !RegExp('\\b${RegExp.escape(u)}\\b|${RegExp.escape(u)}').hasMatch(translation.toLowerCase())) {
        issues.add(TranslationIssue(IssueSeverity.warning, 'Unit "$u" may have been changed — confirm.'));
      }
    }

    final confidence = similarity(original, backTranslation);
    if (confidence < 0.5) {
      issues.add(TranslationIssue(IssueSeverity.warning,
          'Back-translation differs substantially from the original (agreement ${(confidence * 100).round()}%).'));
    }

    return InterpretationResult(
      original: original,
      translation: translation,
      backTranslation: backTranslation,
      from: from,
      to: to,
      confidence: confidence,
      risk: classify(from == 'en' ? original : '$original $backTranslation'),
      issues: issues,
    );
  }
}
