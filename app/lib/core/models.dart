import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Where a clinical fact came from. Never collapsed into "confirmed".
enum Provenance {
  patientReported('Patient-reported'),
  clinicianObserved('Clinician-observed'),
  imported('Imported'),
  aiGenerated('AI-generated'),
  translated('Translated'),
  clinicianApproved('Clinician-approved');

  const Provenance(this.label);
  final String label;

  /// Content that must stay flagged until a clinician reviews it.
  bool get requiresReview => this == aiGenerated || this == translated;
}

enum Verification {
  unverified('Unverified'),
  verified('Verified'),
  disputed('Disputed'),
  retracted('Retracted');

  const Verification(this.label);
  final String label;
}

enum ItemCategory {
  identity('Identity'),
  complaint('Presenting complaint'),
  history('History'),
  vital('Vital sign'),
  weight('Weight'),
  allergy('Allergy'),
  medication('Medication'),
  problem('Problem / working diagnosis'),
  investigation('Investigation'),
  codeStatus('Code status / goals of care'),
  isolation('Isolation precautions'),
  pregnancy('Pregnancy status'),
  note('Note');

  const ItemCategory(this.label);
  final String label;
}

enum Role {
  physician('Physician'),
  nurse('Nurse'),
  interpreter('Interpreter'),
  admin('Administrator'),
  viewer('Read-only');

  const Role(this.label);
  final String label;
}

String canonicalHash(Map<String, dynamic> json) {
  final keys = json.keys.toList()..sort();
  final ordered = {for (final k in keys) k: json[k]};
  return sha256.convert(utf8.encode(jsonEncode(ordered))).toString();
}

T _enum<T extends Enum>(List<T> values, Object? name) =>
    values.firstWhere((v) => v.name == name, orElse: () => values.first);

class Clinician {
  Clinician({required this.id, required this.name, required this.role});
  final String id;
  final String name;
  final Role role;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'role': role.name};
  factory Clinician.fromJson(Map<String, dynamic> j) =>
      Clinician(id: j['id'], name: j['name'], role: _enum(Role.values, j['role']));
}

class Patient {
  Patient({
    required this.id,
    required this.mrn,
    required this.givenName,
    required this.familyName,
    required this.birthDate,
    required this.sex,
    this.preferredLanguage = 'en',
    this.interpreterNeeded = false,
    this.identityVerifiedBy,
    this.identityVerifiedAt,
    this.synthetic = true,
  });

  final String id;
  final String mrn;
  final String givenName;
  final String familyName;
  final DateTime birthDate;
  final String sex;
  String preferredLanguage;
  bool interpreterNeeded;
  String? identityVerifiedBy;
  DateTime? identityVerifiedAt;
  final bool synthetic;

  String get fullName => '$givenName $familyName';
  bool get identityVerified => identityVerifiedBy != null;

  int ageOn(DateTime when) {
    var age = when.year - birthDate.year;
    if (when.month < birthDate.month ||
        (when.month == birthDate.month && when.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mrn': mrn,
        'givenName': givenName,
        'familyName': familyName,
        'birthDate': birthDate.toIso8601String(),
        'sex': sex,
        'preferredLanguage': preferredLanguage,
        'interpreterNeeded': interpreterNeeded,
        'identityVerifiedBy': identityVerifiedBy,
        'identityVerifiedAt': identityVerifiedAt?.toIso8601String(),
        'synthetic': synthetic,
      };

  factory Patient.fromJson(Map<String, dynamic> j) => Patient(
        id: j['id'],
        mrn: j['mrn'],
        givenName: j['givenName'],
        familyName: j['familyName'],
        birthDate: DateTime.parse(j['birthDate']),
        sex: j['sex'],
        preferredLanguage: j['preferredLanguage'] ?? 'en',
        interpreterNeeded: j['interpreterNeeded'] ?? false,
        identityVerifiedBy: j['identityVerifiedBy'],
        identityVerifiedAt: j['identityVerifiedAt'] == null
            ? null
            : DateTime.parse(j['identityVerifiedAt']),
        synthetic: j['synthetic'] ?? true,
      );
}

enum EncounterStatus { active, handedOff, closed }

class Encounter {
  Encounter({
    required this.id,
    required this.patientId,
    required this.start,
    required this.location,
    required this.responsibleClinicianId,
    this.status = EncounterStatus.active,
    this.consentRef,
  });

  final String id;
  final String patientId;
  final DateTime start;
  String location;
  String responsibleClinicianId;
  EncounterStatus status;

  /// Reference to the consent record covering data capture in this encounter.
  String? consentRef;

  Map<String, dynamic> toJson() => {
        'id': id,
        'patientId': patientId,
        'start': start.toIso8601String(),
        'location': location,
        'responsibleClinicianId': responsibleClinicianId,
        'status': status.name,
        'consentRef': consentRef,
      };

  factory Encounter.fromJson(Map<String, dynamic> j) => Encounter(
        id: j['id'],
        patientId: j['patientId'],
        start: DateTime.parse(j['start']),
        location: j['location'],
        responsibleClinicianId: j['responsibleClinicianId'],
        status: _enum(EncounterStatus.values, j['status']),
        consentRef: j['consentRef'],
      );
}

/// One immutable version of a clinical item in the Clinical Truth Ledger.
class LedgerEntry {
  LedgerEntry({
    required this.entryId,
    required this.itemId,
    required this.version,
    required this.encounterId,
    required this.category,
    required this.label,
    required this.value,
    required this.provenance,
    required this.originProvenance,
    required this.authorId,
    required this.authorRole,
    required this.source,
    required this.timestamp,
    required this.verification,
    this.verifiedBy,
    this.consentRef,
    this.changeReason,
    this.language,
    this.originalText,
    this.confidence,
    required this.prevHash,
    String? hash,
  }) : hash = hash ?? '';

  final String entryId;
  final String itemId;
  final int version;
  final String encounterId;
  final ItemCategory category;
  final String label;
  final String value;
  final Provenance provenance;

  /// Provenance of the very first version; kept after clinician approval.
  final Provenance originProvenance;
  final String authorId;
  final Role authorRole;

  /// Free-text origin, e.g. "Patient interview via interpreter", "Imported from referral letter".
  final String source;
  final DateTime timestamp;
  final Verification verification;
  final String? verifiedBy;
  final String? consentRef;
  final String? changeReason;
  final String? language;
  final String? originalText;
  final double? confidence;
  final String prevHash;
  String hash;

  Map<String, dynamic> _body() => {
        'entryId': entryId,
        'itemId': itemId,
        'version': version,
        'encounterId': encounterId,
        'category': category.name,
        'label': label,
        'value': value,
        'provenance': provenance.name,
        'originProvenance': originProvenance.name,
        'authorId': authorId,
        'authorRole': authorRole.name,
        'source': source,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'verification': verification.name,
        'verifiedBy': verifiedBy,
        'consentRef': consentRef,
        'changeReason': changeReason,
        'language': language,
        'originalText': originalText,
        'confidence': confidence,
        'prevHash': prevHash,
      };

  String computeHash() => canonicalHash(_body());

  Map<String, dynamic> toJson() => {..._body(), 'hash': hash};

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
        entryId: j['entryId'],
        itemId: j['itemId'],
        version: j['version'],
        encounterId: j['encounterId'],
        category: _enum(ItemCategory.values, j['category']),
        label: j['label'],
        value: j['value'],
        provenance: _enum(Provenance.values, j['provenance']),
        originProvenance: _enum(Provenance.values, j['originProvenance']),
        authorId: j['authorId'],
        authorRole: _enum(Role.values, j['authorRole']),
        source: j['source'],
        timestamp: DateTime.parse(j['timestamp']),
        verification: _enum(Verification.values, j['verification']),
        verifiedBy: j['verifiedBy'],
        consentRef: j['consentRef'],
        changeReason: j['changeReason'],
        language: j['language'],
        originalText: j['originalText'],
        confidence: (j['confidence'] as num?)?.toDouble(),
        prevHash: j['prevHash'],
        hash: j['hash'],
      );

  bool get isActive => verification != Verification.retracted;

  /// True while machine-produced content has not been approved by a clinician.
  bool get pendingReview => provenance.requiresReview;
}

enum TaskKind { task, pendingInvestigation, followUp }

enum TaskStatus { open, done, cancelled }

class ClinicalTask {
  ClinicalTask({
    required this.id,
    required this.encounterId,
    required this.title,
    required this.kind,
    required this.ownerId,
    required this.created,
    this.due,
    this.status = TaskStatus.open,
    this.completedBy,
    this.completedAt,
  });

  final String id;
  final String encounterId;
  final String title;
  final TaskKind kind;
  String ownerId;
  final DateTime created;
  DateTime? due;
  TaskStatus status;
  String? completedBy;
  DateTime? completedAt;

  bool get isOpen => status == TaskStatus.open;

  Map<String, dynamic> toJson() => {
        'id': id,
        'encounterId': encounterId,
        'title': title,
        'kind': kind.name,
        'ownerId': ownerId,
        'created': created.toIso8601String(),
        'due': due?.toIso8601String(),
        'status': status.name,
        'completedBy': completedBy,
        'completedAt': completedAt?.toIso8601String(),
      };

  factory ClinicalTask.fromJson(Map<String, dynamic> j) => ClinicalTask(
        id: j['id'],
        encounterId: j['encounterId'],
        title: j['title'],
        kind: _enum(TaskKind.values, j['kind']),
        ownerId: j['ownerId'],
        created: DateTime.parse(j['created']),
        due: j['due'] == null ? null : DateTime.parse(j['due']),
        status: _enum(TaskStatus.values, j['status']),
        completedBy: j['completedBy'],
        completedAt:
            j['completedAt'] == null ? null : DateTime.parse(j['completedAt']),
      );
}

enum HandoffFormat {
  sbar('SBAR', ['Situation', 'Background', 'Assessment', 'Recommendation']),
  ipass('I-PASS', [
    'Illness severity',
    'Patient summary',
    'Action list',
    'Situation awareness & contingency',
    'Synthesis by receiver',
  ]);

  const HandoffFormat(this.label, this.sections);
  final String label;
  final List<String> sections;
}

enum HandoffStatus {
  draft('Draft'),
  senderApproved('Sent — awaiting acceptance'),
  accepted('Accepted — responsibility transferred'),
  rejected('Returned to sender');

  const HandoffStatus(this.label);
  final String label;
}

class HandoffEvent {
  HandoffEvent(this.at, this.actorId, this.action, [this.detail]);
  final DateTime at;
  final String actorId;
  final String action;
  final String? detail;

  Map<String, dynamic> toJson() =>
      {'at': at.toIso8601String(), 'actorId': actorId, 'action': action, 'detail': detail};
  factory HandoffEvent.fromJson(Map<String, dynamic> j) =>
      HandoffEvent(DateTime.parse(j['at']), j['actorId'], j['action'], j['detail']);
}

class Handoff {
  Handoff({
    required this.id,
    required this.encounterId,
    required this.format,
    required this.fromId,
    required this.toId,
    required this.sections,
    required this.created,
    this.machineDrafted = false,
    this.reviewedSections = const {},
    this.medsAllergiesVerified = false,
    this.status = HandoffStatus.draft,
    List<HandoffEvent>? events,
  }) : events = events ?? [];

  final String id;
  final String encounterId;
  final HandoffFormat format;
  final String fromId;
  String toId;
  final Map<String, String> sections;
  final DateTime created;

  /// Sections pre-filled by the drafting engine stay labelled until reviewed.
  bool machineDrafted;
  Set<String> reviewedSections;
  bool medsAllergiesVerified;
  HandoffStatus status;
  final List<HandoffEvent> events;

  Map<String, dynamic> toJson() => {
        'id': id,
        'encounterId': encounterId,
        'format': format.name,
        'fromId': fromId,
        'toId': toId,
        'sections': sections,
        'created': created.toIso8601String(),
        'machineDrafted': machineDrafted,
        'reviewedSections': reviewedSections.toList(),
        'medsAllergiesVerified': medsAllergiesVerified,
        'status': status.name,
        'events': events.map((e) => e.toJson()).toList(),
      };

  factory Handoff.fromJson(Map<String, dynamic> j) => Handoff(
        id: j['id'],
        encounterId: j['encounterId'],
        format: _enum(HandoffFormat.values, j['format']),
        fromId: j['fromId'],
        toId: j['toId'],
        sections: Map<String, String>.from(j['sections']),
        created: DateTime.parse(j['created']),
        machineDrafted: j['machineDrafted'] ?? false,
        reviewedSections: Set<String>.from(j['reviewedSections'] ?? const []),
        medsAllergiesVerified: j['medsAllergiesVerified'] ?? false,
        status: _enum(HandoffStatus.values, j['status']),
        events: (j['events'] as List? ?? const [])
            .map((e) => HandoffEvent.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// Tamper-evident audit record; each event hashes the previous one.
class AuditEvent {
  AuditEvent({
    required this.at,
    required this.actorId,
    required this.role,
    required this.action,
    required this.target,
    this.detail,
    required this.prevHash,
    String? hash,
  }) : hash = hash ?? '';

  final DateTime at;
  final String actorId;
  final Role role;
  final String action;
  final String target;
  final String? detail;
  final String prevHash;
  String hash;

  Map<String, dynamic> _body() => {
        'at': at.toUtc().toIso8601String(),
        'actorId': actorId,
        'role': role.name,
        'action': action,
        'target': target,
        'detail': detail,
        'prevHash': prevHash,
      };

  String computeHash() => canonicalHash(_body());
  Map<String, dynamic> toJson() => {..._body(), 'hash': hash};

  factory AuditEvent.fromJson(Map<String, dynamic> j) => AuditEvent(
        at: DateTime.parse(j['at']),
        actorId: j['actorId'],
        role: _enum(Role.values, j['role']),
        action: j['action'],
        target: j['target'],
        detail: j['detail'],
        prevHash: j['prevHash'],
        hash: j['hash'],
      );
}
