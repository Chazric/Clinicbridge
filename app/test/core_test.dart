import 'dart:io';

import 'package:clinicbridge/core/app_state.dart';
import 'package:clinicbridge/core/drug_knowledge.dart';
import 'package:clinicbridge/core/handoff.dart';
import 'package:clinicbridge/core/interpreter.dart';
import 'package:clinicbridge/core/ledger.dart';
import 'package:clinicbridge/core/models.dart';
import 'package:clinicbridge/core/rbac.dart';
import 'package:clinicbridge/core/vault.dart';
import 'package:clinicbridge/core/workflow_intel.dart';
import 'package:clinicbridge/demo/synthetic_data.dart';
import 'package:flutter_test/flutter_test.dart';

final doc = Clinician(id: 'd1', name: 'Dr A', role: Role.physician);
final doc2 = Clinician(id: 'd2', name: 'Dr B', role: Role.physician);
final nurse = Clinician(id: 'n1', name: 'RN C', role: Role.nurse);
final interp = Clinician(id: 'i1', name: 'Interp', role: Role.interpreter);
final viewer = Clinician(id: 'v1', name: 'View', role: Role.viewer);

class FakeTranslator implements TranslationService {
  FakeTranslator(this.table);
  final Map<String, String> table;
  @override
  Future<String> translate(String text, {required String from, required String to}) async => table[text] ?? text;
}

Patient pat({String id = 'p1', String mrn = 'M1', String g = 'Maria', String f = 'Garcia', DateTime? dob, String sex = 'female'}) =>
    Patient(id: id, mrn: mrn, givenName: g, familyName: f, birthDate: dob ?? DateTime(1958, 3, 7), sex: sex);

void main() {
  group('Clinical Truth Ledger', () {
    test('patient-reported starts unverified; clinician-observed starts verified', () {
      final l = Ledger();
      final a = l.record(encounterId: 'e', category: ItemCategory.allergy, label: 'A', value: 'Penicillin',
          provenance: Provenance.patientReported, author: nurse, source: 'interview');
      final b = l.record(encounterId: 'e', category: ItemCategory.vital, label: 'BP', value: '120/80',
          provenance: Provenance.clinicianObserved, author: nurse, source: 'cuff');
      expect(a.verification, Verification.unverified);
      expect(b.verification, Verification.verified);
    });

    test('AI-generated content cannot be silently verified, only explicitly approved', () {
      final l = Ledger();
      final e = l.record(encounterId: 'e', category: ItemCategory.note, label: 'Summary', value: 'draft',
          provenance: Provenance.aiGenerated, author: doc, source: 'engine');
      expect(e.pendingReview, isTrue);
      expect(() => l.verify(e.itemId, doc), throwsA(isA<LedgerException>()));
      final ap = l.approve(e.itemId, doc, editedValue: 'reviewed text');
      expect(ap.provenance, Provenance.clinicianApproved);
      expect(ap.originProvenance, Provenance.aiGenerated);
      expect(ap.verification, Verification.verified);
      expect(l.history(e.itemId).length, 2);
      expect(l.history(e.itemId).first.value, 'draft');
    });

    test('cannot record content as already clinician-approved', () {
      expect(
          () => Ledger().record(encounterId: 'e', category: ItemCategory.note, label: 'x', value: 'x',
              provenance: Provenance.clinicianApproved, author: doc, source: 's'),
          throwsA(isA<LedgerException>()));
    });

    test('translated content must keep its original text', () {
      expect(
          () => Ledger().record(encounterId: 'e', category: ItemCategory.complaint, label: 'x', value: 'pain',
              provenance: Provenance.translated, author: interp, source: 's'),
          throwsA(isA<LedgerException>()));
    });

    test('interpreter cannot verify or approve', () {
      final l = Ledger();
      final e = l.record(encounterId: 'e', category: ItemCategory.complaint, label: 'x', value: 'pain',
          provenance: Provenance.translated, author: interp, source: 's', originalText: 'dolor', language: 'es');
      expect(() => l.approve(e.itemId, interp), throwsA(isA<AccessDenied>()));
      expect(() => Ledger().record(encounterId: 'e', category: ItemCategory.note, label: 'x', value: 'x',
          provenance: Provenance.clinicianObserved, author: viewer, source: 's'), throwsA(isA<AccessDenied>()));
    });

    test('amend by non-verifier keeps item unverified; history preserved', () {
      final l = Ledger();
      final e = l.record(encounterId: 'e', category: ItemCategory.medication, label: 'm', value: 'Warfarin 5 mg',
          provenance: Provenance.patientReported, author: interp, source: 's');
      final v2 = l.amend(e.itemId, interp, 'Warfarin 3 mg', 'patient corrected');
      expect(v2.verification, Verification.unverified);
      final v3 = l.amend(e.itemId, doc, 'Warfarin 3 mg daily', 'confirmed with pharmacy');
      expect(v3.verification, Verification.verified);
      expect(l.history(e.itemId).map((x) => x.version), [1, 2, 3]);
      expect(() => l.amend(e.itemId, doc, 'x', ' '), throwsA(isA<LedgerException>()));
    });

    test('hash chain detects tampering', () {
      final l = Ledger();
      for (var i = 0; i < 5; i++) {
        l.record(encounterId: 'e', category: ItemCategory.note, label: 'n', value: 'v$i',
            provenance: Provenance.clinicianObserved, author: doc, source: 's');
      }
      expect(l.verifyChain(), -1);
      final json = l.entries.map((e) => e.toJson()).toList();
      json[2]['value'] = 'tampered';
      final t = Ledger(json.map(LedgerEntry.fromJson).toList());
      expect(t.verifyChain(), 2);
    });

    test('retracted items drop out of current view but stay in history', () {
      final l = Ledger();
      final e = l.record(encounterId: 'e', category: ItemCategory.allergy, label: 'a', value: 'Latex',
          provenance: Provenance.patientReported, author: nurse, source: 's');
      l.retract(e.itemId, doc, 'wrong patient');
      expect(l.currentItems('e'), isEmpty);
      expect(l.currentItems('e', includeRetracted: true).single.verification, Verification.retracted);
    });
  });

  group('Workflow intelligence', () {
    List<WorkflowAlert> run(List<(ItemCategory, String, Provenance)> items, {Patient? p, List<ClinicalTask> tasks = const [], List<Patient>? all}) {
      final l = Ledger();
      for (final (c, v, pv) in items) {
        l.record(encounterId: 'e', category: c, label: c.label, value: v, provenance: pv, author: doc, source: 's');
      }
      final patient = p ?? pat();
      return WorkflowIntelligence.analyze(
          patient: patient,
          encounter: Encounter(id: 'e', patientId: patient.id, start: DateTime.now(), location: 'ED', responsibleClinicianId: doc.id),
          items: l.currentItems('e'),
          tasks: tasks,
          allPatients: all ?? [patient]);
    }

    Set<String> codes(List<WorkflowAlert> a) => a.map((x) => x.code).toSet();

    test('flags missing allergy, weight, code status, identity, pregnancy, consent', () {
      final c = codes(run([], p: pat(dob: DateTime(1995, 2, 1))));
      expect(c, containsAll(['missing.allergy', 'missing.weight', 'missing.codeStatus', 'identity.unverified', 'missing.pregnancy', 'missing.consent']));
    });

    test('penicillin allergy vs amoxicillin is critical', () {
      final a = run([
        (ItemCategory.allergy, 'Penicillin — hives', Provenance.clinicianObserved),
        (ItemCategory.medication, 'Amoxicillin 500 mg', Provenance.clinicianObserved),
      ]);
      expect(a.where((x) => x.code == 'conflict.allergyMed' && x.severity == AlertSeverity.critical), isNotEmpty);
    });

    test('penicillin allergy vs ceftriaxone flags cross-reactivity', () {
      final a = run([
        (ItemCategory.allergy, 'Penicillin', Provenance.clinicianObserved),
        (ItemCategory.medication, 'Ceftriaxone 2 g IV', Provenance.clinicianObserved),
      ]);
      expect(a.firstWhere((x) => x.code == 'conflict.allergyMed').message, contains('cross-reactivity'));
    });

    test('NKDA plus a real allergy is a conflict', () {
      expect(codes(run([
        (ItemCategory.allergy, 'NKDA', Provenance.clinicianObserved),
        (ItemCategory.allergy, 'Sulfa', Provenance.patientReported),
      ])), contains('conflict.nkda'));
    });

    test('two anticoagulants → duplicate therapy, high-alert', () {
      final c = codes(run([
        (ItemCategory.medication, 'Warfarin 5 mg daily', Provenance.clinicianObserved),
        (ItemCategory.medication, 'Apixaban 5 mg twice daily', Provenance.clinicianObserved),
      ]));
      expect(c, containsAll(['duplicate.therapy', 'highAlert']));
    });

    test('weights 72 vs 158 conflict (kg/lb)', () {
      expect(codes(run([
        (ItemCategory.weight, '72 kg', Provenance.clinicianObserved),
        (ItemCategory.weight, '158 kg', Provenance.imported),
      ])), contains('conflict.weight'));
    });

    test('error-prone dose text', () {
      expect(DoseTextChecks.issues('Morphine .5 mg'), isNotEmpty);
      expect(DoseTextChecks.issues('Warfarin 5.0 mg'), isNotEmpty);
      expect(DoseTextChecks.issues('Insulin 10 U'), isNotEmpty);
      expect(DoseTextChecks.issues('Warfarin 5 mg daily'), isEmpty);
      expect(DoseTextChecks.issues('Paracetamol 0.5 g'), isEmpty);
    });

    test('no false conflict for NKDA + ordinary meds', () {
      final c = codes(run([
        (ItemCategory.allergy, 'No known drug allergies', Provenance.clinicianObserved),
        (ItemCategory.medication, 'Metformin 500 mg', Provenance.clinicianObserved),
      ]));
      expect(c.intersection({'conflict.allergyMed', 'conflict.nkda'}), isEmpty);
    });

    test('duplicate patients: same DOB similar name, transposed DOB, distinct', () {
      final a = pat();
      expect(DuplicatePatientDetector.likelyDuplicate(a, pat(id: 'p2', mrn: 'M2', g: 'María', f: 'Garcia')), isTrue);
      expect(DuplicatePatientDetector.likelyDuplicate(a, pat(id: 'p3', mrn: 'M3', dob: DateTime(1958, 7, 3))), isTrue);
      expect(DuplicatePatientDetector.likelyDuplicate(a, pat(id: 'p4', mrn: 'M4', g: 'John', f: 'Smith')), isFalse);
      expect(DuplicatePatientDetector.likelyDuplicate(a, pat(id: 'p5', mrn: 'M5', dob: DateTime(1960, 1, 1))), isFalse);
    });

    test('overdue task flagged', () {
      final t = ClinicalTask(id: 't', encounterId: 'e', title: 'Troponin', kind: TaskKind.pendingInvestigation,
          ownerId: doc.id, created: DateTime.now(), due: DateTime.now().subtract(const Duration(minutes: 5)));
      expect(codes(run([], tasks: [t])), containsAll(['task.overdue', 'pending.investigations']));
    });
  });

  group('Interpreter safety', () {
    test('number words and digits extracted', () {
      expect(TranslationSafety.numbers('take twenty five mg', lang: 'en'), contains(25));
      expect(TranslationSafety.numbers('tome 25 mg', lang: 'es'), [25]);
    });

    test('faithful translation passes', () async {
      final eng = InterpreterEngine(FakeTranslator({
        'Take 2 tablets of metformin twice a day': 'Tome 2 tabletas de metformina dos veces al día',
        'Tome 2 tabletas de metformina dos veces al día': 'Take 2 tablets of metformin twice a day',
      }));
      final r = await eng.interpret('Take 2 tablets of metformin twice a day', from: 'en', to: 'es');
      expect(r.hasCritical, isFalse);
      expect(r.confidence, 1);
      expect(r.risk, ClinicalRisk.medication);
    });

    test('lost number is critical', () async {
      final eng = InterpreterEngine(FakeTranslator({
        'Take 5 mg of warfarin': 'Tome warfarina',
        'Tome warfarina': 'Take warfarin',
      }));
      final r = await eng.interpret('Take 5 mg of warfarin', from: 'en', to: 'es');
      expect(r.hasCritical, isTrue);
      expect(r.requiresHumanInterpreter, isTrue);
    });

    test('changed number is critical', () async {
      final r = TranslationSafety.assess(
          original: 'Take 15 units of insulin', translation: 'Tome 50 unidades de insulina',
          backTranslation: 'Take 50 units of insulin', from: 'en', to: 'es');
      expect(r.issues.where((i) => i.severity == IssueSeverity.critical), isNotEmpty);
    });

    test('negation flip is critical', () {
      final r = TranslationSafety.assess(
          original: 'You are not allergic to penicillin', translation: 'Usted es alérgico a la penicilina',
          backTranslation: 'You are allergic to penicillin', from: 'en', to: 'es');
      expect(r.issues.any((i) => i.message.contains('Negation')), isTrue);
    });

    test('teen/ty warning', () {
      final r = TranslationSafety.assess(
          original: 'Take fifteen drops', translation: 'Tome quince gotas', backTranslation: 'Take fifteen drops', from: 'en', to: 'es');
      expect(r.issues.any((i) => i.message.contains('misheard')), isTrue);
    });

    test('consent always escalates to a human interpreter', () {
      final r = TranslationSafety.assess(
          original: 'Do you consent to the surgery', translation: '¿Da su consentimiento para la cirugía?',
          backTranslation: 'Do you consent to the surgery', from: 'en', to: 'es');
      expect(r.risk, ClinicalRisk.consent);
      expect(r.requiresHumanInterpreter, isTrue);
    });
  });

  group('Handoff', () {
    late Handoff h;
    final p = pat();
    final enc = Encounter(id: 'e', patientId: p.id, start: DateTime.now(), location: 'ED', responsibleClinicianId: doc.id);

    setUp(() {
      h = HandoffService.draft(format: HandoffFormat.sbar, patient: p, encounter: enc, items: const [], tasks: const [],
          alerts: const [], from: doc, toId: doc2.id);
    });

    test('draft is machine-labelled and shows NOT DOCUMENTED', () {
      expect(h.machineDrafted, isTrue);
      expect(h.sections['Background'], contains('NOT DOCUMENTED'));
    });

    test('cannot send until reviewed and meds/allergies confirmed', () {
      expect(HandoffService.sendBlockers(h), isNotEmpty);
      expect(() => HandoffService.send(h, doc), throwsA(isA<HandoffException>()));
      for (final s in HandoffService.senderSections(h)) {
        HandoffService.markReviewed(h, s, doc, text: '$s ok');
      }
      expect(h.machineDrafted, isFalse);
      HandoffService.verifyMedsAllergies(h, doc);
      HandoffService.send(h, doc);
      expect(h.status, HandoffStatus.senderApproved);
    });

    test('only the named receiver accepts; responsibility transfers on accept', () {
      for (final s in HandoffService.senderSections(h)) {
        HandoffService.markReviewed(h, s, doc, text: '$s ok');
      }
      HandoffService.verifyMedsAllergies(h, doc);
      HandoffService.send(h, doc);
      expect(() => HandoffService.accept(h, nurse, enc), throwsA(isA<HandoffException>()));
      expect(enc.responsibleClinicianId, doc.id);
      HandoffService.accept(h, doc2, enc);
      expect(enc.responsibleClinicianId, doc2.id);
      expect(h.events.map((e) => e.action), containsAll(['drafted', 'sender-approved', 'accepted']));
    });

    test('I-PASS requires receiver synthesis', () {
      final ip = HandoffService.draft(format: HandoffFormat.ipass, patient: p, encounter: enc, items: const [], tasks: const [],
          alerts: const [], from: doc, toId: doc2.id);
      for (final s in HandoffService.senderSections(ip)) {
        HandoffService.markReviewed(ip, s, doc, text: '$s ok');
      }
      HandoffService.verifyMedsAllergies(ip, doc);
      HandoffService.send(ip, doc);
      expect(() => HandoffService.accept(ip, doc2, enc, synthesis: 'ok'), throwsA(isA<HandoffException>()));
      HandoffService.accept(ip, doc2, enc, synthesis: 'Stable pneumonia, chase cultures');
      expect(ip.status, HandoffStatus.accepted);
    });
  });

  group('App state, FHIR, audit, retention', () {
    test('synthetic demo loads, alerts fire, FHIR bundle valid shape, audit chain intact', () async {
      final s = AppState();
      await SyntheticData.load(s);
      expect(s.patients.every((p) => p.synthetic), isTrue);
      final codes = s.alerts('enc-maria').map((a) => a.code).toSet();
      expect(codes, containsAll(['conflict.allergyMed', 'duplicate.therapy', 'conflict.weight', 'duplicate.patient', 'review.machine', 'identity.unverified']));
      await s.signIn(s.clinician('clin-okafor')!);
      final b = s.exportFhir('enc-maria');
      expect(b['resourceType'], 'Bundle');
      final types = (b['entry'] as List).map((e) => e['resource']['resourceType']).toSet();
      expect(types, containsAll(['Patient', 'Encounter', 'AllergyIntolerance', 'MedicationStatement', 'Observation', 'Provenance', 'Task', 'Condition']));
      final ai = (b['entry'] as List).map((e) => e['resource']).firstWhere((r) => r['resourceType'] == 'Observation' &&
          (r['meta']['tag'] as List).any((t) => t['code'] == 'aiGenerated'));
      expect(ai['status'], 'preliminary');
      expect(s.verifyAuditChain(), -1);
      expect(s.ledger.verifyChain(), -1);
    });

    test('patient record isolation: items never leak across encounters', () async {
      final s = AppState();
      await SyntheticData.load(s);
      for (final e in s.encounters) {
        expect(s.items(e.id).every((i) => i.encounterId == e.id), isTrue);
      }
      await s.signIn(s.clinician('clin-okafor')!);
      final b = s.exportFhir('enc-jean');
      final text = b.toString();
      expect(text.contains('Warfarin'), isFalse);
      expect(text.contains('Garcia'), isFalse);
    });

    test('identity check needs both identifiers', () async {
      final s = AppState();
      await SyntheticData.load(s);
      await s.signIn(s.clinician('clin-patel')!);
      final m = s.patient('pat-maria');
      expect(await s.verifyIdentity(m, statedName: 'Maria Garcia Lopez', statedDob: DateTime(1958, 7, 3)), isFalse);
      expect(m.identityVerified, isFalse);
      expect(await s.verifyIdentity(m, statedName: 'maria garcia-lopez', statedDob: DateTime(1958, 3, 7)), isTrue);
      expect(s.audit.map((a) => a.action), containsAll(['identity-mismatch', 'identity-verified']));
    });

    test('state survives JSON round trip', () async {
      final s = AppState();
      await SyntheticData.load(s);
      final t = AppState()..loadJson(s.toJson());
      expect(t.ledger.verifyChain(), -1);
      expect(t.verifyAuditChain(), -1);
      expect(t.items('enc-maria').length, s.items('enc-maria').length);
    });

    test('retention purges closed old encounters only', () async {
      final s = AppState();
      await SyntheticData.load(s);
      await s.signIn(s.clinician('clin-chen')!);
      await s.closeEncounter(s.encounter('enc-jean'));
      expect(await s.applyRetention(now: DateTime.now().add(const Duration(days: 31))), 1);
      expect(s.encounters.any((e) => e.id == 'enc-jean'), isFalse);
      expect(s.encounters.any((e) => e.id == 'enc-maria'), isTrue);
      expect(s.ledger.verifyChain(), -1);
      expect(s.audit.any((a) => a.action == 'retention-purge'), isTrue);
    });

    test('admin cannot write clinical data; viewer cannot export', () {
      expect(Rbac.can(Role.admin, Permission.addEntry), isFalse);
      expect(Rbac.can(Role.viewer, Permission.exportData), isFalse);
      expect(Rbac.can(Role.interpreter, Permission.approveMachineContent), isFalse);
    });
  });

  group('Vault & PIN', () {
    test('encrypted at rest, recoverable from backup, shredded on destroy', () async {
      final dir = await Directory.systemTemp.createTemp('cbvault');
      final v = Vault(dir: dir, secrets: InMemorySecretStore());
      await v.save({'a': 'Garcia'});
      expect(await v.file.readAsString(), isNot(contains('Garcia')));
      await v.save({'a': 'second'});
      await v.file.writeAsString('corrupt');
      expect((await v.load())!['a'], 'Garcia');
      await v.destroy();
      expect(await v.load(), isNull);
    });

    test('passphrase backup round trip and wrong passphrase rejected', () async {
      final blob = await Vault.exportBackup({'x': 1}, 'correct horse battery');
      expect((await Vault.importBackup(blob, 'correct horse battery'))['x'], 1);
      expect(() => Vault.importBackup(blob, 'wrong passphrase!'), throwsA(isA<VaultException>()));
    });

    test('PIN strength, check and lockout', () async {
      final g = PinGuard(InMemorySecretStore());
      expect(PinGuard.weakness('1234'), isNotNull);
      expect(PinGuard.weakness('123456'), isNotNull);
      expect(PinGuard.weakness('111111'), isNotNull);
      await g.setPin('583920');
      expect(await g.check('583920'), isTrue);
      for (var i = 0; i < 5; i++) {
        await g.check('000001');
      }
      expect(await g.lockedFor(), isNotNull);
      expect(await g.check('583920'), isFalse);
    });
  });
}
