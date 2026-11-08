import 'models.dart';

/// Country / jurisdiction interoperability profile applied on export.
enum FhirProfile {
  baseR4('HL7 FHIR R4 (base)', null, null),
  ips('International Patient Summary', 'http://hl7.org/fhir/uv/ips/StructureDefinition/Patient-uv-ips',
      'http://hl7.org/fhir/uv/ips/StructureDefinition/AllergyIntolerance-uv-ips'),
  usCore('US Core', 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient',
      'http://hl7.org/fhir/us/core/StructureDefinition/us-core-allergyintolerance'),
  ukCore('UK Core', 'https://fhir.hl7.org.uk/StructureDefinition/UKCore-Patient',
      'https://fhir.hl7.org.uk/StructureDefinition/UKCore-AllergyIntolerance');

  const FhirProfile(this.label, this.patientProfile, this.allergyProfile);
  final String label;
  final String? patientProfile;
  final String? allergyProfile;
}

/// Builds an R4 collection Bundle. Every resource carries an origin tag and a
/// Provenance resource so receiving systems can tell patient-reported,
/// translated and AI-generated content from clinician-confirmed data.
class FhirExporter {
  static const originSystem = 'https://clinicbridge.app/fhir/CodeSystem/information-origin';

  static Map<String, dynamic> bundle({
    required Patient patient,
    required Encounter encounter,
    required List<LedgerEntry> items,
    required List<ClinicalTask> tasks,
    required List<Handoff> handoffs,
    required Map<String, Clinician> clinicians,
    FhirProfile profile = FhirProfile.baseR4,
    DateTime? now,
  }) {
    final entries = <Map<String, dynamic>>[];
    void add(Map<String, dynamic> r) =>
        entries.add({'fullUrl': 'urn:uuid:${r['id']}', 'resource': r});
    final patRef = 'urn:uuid:${patient.id}';
    final encRef = 'urn:uuid:${encounter.id}';

    add({
      'resourceType': 'Patient',
      'id': patient.id,
      if (profile.patientProfile != null) 'meta': {'profile': [profile.patientProfile]},
      'identifier': [
        {'system': 'urn:clinicbridge:mrn', 'value': patient.mrn}
      ],
      'name': [
        {'family': patient.familyName, 'given': [patient.givenName]}
      ],
      'gender': patient.sex,
      'birthDate': patient.birthDate.toIso8601String().substring(0, 10),
      'communication': [
        {
          'language': {
            'coding': [
              {'system': 'urn:ietf:bcp:47', 'code': patient.preferredLanguage}
            ]
          },
          'preferred': true
        }
      ],
      if (patient.synthetic)
        'extension': [
          {'url': 'https://clinicbridge.app/fhir/StructureDefinition/synthetic-data', 'valueBoolean': true}
        ],
    });

    add({
      'resourceType': 'Encounter',
      'id': encounter.id,
      'status': encounter.status == EncounterStatus.closed ? 'finished' : 'in-progress',
      'class': {'system': 'http://terminology.hl7.org/CodeSystem/v3-ActCode', 'code': 'AMB'},
      'subject': {'reference': patRef},
      'period': {'start': encounter.start.toUtc().toIso8601String()},
      'location': [
        {'location': {'display': encounter.location}}
      ],
      'participant': [
        {'individual': {'display': clinicians[encounter.responsibleClinicianId]?.name ?? encounter.responsibleClinicianId}}
      ],
    });

    for (final e in items) {
      final r = _resourceFor(e, patRef, encRef, profile);
      add(r);
      add({
        'resourceType': 'Provenance',
        'id': 'prov-${e.entryId}',
        'target': [
          {'reference': 'urn:uuid:${r['id']}'}
        ],
        'recorded': e.timestamp.toUtc().toIso8601String(),
        'agent': [
          {
            'type': {
              'coding': [
                {'system': 'http://terminology.hl7.org/CodeSystem/provenance-participant-type', 'code': 'author'}
              ]
            },
            'who': {'display': '${clinicians[e.authorId]?.name ?? e.authorId} (${e.authorRole.label})'}
          },
          if (e.verifiedBy != null)
            {
              'type': {
                'coding': [
                  {'system': 'http://terminology.hl7.org/CodeSystem/provenance-participant-type', 'code': 'verifier'}
                ]
              },
              'who': {'display': clinicians[e.verifiedBy]?.name ?? e.verifiedBy}
            },
        ],
        'entity': [
          {'role': 'source', 'what': {'display': e.source}}
        ],
        if (e.changeReason != null) 'reason': [{'text': e.changeReason}],
        'signature': [],
        'extension': [
          {'url': 'https://clinicbridge.app/fhir/StructureDefinition/ledger-hash', 'valueString': e.hash},
          {'url': 'https://clinicbridge.app/fhir/StructureDefinition/ledger-version', 'valueInteger': e.version},
        ],
      }..remove('signature'));
    }

    for (final t in tasks) {
      add({
        'resourceType': 'Task',
        'id': t.id,
        'status': switch (t.status) { TaskStatus.open => 'requested', TaskStatus.done => 'completed', TaskStatus.cancelled => 'cancelled' },
        'intent': 'order',
        'description': t.title,
        'for': {'reference': patRef},
        'encounter': {'reference': encRef},
        'owner': {'display': clinicians[t.ownerId]?.name ?? t.ownerId},
        'authoredOn': t.created.toUtc().toIso8601String(),
        if (t.due != null) 'restriction': {'period': {'end': t.due!.toUtc().toIso8601String()}},
      });
    }

    for (final h in handoffs) {
      add({
        'resourceType': 'Composition',
        'id': h.id,
        'status': h.status == HandoffStatus.accepted ? 'final' : 'preliminary',
        'type': {
          'coding': [
            {'system': 'http://loinc.org', 'code': '18761-7', 'display': 'Provider-unspecified transfer summary'}
          ],
          'text': '${h.format.label} handoff'
        },
        'subject': {'reference': patRef},
        'encounter': {'reference': encRef},
        'date': h.created.toUtc().toIso8601String(),
        'author': [
          {'display': clinicians[h.fromId]?.name ?? h.fromId}
        ],
        'title': '${h.format.label} handoff → ${clinicians[h.toId]?.name ?? h.toId} (${h.status.label})',
        'section': [
          for (final s in h.format.sections)
            {
              'title': s,
              'text': {'status': 'generated', 'div': '<div xmlns="http://www.w3.org/1999/xhtml">${_esc(h.sections[s] ?? '')}</div>'}
            }
        ],
      });
    }

    return {
      'resourceType': 'Bundle',
      'id': 'export-${encounter.id}',
      'type': 'collection',
      'timestamp': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'entry': entries,
    };
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\n', '<br/>');

  static Map<String, dynamic> _origin(LedgerEntry e) => {
        'tag': [
          {'system': originSystem, 'code': e.provenance.name, 'display': e.provenance.label},
          if (e.originProvenance != e.provenance)
            {'system': originSystem, 'code': 'origin-${e.originProvenance.name}', 'display': 'Originally ${e.originProvenance.label}'},
        ]
      };

  static Map<String, dynamic> _resourceFor(LedgerEntry e, String patRef, String encRef, FhirProfile profile) {
    final id = e.itemId;
    final meta = _origin(e);
    String verif() => switch (e.verification) {
          Verification.verified => 'confirmed',
          Verification.unverified => 'unconfirmed',
          Verification.disputed => 'unconfirmed',
          Verification.retracted => 'entered-in-error',
        };
    switch (e.category) {
      case ItemCategory.allergy:
        if (profile.allergyProfile != null) meta['profile'] = [profile.allergyProfile];
        return {
          'resourceType': 'AllergyIntolerance',
          'id': id,
          'meta': meta,
          'clinicalStatus': {
            'coding': [
              {'system': 'http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical', 'code': 'active'}
            ]
          },
          'verificationStatus': {
            'coding': [
              {'system': 'http://terminology.hl7.org/CodeSystem/allergyintolerance-verification', 'code': verif()}
            ]
          },
          'code': {'text': e.value},
          'patient': {'reference': patRef},
          'encounter': {'reference': encRef},
          'recordedDate': e.timestamp.toUtc().toIso8601String(),
        };
      case ItemCategory.medication:
        return {
          'resourceType': 'MedicationStatement',
          'id': id,
          'meta': meta,
          'status': e.verification == Verification.retracted ? 'entered-in-error' : 'active',
          'medicationCodeableConcept': {'text': e.value},
          'subject': {'reference': patRef},
          'context': {'reference': encRef},
          'dateAsserted': e.timestamp.toUtc().toIso8601String(),
        };
      case ItemCategory.problem:
        return {
          'resourceType': 'Condition',
          'id': id,
          'meta': meta,
          'verificationStatus': {
            'coding': [
              {
                'system': 'http://terminology.hl7.org/CodeSystem/condition-ver-status',
                'code': e.verification == Verification.verified ? 'provisional' : (e.verification == Verification.retracted ? 'entered-in-error' : 'unconfirmed')
              }
            ]
          },
          'code': {'text': e.value},
          'subject': {'reference': patRef},
          'encounter': {'reference': encRef},
        };
      default:
        return {
          'resourceType': 'Observation',
          'id': id,
          'meta': meta,
          'status': switch (e.verification) {
            Verification.verified => 'final',
            Verification.retracted => 'entered-in-error',
            _ => 'preliminary',
          },
          'code': {'text': e.label},
          'subject': {'reference': patRef},
          'encounter': {'reference': encRef},
          'effectiveDateTime': e.timestamp.toUtc().toIso8601String(),
          'valueString': e.value,
          if (e.originalText != null)
            'note': [
              {'text': 'Original (${e.language ?? '?'}): ${e.originalText}'}
            ],
        };
    }
  }
}
