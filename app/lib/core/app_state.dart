import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'fhir.dart';
import 'handoff.dart';
import 'licence.dart';
import 'ledger.dart';
import 'models.dart';
import 'rbac.dart';
import 'workflow_intel.dart';

typedef Persist = Future<void> Function(Map<String, dynamic> snapshot);

class AppSettings {
  AppSettings({
    this.retentionDays = 30,
    this.fhirProfile = FhirProfile.baseR4,
    this.interpreterServicePhone = '',
    this.autoLockMinutes = 2,
    this.licenceKey = '',
    this.licenceToken = '',
    this.licenceSig = '',
    String? deviceId,
  }) : deviceId = deviceId == null || deviceId.isEmpty ? newDeviceId() : deviceId;

  /// Closed encounters older than this are purged from the device.
  int retentionDays;
  FhirProfile fhirProfile;

  /// Hospital's qualified-interpreter line (configured per site).
  String interpreterServicePhone;
  int autoLockMinutes;

  /// Clinic licence key and the last server-signed licence for this install.
  String licenceKey;
  String licenceToken;
  String licenceSig;

  /// Random per-install id; the only device identifier sent to the licence server.
  String deviceId;

  Map<String, dynamic> toJson() => {
        'retentionDays': retentionDays,
        'fhirProfile': fhirProfile.name,
        'interpreterServicePhone': interpreterServicePhone,
        'autoLockMinutes': autoLockMinutes,
        'licenceKey': licenceKey,
        'licenceToken': licenceToken,
        'licenceSig': licenceSig,
        'deviceId': deviceId,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        retentionDays: j['retentionDays'] ?? 30,
        fhirProfile: FhirProfile.values.firstWhere((p) => p.name == j['fhirProfile'], orElse: () => FhirProfile.baseR4),
        interpreterServicePhone: j['interpreterServicePhone'] ?? '',
        autoLockMinutes: j['autoLockMinutes'] ?? 2,
        licenceKey: j['licenceKey'] ?? '',
        licenceToken: j['licenceToken'] ?? '',
        licenceSig: j['licenceSig'] ?? '',
        deviceId: j['deviceId'] as String?,
      );
}

/// Single source of truth for the app. All mutations are permission-checked
/// and written to the hash-chained audit log.
class AppState extends ChangeNotifier {
  AppState({Persist? persist, LicenceVerifier? licenceVerifier, LicenceTransport? licenceTransport})
      : _persist = persist, // ignore: prefer_initializing_formals
        _verifier = licenceVerifier ?? LicenceVerifier(),
        _transport = licenceTransport ?? httpLicenceTransport;

  static const _uuid = Uuid();
  final Persist? _persist;
  final LicenceVerifier _verifier;
  final LicenceTransport _transport;

  /// Verified licence for this device, or null (synthetic demo only).
  Licence? licence;
  bool get licensed => licence?.isActiveFor(settings.deviceId, DateTime.now()) ?? false;

  final List<Clinician> clinicians = [];
  final List<Patient> patients = [];
  final List<Encounter> encounters = [];
  Ledger ledger = Ledger();
  final List<ClinicalTask> tasks = [];
  final List<Handoff> handoffs = [];
  final List<AuditEvent> audit = [];
  AppSettings settings = AppSettings();
  Clinician? currentUser;

  Clinician get user {
    final u = currentUser;
    if (u == null) throw StateError('No user signed in');
    return u;
  }

  Map<String, Clinician> get clinicianMap => {for (final c in clinicians) c.id: c};
  Clinician? clinician(String id) => clinicianMap[id];

  bool can(Permission p) => currentUser != null && Rbac.can(currentUser!.role, p);

  // ---------- persistence ----------
  Map<String, dynamic> toJson() => {
        'schema': 1,
        'clinicians': clinicians.map((c) => c.toJson()).toList(),
        'patients': patients.map((p) => p.toJson()).toList(),
        'encounters': encounters.map((e) => e.toJson()).toList(),
        'ledger': ledger.entries.map((e) => e.toJson()).toList(),
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'handoffs': handoffs.map((h) => h.toJson()).toList(),
        'audit': audit.map((a) => a.toJson()).toList(),
        'settings': settings.toJson(),
        'currentUser': currentUser?.id,
      };

  void loadJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> l(String k) =>
        (j[k] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    clinicians
      ..clear()
      ..addAll(l('clinicians').map(Clinician.fromJson));
    patients
      ..clear()
      ..addAll(l('patients').map(Patient.fromJson));
    encounters
      ..clear()
      ..addAll(l('encounters').map(Encounter.fromJson));
    ledger = Ledger(l('ledger').map(LedgerEntry.fromJson).toList());
    tasks
      ..clear()
      ..addAll(l('tasks').map(ClinicalTask.fromJson));
    handoffs
      ..clear()
      ..addAll(l('handoffs').map(Handoff.fromJson));
    audit
      ..clear()
      ..addAll(l('audit').map(AuditEvent.fromJson));
    settings = j['settings'] == null ? AppSettings() : AppSettings.fromJson(Map<String, dynamic>.from(j['settings']));
    final cu = j['currentUser'];
    currentUser = cu == null ? null : clinicianMap[cu];
    notifyListeners();
  }

  Future<void> commit() async {
    notifyListeners();
    await _persist?.call(toJson());
  }

  // ---------- audit ----------
  void log(String action, String target, [String? detail]) {
    final actor = currentUser;
    final e = AuditEvent(
      at: DateTime.now(),
      actorId: actor?.id ?? 'system',
      role: actor?.role ?? Role.admin,
      action: action,
      target: target,
      detail: detail,
      prevHash: audit.isEmpty ? 'GENESIS' : audit.last.hash,
    );
    e.hash = e.computeHash();
    audit.add(e);
  }

  int verifyAuditChain() {
    var prev = 'GENESIS';
    for (var i = 0; i < audit.length; i++) {
      if (audit[i].prevHash != prev || audit[i].computeHash() != audit[i].hash) return i;
      prev = audit[i].hash;
    }
    return -1;
  }

  // ---------- session ----------
  Future<void> signIn(Clinician c) async {
    currentUser = c;
    log('sign-in', c.id, c.role.label);
    await commit();
  }

  Future<void> signOut() async {
    if (currentUser != null) log('sign-out', currentUser!.id);
    currentUser = null;
    await commit();
  }

  Future<Clinician> addClinician(String name, Role role) async {
    final c = Clinician(id: _uuid.v4(), name: name, role: role);
    clinicians.add(c);
    log('profile-created', c.id, '${c.name} (${role.label})');
    await commit();
    return c;
  }

  // ---------- queries ----------
  Patient patient(String id) => patients.firstWhere((p) => p.id == id);
  Encounter encounter(String id) => encounters.firstWhere((e) => e.id == id);
  List<Encounter> encountersFor(String patientId) =>
      encounters.where((e) => e.patientId == patientId).toList()..sort((a, b) => b.start.compareTo(a.start));
  List<LedgerEntry> items(String encounterId) => ledger.currentItems(encounterId);
  List<ClinicalTask> tasksFor(String encounterId) => tasks.where((t) => t.encounterId == encounterId).toList();
  List<Handoff> handoffsFor(String encounterId) =>
      handoffs.where((h) => h.encounterId == encounterId).toList()..sort((a, b) => b.created.compareTo(a.created));
  List<Handoff> get inbox => currentUser == null
      ? []
      : handoffs.where((h) => h.toId == currentUser!.id && h.status == HandoffStatus.senderApproved).toList();

  List<WorkflowAlert> alerts(String encounterId) {
    final enc = encounter(encounterId);
    return WorkflowIntelligence.analyze(
      patient: patient(enc.patientId),
      encounter: enc,
      items: items(encounterId),
      tasks: tasksFor(encounterId),
      allPatients: patients,
    );
  }

  /// Timeline of ledger versions, tasks and handoff events, newest first.
  List<(DateTime, String, String)> timeline(String encounterId) {
    final out = <(DateTime, String, String)>[];
    for (final e in ledger.entries.where((e) => e.encounterId == encounterId)) {
      final who = clinician(e.authorId)?.name ?? e.authorId;
      final verb = e.version == 1 ? 'recorded' : (e.changeReason ?? 'updated');
      out.add((e.timestamp, '${e.category.label}: ${e.value}', '$verb · ${e.provenance.label} · $who'));
    }
    for (final t in tasksFor(encounterId)) {
      out.add((t.created, 'Task: ${t.title}', 'created · ${t.status.name}'));
      if (t.completedAt != null) out.add((t.completedAt!, 'Task done: ${t.title}', clinician(t.completedBy ?? '')?.name ?? ''));
    }
    for (final h in handoffsFor(encounterId)) {
      for (final ev in h.events) {
        out.add((ev.at, '${h.format.label} handoff: ${ev.action}', '${clinician(ev.actorId)?.name ?? ev.actorId}${ev.detail == null ? '' : ' · ${ev.detail}'}'));
      }
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return out;
  }

  // ---------- patients & encounters ----------
  Future<Patient> registerPatient({
    required String givenName,
    required String familyName,
    required DateTime birthDate,
    required String sex,
    required String preferredLanguage,
    required bool interpreterNeeded,
    required String location,
  }) async {
    Rbac.require(user.role, Permission.addEntry);
    if (!licensed) {
      throw LicenceException('A clinic licence is required to record real patients. The synthetic demo stays free. '
          'Enter your clinic\'s licence key in Settings → Licence.');
    }
    final p = Patient(
      id: _uuid.v4(),
      mrn: 'CB-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}',
      givenName: givenName,
      familyName: familyName,
      birthDate: birthDate,
      sex: sex,
      preferredLanguage: preferredLanguage,
      interpreterNeeded: interpreterNeeded,
      synthetic: false,
    );
    patients.add(p);
    final enc = Encounter(
      id: _uuid.v4(),
      patientId: p.id,
      start: DateTime.now(),
      location: location,
      responsibleClinicianId: user.id,
    );
    encounters.add(enc);
    log('patient-registered', p.id, 'MRN ${p.mrn}');
    log('encounter-opened', enc.id, location);
    await commit();
    return p;
  }

  /// Two-identifier check: the clinician must re-enter name and DOB as stated
  /// by the patient (or wristband) and both must match.
  Future<bool> verifyIdentity(Patient p, {required String statedName, required DateTime statedDob}) async {
    Rbac.require(user.role, Permission.verifyIdentity);
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    final nameOk = n(statedName) == n(p.fullName) || n(statedName) == n('${p.familyName}${p.givenName}');
    final dobOk = statedDob.year == p.birthDate.year &&
        statedDob.month == p.birthDate.month &&
        statedDob.day == p.birthDate.day;
    final ok = nameOk && dobOk;
    log(ok ? 'identity-verified' : 'identity-mismatch', p.id, 'name:${nameOk ? 'ok' : 'no'} dob:${dobOk ? 'ok' : 'no'}');
    if (ok) {
      p.identityVerifiedBy = user.id;
      p.identityVerifiedAt = DateTime.now();
    }
    await commit();
    return ok;
  }

  Future<void> recordConsent(Encounter e, String reference) async {
    Rbac.require(user.role, Permission.addEntry);
    e.consentRef = reference;
    log('consent-recorded', e.id, reference);
    await commit();
  }

  Future<void> setInterpreterNeeded(Patient p, bool needed, String language) async {
    p.interpreterNeeded = needed;
    p.preferredLanguage = language;
    log('language-updated', p.id, '$language interpreter:$needed');
    await commit();
  }

  // ---------- ledger ----------
  Future<LedgerEntry> record({
    required String encounterId,
    required ItemCategory category,
    required String label,
    required String value,
    required Provenance provenance,
    required String source,
    String? language,
    String? originalText,
    double? confidence,
  }) async {
    final e = ledger.record(
      encounterId: encounterId,
      category: category,
      label: label,
      value: value,
      provenance: provenance,
      author: user,
      source: source,
      consentRef: encounter(encounterId).consentRef,
      language: language,
      originalText: originalText,
      confidence: confidence,
    );
    log('ledger-record', e.itemId, '${category.name}/${provenance.name}');
    await commit();
    return e;
  }

  Future<void> verify(String itemId) async {
    ledger.verify(itemId, user);
    log('ledger-verify', itemId);
    await commit();
  }

  Future<void> approve(String itemId, {String? editedValue}) async {
    ledger.approve(itemId, user, editedValue: editedValue);
    log('ledger-approve', itemId, editedValue == null ? null : 'edited');
    await commit();
  }

  Future<void> amend(String itemId, String value, String reason) async {
    ledger.amend(itemId, user, value, reason);
    log('ledger-amend', itemId, reason);
    await commit();
  }

  Future<void> dispute(String itemId, String reason) async {
    ledger.dispute(itemId, user, reason);
    log('ledger-dispute', itemId, reason);
    await commit();
  }

  Future<void> retract(String itemId, String reason) async {
    ledger.retract(itemId, user, reason);
    log('ledger-retract', itemId, reason);
    await commit();
  }

  // ---------- tasks ----------
  Future<void> addTask(String encounterId, String title, TaskKind kind, {DateTime? due}) async {
    Rbac.require(user.role, Permission.manageTasks);
    final t = ClinicalTask(
        id: _uuid.v4(), encounterId: encounterId, title: title, kind: kind, ownerId: user.id, created: DateTime.now(), due: due);
    tasks.add(t);
    log('task-created', t.id, title);
    await commit();
  }

  Future<void> completeTask(ClinicalTask t) async {
    Rbac.require(user.role, Permission.manageTasks);
    t.status = TaskStatus.done;
    t.completedBy = user.id;
    t.completedAt = DateTime.now();
    log('task-completed', t.id, t.title);
    await commit();
  }

  // ---------- handoff ----------
  Future<Handoff> draftHandoff(String encounterId, HandoffFormat format, String toId) async {
    final enc = encounter(encounterId);
    final h = HandoffService.draft(
      format: format,
      patient: patient(enc.patientId),
      encounter: enc,
      items: items(encounterId),
      tasks: tasksFor(encounterId),
      alerts: alerts(encounterId),
      from: user,
      toId: toId,
    );
    handoffs.add(h);
    log('handoff-drafted', h.id, format.label);
    await commit();
    return h;
  }

  Future<void> reviewHandoffSection(Handoff h, String section, String text) async {
    HandoffService.markReviewed(h, section, user, text: text);
    log('handoff-section-reviewed', h.id, section);
    await commit();
  }

  Future<void> confirmHandoffMedsAllergies(Handoff h) async {
    HandoffService.verifyMedsAllergies(h, user);
    log('handoff-meds-allergies-verified', h.id);
    await commit();
  }

  Future<void> sendHandoff(Handoff h) async {
    HandoffService.send(h, user);
    log('handoff-sent', h.id, 'to ${h.toId}');
    await commit();
  }

  Future<void> acceptHandoff(Handoff h, {String? synthesis}) async {
    final enc = encounter(h.encounterId);
    HandoffService.accept(h, user, enc, synthesis: synthesis);
    enc.status = EncounterStatus.handedOff;
    log('handoff-accepted', h.id, 'responsibility → ${user.id}');
    await commit();
  }

  Future<void> rejectHandoff(Handoff h, String reason) async {
    HandoffService.reject(h, user, reason);
    log('handoff-returned', h.id, reason);
    await commit();
  }

  // ---------- export & governance ----------
  Map<String, dynamic> exportFhir(String encounterId) {
    Rbac.require(user.role, Permission.exportData);
    final enc = encounter(encounterId);
    final b = FhirExporter.bundle(
      patient: patient(enc.patientId),
      encounter: enc,
      items: ledger.currentItems(encounterId, includeRetracted: true),
      tasks: tasksFor(encounterId),
      handoffs: handoffsFor(encounterId),
      clinicians: clinicianMap,
      profile: settings.fhirProfile,
    );
    log('fhir-export', encounterId, settings.fhirProfile.name);
    commit();
    return b;
  }

  Future<void> closeEncounter(Encounter e) async {
    e.status = EncounterStatus.closed;
    log('encounter-closed', e.id);
    await commit();
  }

  /// Removes closed encounters past the retention window. Returns count purged.
  Future<int> applyRetention({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(Duration(days: settings.retentionDays));
    final expired = encounters.where((e) => e.status != EncounterStatus.active && e.start.isBefore(cutoff)).toList();
    for (final e in expired) {
      ledger.removeEncounter(e.id);
      tasks.removeWhere((t) => t.encounterId == e.id);
      handoffs.removeWhere((h) => h.encounterId == e.id);
      encounters.remove(e);
      log('retention-purge', e.id, 'older than ${settings.retentionDays} days');
    }
    patients.removeWhere((p) => !encounters.any((e) => e.patientId == p.id));
    if (expired.isNotEmpty) await commit();
    return expired.length;
  }

  Future<void> deletePatient(Patient p, String reason) async {
    Rbac.require(user.role, Permission.manageData);
    for (final e in encountersFor(p.id)) {
      ledger.removeEncounter(e.id);
      tasks.removeWhere((t) => t.encounterId == e.id);
      handoffs.removeWhere((h) => h.encounterId == e.id);
      encounters.remove(e);
    }
    patients.remove(p);
    log('patient-deleted', p.id, reason);
    await commit();
  }

  void clearAll() {
    clinicians.clear();
    patients.clear();
    encounters.clear();
    ledger = Ledger();
    tasks.clear();
    handoffs.clear();
    audit.clear();
    settings = AppSettings();
    currentUser = null;
    notifyListeners();
  }

  // ---------- licence ----------
  /// Re-verifies the stored signed licence (offline); call after loading or restoring.
  Future<void> reloadLicence() async {
    final t = settings.licenceToken, sig = settings.licenceSig;
    licence = t.isEmpty || sig.isEmpty ? null : await _verifier.verify(t, sig);
    notifyListeners();
  }

  /// Activates (or refreshes) this device against the clinic licence key; uses one seat.
  Future<Licence> activateLicence(String key) async {
    final k = key.trim().toUpperCase();
    if (!RegExp(r'^CB(-[A-Z2-9]{4}){4}$').hasMatch(k)) {
      throw LicenceException('Licence keys look like CB-XXXX-XXXX-XXXX-XXXX.');
    }
    final r = await _transport('/v1/billing/activate', {'licence_key': k, 'device_id': settings.deviceId});
    final token = r['token'] as String? ?? '', sig = r['sig'] as String? ?? '';
    final l = await _verifier.verify(token, sig);
    if (l == null || l.device != settings.deviceId) {
      throw LicenceException('The licence server response could not be verified.');
    }
    settings
      ..licenceKey = k
      ..licenceToken = token
      ..licenceSig = sig;
    licence = l;
    log('licence-activated', 'licence', '${l.status}, ${l.devicesUsed}/${l.seats} seats');
    await commit();
    return l;
  }

  Future<Licence?> refreshLicence() async {
    if (settings.licenceKey.isEmpty) return null;
    return activateLicence(settings.licenceKey);
  }

  /// Frees this device's seat. Records already on the device are kept, but no new
  /// real-patient encounters can be created until a licence is entered again.
  Future<void> removeLicence() async {
    if (settings.licenceKey.isNotEmpty) {
      await _transport('/v1/billing/deactivate', {'licence_key': settings.licenceKey, 'device_id': settings.deviceId});
    }
    settings
      ..licenceKey = ''
      ..licenceToken = ''
      ..licenceSig = '';
    licence = null;
    log('licence-removed', 'licence');
    await commit();
  }

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(settings);
    log('settings-updated', 'settings');
    await commit();
  }
}
