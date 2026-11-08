import 'models.dart';
import 'drug_knowledge.dart';

enum AlertSeverity { critical, warning, info }

class WorkflowAlert {
  WorkflowAlert(this.severity, this.code, this.message, {this.itemIds = const []});
  final AlertSeverity severity;
  final String code;
  final String message;
  final List<String> itemIds;
}

/// Deterministic, explainable checks. These are prompts for the clinician,
/// not diagnoses or orders.
class WorkflowIntelligence {
  static List<WorkflowAlert> analyze({
    required Patient patient,
    required Encounter encounter,
    required List<LedgerEntry> items,
    required List<ClinicalTask> tasks,
    required List<Patient> allPatients,
    DateTime? now,
  }) {
    final alerts = <WorkflowAlert>[];
    final when = now ?? DateTime.now();
    List<LedgerEntry> of(ItemCategory c) => items.where((e) => e.category == c).toList();

    // Identity: two identifiers (name + DOB) confirmed against the patient.
    if (!patient.identityVerified) {
      alerts.add(WorkflowAlert(AlertSeverity.critical, 'identity.unverified',
          'Patient identity not verified with two identifiers (full name + date of birth).'));
    }

    // Communication.
    if (patient.preferredLanguage != 'en' && !patient.interpreterNeeded) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'language.interpreter',
          'Preferred language is not English but "interpreter needed" is not set.'));
    }

    // Missing core documentation.
    final allergies = of(ItemCategory.allergy);
    if (allergies.isEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.critical, 'missing.allergy',
          'Allergy status not documented. Record allergies or "No known drug allergies".'));
    }
    if (of(ItemCategory.medication).isEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'missing.medication',
          'Medication list not documented (record "None" if none).'));
    }
    if (of(ItemCategory.weight).isEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'missing.weight',
          'No weight recorded — required for weight-based dosing.'));
    }
    if (of(ItemCategory.complaint).isEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.info, 'missing.complaint', 'No presenting complaint recorded.'));
    }
    if (of(ItemCategory.codeStatus).isEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'missing.codeStatus',
          'Code status / goals of care not documented.'));
    }
    final age = patient.ageOn(when);
    if (patient.sex == 'female' && age >= 12 && age <= 55 && of(ItemCategory.pregnancy).isEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'missing.pregnancy',
          'Pregnancy status not documented for a patient of reproductive age.'));
    }
    if (encounter.consentRef == null) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'missing.consent',
          'No consent / authorization reference recorded for this encounter.'));
    }

    // Unreviewed machine content and unverified critical items.
    for (final e in items.where((e) => e.pendingReview)) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'review.machine',
          '${e.provenance.label} "${e.label}" awaits clinician review.',
          itemIds: [e.itemId]));
    }
    for (final e in [...allergies, ...of(ItemCategory.medication)]
        .where((e) => e.verification == Verification.unverified && !e.pendingReview)) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'verify.critical',
          '${e.category.label} "${e.value}" is ${e.provenance.label.toLowerCase()} and not yet verified.',
          itemIds: [e.itemId]));
    }
    for (final e in items.where((e) => e.verification == Verification.disputed)) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'disputed',
          '"${e.label}" is disputed: ${e.changeReason ?? ''}', itemIds: [e.itemId]));
    }

    // Conflicts: NKDA alongside documented allergies.
    final nkda = allergies.where((a) => DrugKnowledge.isNoKnownAllergy(a.value)).toList();
    final realAllergies = allergies.where((a) => !DrugKnowledge.isNoKnownAllergy(a.value)).toList();
    if (nkda.isNotEmpty && realAllergies.isNotEmpty) {
      alerts.add(WorkflowAlert(AlertSeverity.critical, 'conflict.nkda',
          'Conflicting allergy information: "No known allergies" recorded together with specific allergies.',
          itemIds: [...nkda, ...realAllergies].map((e) => e.itemId).toList()));
    }

    // Conflicts: medication vs documented allergy (class-level cross-sensitivity).
    final meds = of(ItemCategory.medication).where((m) => !DrugKnowledge.isNone(m.value)).toList();
    for (final a in realAllergies) {
      for (final m in meds) {
        final why = DrugKnowledge.allergyConflict(a.value, m.value);
        if (why != null) {
          alerts.add(WorkflowAlert(AlertSeverity.critical, 'conflict.allergyMed',
              'Medication "${m.value}" may conflict with allergy "${a.value}" ($why). Verify before administration.',
              itemIds: [a.itemId, m.itemId]));
        }
      }
    }

    // Duplicate therapy and high-alert medications.
    for (var i = 0; i < meds.length; i++) {
      for (var j = i + 1; j < meds.length; j++) {
        final dup = DrugKnowledge.duplicateTherapy(meds[i].value, meds[j].value);
        if (dup != null) {
          alerts.add(WorkflowAlert(AlertSeverity.warning, 'duplicate.therapy',
              'Possible duplicate therapy ($dup): "${meds[i].value}" and "${meds[j].value}".',
              itemIds: [meds[i].itemId, meds[j].itemId]));
        }
      }
    }
    for (final m in meds) {
      final cls = DrugKnowledge.highAlertClass(m.value);
      if (cls != null) {
        alerts.add(WorkflowAlert(AlertSeverity.info, 'highAlert',
            'High-alert medication ($cls): "${m.value}" — independent double-check recommended.',
            itemIds: [m.itemId]));
      }
      for (final issue in DoseTextChecks.issues(m.value)) {
        alerts.add(WorkflowAlert(AlertSeverity.warning, 'dose.format', '"${m.value}": $issue',
            itemIds: [m.itemId]));
      }
    }

    // Conflicting weights (>10% apart).
    final weights = of(ItemCategory.weight)
        .map((w) => MapEntry(w, double.tryParse(RegExp(r'[\d.]+').stringMatch(w.value) ?? '')))
        .where((e) => e.value != null)
        .toList();
    for (var i = 0; i < weights.length; i++) {
      for (var j = i + 1; j < weights.length; j++) {
        final a = weights[i].value!, b = weights[j].value!;
        if ((a - b).abs() / (a > b ? a : b) > 0.10) {
          alerts.add(WorkflowAlert(AlertSeverity.warning, 'conflict.weight',
              'Recorded weights differ by more than 10% ($a vs $b). Confirm units (kg vs lb) and re-weigh.',
              itemIds: [weights[i].key.itemId, weights[j].key.itemId]));
        }
      }
    }

    // Exact duplicate items.
    final seen = <String, LedgerEntry>{};
    for (final e in items) {
      final key = '${e.category.name}|${e.value.trim().toLowerCase()}';
      final prior = seen[key];
      if (prior != null) {
        alerts.add(WorkflowAlert(AlertSeverity.info, 'duplicate.entry',
            'Duplicate ${e.category.label.toLowerCase()} entry: "${e.value}".',
            itemIds: [prior.itemId, e.itemId]));
      } else {
        seen[key] = e;
      }
    }

    // Outstanding responsibilities.
    final open = tasks.where((t) => t.isOpen).toList();
    for (final t in open.where((t) => t.due != null && t.due!.isBefore(when))) {
      alerts.add(WorkflowAlert(AlertSeverity.warning, 'task.overdue', 'Overdue: ${t.title}'));
    }
    final pending = open.where((t) => t.kind == TaskKind.pendingInvestigation).length;
    if (pending > 0) {
      alerts.add(WorkflowAlert(AlertSeverity.info, 'pending.investigations',
          '$pending investigation result(s) pending — include in handoff.'));
    }

    // Possible duplicate patient records.
    for (final other in allPatients.where((p) => p.id != patient.id)) {
      if (DuplicatePatientDetector.likelyDuplicate(patient, other)) {
        alerts.add(WorkflowAlert(AlertSeverity.critical, 'duplicate.patient',
            'Possible duplicate record: ${other.fullName} (MRN ${other.mrn}). Do not merge without verification.'));
      }
    }

    alerts.sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return alerts;
  }
}

class DuplicatePatientDetector {
  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

  static int _lev(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final cur = [i + 1];
      for (var j = 0; j < b.length; j++) {
        cur.add([
          cur[j] + 1,
          prev[j + 1] + 1,
          prev[j] + (a[i] == b[j] ? 0 : 1),
        ].reduce((x, y) => x < y ? x : y));
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// Same DOB with a near-identical name, or same name with a transposed day/month.
  static bool likelyDuplicate(Patient a, Patient b) {
    if (a.mrn == b.mrn) return true;
    final nameA = _norm(a.givenName) + _norm(a.familyName);
    final nameB = _norm(b.givenName) + _norm(b.familyName);
    final swapped = _norm(b.familyName) + _norm(b.givenName);
    final nameClose = _lev(nameA, nameB) <= 2 || _lev(nameA, swapped) <= 2;
    final sameDob = a.birthDate.year == b.birthDate.year &&
        a.birthDate.month == b.birthDate.month &&
        a.birthDate.day == b.birthDate.day;
    final transposedDob = a.birthDate.year == b.birthDate.year &&
        a.birthDate.month == b.birthDate.day &&
        a.birthDate.day == b.birthDate.month;
    return nameClose && (sameDob || transposedDob);
  }
}
