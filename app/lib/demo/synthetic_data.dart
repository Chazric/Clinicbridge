import '../core/app_state.dart';
import '../core/models.dart';

/// Fictional, synthetic records for demonstration only. No real patient data
/// may ever be loaded into demo, development or test builds.
class SyntheticData {
  static Future<void> load(AppState s) async {
    final now = DateTime.now();
    final okafor = Clinician(id: 'clin-okafor', name: 'Dr. Ada Okafor', role: Role.physician);
    final chen = Clinician(id: 'clin-chen', name: 'Dr. Lucas Chen', role: Role.physician);
    final patel = Clinician(id: 'clin-patel', name: 'RN Sofia Patel', role: Role.nurse);
    final rossi = Clinician(id: 'clin-rossi', name: 'Marco Rossi (Interpreter)', role: Role.interpreter);
    final admin = Clinician(id: 'clin-admin', name: 'Site Administrator', role: Role.admin);
    s.clinicians.addAll([okafor, chen, patel, rossi, admin]);

    Patient p(String id, String mrn, String g, String f, DateTime dob, String sex, String lang, bool interp) => Patient(
        id: id, mrn: mrn, givenName: g, familyName: f, birthDate: dob, sex: sex,
        preferredLanguage: lang, interpreterNeeded: interp, synthetic: true);

    final maria = p('pat-maria', 'SYN-100231', 'Maria', 'Garcia Lopez', DateTime(1958, 3, 7), 'female', 'es', true);
    final mariaDup = p('pat-maria2', 'SYN-100877', 'María', 'Garcia-Lopez', DateTime(1958, 7, 3), 'female', 'es', true);
    final jean = p('pat-jean', 'SYN-100412', 'Jean-Baptiste', 'Pierre', DateTime(1979, 11, 21), 'male', 'ht', true);
    final amina = p('pat-amina', 'SYN-100598', 'Amina', 'Yusuf', DateTime(1994, 5, 14), 'female', 'en', false);
    s.patients.addAll([maria, mariaDup, jean, amina]);

    Encounter enc(String id, Patient pt, String loc, int minsAgo, String clin) => Encounter(
        id: id, patientId: pt.id, start: now.subtract(Duration(minutes: minsAgo)), location: loc, responsibleClinicianId: clin);
    final e1 = enc('enc-maria', maria, 'ED Bay 4', 180, okafor.id)..consentRef = 'CONSENT-SYN-7781 (verbal, via interpreter)';
    final e2 = enc('enc-maria2', mariaDup, 'Registration', 30, patel.id);
    final e3 = enc('enc-jean', jean, 'Ward 6B, Bed 12', 600, chen.id);
    final e4 = enc('enc-amina', amina, 'Maternity Triage 2', 90, okafor.id)..consentRef = 'CONSENT-SYN-7802 (written)';
    s.encounters.addAll([e1, e2, e3, e4]);

    s.currentUser = patel;
    Future<void> r(Encounter e, Clinician who, ItemCategory c, String label, String value, Provenance pv, String src,
        {String? lang, String? orig, double? conf}) async {
      s.currentUser = who;
      await s.record(encounterId: e.id, category: c, label: label, value: value, provenance: pv, source: src,
          language: lang, originalText: orig, confidence: conf);
    }

    // Maria — chest pain, Spanish speaker; seeded with realistic safety issues.
    await r(e1, rossi, ItemCategory.complaint, 'Chief complaint', 'Chest pressure for 2 hours, radiating to left arm',
        Provenance.translated, 'Interpreter session (ES→EN)', lang: 'es', orig: 'Presión en el pecho desde hace 2 horas, se me va al brazo izquierdo', conf: 0.82);
    await r(e1, patel, ItemCategory.allergy, 'Allergy', 'Penicillin — hives', Provenance.patientReported, 'Patient interview via interpreter');
    await r(e1, patel, ItemCategory.medication, 'Home medication', 'Warfarin 5 mg daily', Provenance.patientReported, 'Patient interview via interpreter');
    await r(e1, okafor, ItemCategory.medication, 'Medication', 'Apixaban 5 mg twice daily', Provenance.imported, 'Referral letter from primary care (synthetic)');
    await r(e1, okafor, ItemCategory.medication, 'Medication', 'Amoxicillin 500 mg three times daily', Provenance.imported, 'Referral letter from primary care (synthetic)');
    await r(e1, okafor, ItemCategory.medication, 'Medication', 'Metformin 1000 mg twice daily', Provenance.imported, 'Referral letter from primary care (synthetic)');
    await r(e1, patel, ItemCategory.weight, 'Weight', '72 kg', Provenance.clinicianObserved, 'Bed scale');
    await r(e1, okafor, ItemCategory.weight, 'Weight', '158 kg', Provenance.imported, 'Referral letter (unit likely lb)');
    await r(e1, patel, ItemCategory.vital, 'Vitals', 'BP 162/94, HR 104, RR 20, SpO2 95% RA, T 36.9 °C', Provenance.clinicianObserved, 'Monitor');
    await r(e1, okafor, ItemCategory.history, 'Past history', 'Type 2 diabetes; atrial fibrillation', Provenance.patientReported, 'Patient interview via interpreter');
    await r(e1, okafor, ItemCategory.problem, 'Working problem', 'Suspected acute coronary syndrome', Provenance.clinicianObserved, 'Clinical assessment');
    await r(e1, okafor, ItemCategory.note, 'Encounter summary', 'Draft: 65-year-old woman with chest pressure, on two anticoagulants per records; penicillin allergy conflicts with listed amoxicillin.',
        Provenance.aiGenerated, 'Drafting engine (rule-based, unreviewed)');

    // Jean-Baptiste — ward patient awaiting handoff.
    await r(e3, chen, ItemCategory.complaint, 'Admission reason', 'Community-acquired pneumonia, day 2', Provenance.clinicianObserved, 'Admission note');
    await r(e3, chen, ItemCategory.allergy, 'Allergy', 'No known drug allergies', Provenance.clinicianObserved, 'Confirmed with patient and family');
    await r(e3, chen, ItemCategory.medication, 'Inpatient medication', 'Ceftriaxone 2 g IV daily', Provenance.clinicianObserved, 'Medication chart');
    await r(e3, chen, ItemCategory.medication, 'Inpatient medication', 'Insulin glargine 20 units at night', Provenance.clinicianObserved, 'Medication chart');
    await r(e3, patel, ItemCategory.weight, 'Weight', '81 kg', Provenance.clinicianObserved, 'Standing scale');
    await r(e3, chen, ItemCategory.codeStatus, 'Code status', 'Full code (discussed with patient via interpreter)', Provenance.clinicianObserved, 'Goals-of-care discussion');
    await r(e3, patel, ItemCategory.vital, 'Vitals', 'BP 118/72, HR 92, RR 22, SpO2 93% on 2 L, T 38.1 °C', Provenance.clinicianObserved, 'Obs round');
    await r(e3, chen, ItemCategory.problem, 'Working problem', 'Right lower lobe pneumonia', Provenance.clinicianObserved, 'Chest X-ray + exam');

    // Amina — English speaker, mostly complete record.
    await r(e4, okafor, ItemCategory.complaint, 'Chief complaint', 'Headache and visual disturbance, 34 weeks pregnant', Provenance.clinicianObserved, 'Triage');
    await r(e4, okafor, ItemCategory.pregnancy, 'Pregnancy', 'Pregnant — 34 weeks, G2P1', Provenance.clinicianObserved, 'Antenatal record');
    await r(e4, okafor, ItemCategory.allergy, 'Allergy', 'No known drug allergies', Provenance.patientReported, 'Patient');
    await r(e4, okafor, ItemCategory.medication, 'Medication', 'None', Provenance.patientReported, 'Patient');
    await r(e4, patel, ItemCategory.vital, 'Vitals', 'BP 158/104, HR 88, urine protein 2+', Provenance.clinicianObserved, 'Triage');

    s.currentUser = okafor;
    s.tasks.addAll([
      ClinicalTask(id: 'task-1', encounterId: e1.id, title: 'Repeat troponin at 3 h', kind: TaskKind.pendingInvestigation, ownerId: okafor.id, created: now.subtract(const Duration(minutes: 170)), due: now.add(const Duration(minutes: 10))),
      ClinicalTask(id: 'task-2', encounterId: e1.id, title: 'Reconcile anticoagulants with pharmacy', kind: TaskKind.task, ownerId: okafor.id, created: now.subtract(const Duration(minutes: 120)), due: now.subtract(const Duration(minutes: 30))),
      ClinicalTask(id: 'task-3', encounterId: e3.id, title: 'Blood culture result pending', kind: TaskKind.pendingInvestigation, ownerId: chen.id, created: now.subtract(const Duration(hours: 9))),
      ClinicalTask(id: 'task-4', encounterId: e3.id, title: 'Recheck temperature 22:00 and notify if > 38.5 °C', kind: TaskKind.followUp, ownerId: chen.id, created: now.subtract(const Duration(hours: 2))),
      ClinicalTask(id: 'task-5', encounterId: e4.id, title: 'Repeat BP in 15 min', kind: TaskKind.task, ownerId: patel.id, created: now.subtract(const Duration(minutes: 20))),
    ]);
    jean.identityVerifiedBy = chen.id;
    jean.identityVerifiedAt = now.subtract(const Duration(hours: 9));
    amina.identityVerifiedBy = okafor.id;
    amina.identityVerifiedAt = now.subtract(const Duration(minutes: 85));
    s.log('demo-data-loaded', 'all', 'Synthetic records only');
    s.currentUser = null;
    await s.commit();
  }
}
