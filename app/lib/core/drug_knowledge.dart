/// Small, curated reference used for safety prompts only. It is NOT a complete
/// drug database; production use requires a licensed, maintained source
/// (e.g. RxNorm/SNOMED CT/national formulary) and pharmacist governance.
class DrugKnowledge {
  static const Map<String, List<String>> allergyClasses = {
    'penicillin': [
      'penicillin', 'amoxicillin', 'ampicillin', 'piperacillin', 'flucloxacillin',
      'dicloxacillin', 'oxacillin', 'nafcillin', 'co-amoxiclav', 'augmentin', 'tazocin',
    ],
    'cephalosporin': ['cefalexin', 'cephalexin', 'cefazolin', 'ceftriaxone', 'cefuroxime', 'cefepime', 'cefotaxime'],
    'sulfonamide antibiotic': ['sulfamethoxazole', 'co-trimoxazole', 'bactrim', 'septra', 'sulfadiazine'],
    'nsaid': ['ibuprofen', 'naproxen', 'diclofenac', 'ketorolac', 'aspirin', 'indomethacin', 'celecoxib', 'meloxicam'],
    'opioid': ['morphine', 'codeine', 'oxycodone', 'hydromorphone', 'fentanyl', 'tramadol', 'hydrocodone'],
    'macrolide': ['erythromycin', 'azithromycin', 'clarithromycin'],
    'fluoroquinolone': ['ciprofloxacin', 'levofloxacin', 'moxifloxacin'],
    'iodinated contrast': ['iohexol', 'iopamidol', 'contrast'],
  };

  /// Partial cross-reactivity worth flagging for clinician review.
  static const Map<String, String> crossReactive = {
    'penicillin': 'cephalosporin',
  };

  static const Map<String, List<String>> therapeuticClasses = {
    'anticoagulant': ['warfarin', 'apixaban', 'rivaroxaban', 'dabigatran', 'edoxaban', 'heparin', 'enoxaparin', 'dalteparin'],
    'nsaid': ['ibuprofen', 'naproxen', 'diclofenac', 'ketorolac', 'indomethacin', 'celecoxib', 'meloxicam'],
    'opioid': ['morphine', 'codeine', 'oxycodone', 'hydromorphone', 'fentanyl', 'tramadol', 'hydrocodone'],
    'acetaminophen/paracetamol': ['acetaminophen', 'paracetamol', 'tylenol', 'panadol', 'doliprane'],
    'ssri': ['sertraline', 'fluoxetine', 'citalopram', 'escitalopram', 'paroxetine'],
    'ace inhibitor / arb': ['lisinopril', 'enalapril', 'ramipril', 'losartan', 'valsartan', 'candesartan'],
    'benzodiazepine': ['lorazepam', 'diazepam', 'midazolam', 'alprazolam', 'clonazepam'],
  };

  /// Based on widely used high-alert medication categories (e.g. ISMP lists).
  static const Map<String, List<String>> highAlert = {
    'insulin': ['insulin', 'glargine', 'lispro', 'aspart', 'detemir', 'degludec'],
    'anticoagulant': ['warfarin', 'heparin', 'enoxaparin', 'apixaban', 'rivaroxaban', 'dabigatran'],
    'opioid': ['morphine', 'hydromorphone', 'fentanyl', 'oxycodone', 'methadone'],
    'concentrated electrolyte': ['potassium chloride', 'kcl', 'hypertonic saline', 'magnesium sulfate'],
    'oral methotrexate (weekly dosing)': ['methotrexate'],
    'sedative': ['midazolam', 'propofol', 'dexmedetomidine'],
    'antidiabetic (sulfonylurea)': ['glipizide', 'glyburide', 'glibenclamide', 'gliclazide'],
    'antiarrhythmic': ['amiodarone', 'digoxin'],
  };

  static String _n(String s) => s.toLowerCase();

  static bool _mentions(String text, String term) =>
      RegExp('\\b${RegExp.escape(term)}', caseSensitive: false).hasMatch(text);

  static bool isNoKnownAllergy(String v) =>
      RegExp(r'\b(nkda|nka|no known (drug )?allerg)', caseSensitive: false).hasMatch(v);

  static bool isNone(String v) => RegExp(r'^\s*(none|nil|no medications?)\s*$', caseSensitive: false).hasMatch(v);

  static String? _classOf(String text, Map<String, List<String>> classes) {
    for (final entry in classes.entries) {
      if (_mentions(text, entry.key) || entry.value.any((d) => _mentions(text, d))) return entry.key;
    }
    return null;
  }

  static String? allergyConflict(String allergy, String medication) {
    final a = _n(allergy), m = _n(medication);
    for (final entry in allergyClasses.entries) {
      final allergyHit = _mentions(a, entry.key) || entry.value.any((d) => _mentions(a, d));
      if (!allergyHit) continue;
      final drug = entry.value.firstWhere((d) => _mentions(m, d), orElse: () => '');
      if (drug.isNotEmpty) return '${entry.key} class';
      final cross = crossReactive[entry.key];
      if (cross != null && allergyClasses[cross]!.any((d) => _mentions(m, d))) {
        return 'possible ${entry.key}–$cross cross-reactivity';
      }
    }
    // Same-drug match for anything outside the curated classes.
    final first = RegExp(r'[a-z]{4,}').stringMatch(a);
    if (first != null && !isNoKnownAllergy(a) && _mentions(m, first)) return 'same agent';
    return null;
  }

  static String? duplicateTherapy(String a, String b) {
    final ca = _classOf(a, therapeuticClasses);
    if (ca == null) return null;
    final cb = _classOf(b, therapeuticClasses);
    return ca == cb ? ca : null;
  }

  static String? highAlertClass(String medication) => _classOf(medication, highAlert);
}

/// Text checks against error-prone dose expressions (ISMP-style).
class DoseTextChecks {
  static List<String> issues(String text) {
    final out = <String>[];
    if (RegExp(r'\d+\.0\b').hasMatch(text)) {
      out.add('trailing zero (e.g. "5.0 mg") can be misread as 10× dose — write "5 mg".');
    }
    if (RegExp(r'(^|[^\d])\.\d').hasMatch(text)) {
      out.add('missing leading zero (".5 mg") — write "0.5 mg".');
    }
    if (RegExp(r'\b\d+\s*(u|iu)\b', caseSensitive: false).hasMatch(text)) {
      out.add('"U"/"IU" abbreviation — write "units".');
    }
    if (RegExp(r'\b(qd|qod)\b', caseSensitive: false).hasMatch(text)) {
      out.add('"QD/QOD" abbreviation — write "daily" / "every other day".');
    }
    if (RegExp(r'\b(ug|µg|μg)\b', caseSensitive: false).hasMatch(text)) {
      out.add('"µg" can be misread as "mg" — write "mcg".');
    }
    return out;
  }
}
