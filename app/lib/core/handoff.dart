import 'package:uuid/uuid.dart';

import 'models.dart';
import 'rbac.dart';
import 'workflow_intel.dart';

class HandoffException implements Exception {
  HandoffException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Handoff lifecycle: draft → sender approved → accepted (or returned).
/// Responsibility only transfers on explicit receiver acceptance.
class HandoffService {
  static const _uuid = Uuid();

  static Handoff draft({
    required HandoffFormat format,
    required Patient patient,
    required Encounter encounter,
    required List<LedgerEntry> items,
    required List<ClinicalTask> tasks,
    required List<WorkflowAlert> alerts,
    required Clinician from,
    required String toId,
    DateTime? now,
  }) {
    Rbac.require(from.role, Permission.createHandoff);
    final when = now ?? DateTime.now();
    String list(ItemCategory c) {
      final v = items.where((e) => e.category == c).map((e) {
        final tag = e.verification == Verification.verified ? '' : ' [${e.provenance.label}, ${e.verification.label.toLowerCase()}]';
        return '${e.value}$tag';
      }).toList();
      return v.isEmpty ? 'NOT DOCUMENTED' : v.join('; ');
    }

    final open = tasks.where((t) => t.isOpen).toList();
    final actions = open.isEmpty
        ? 'No outstanding tasks.'
        : open.map((t) => '• ${t.title}${t.due == null ? '' : ' (due ${t.due!.toLocal().toString().substring(0, 16)})'}').join('\n');
    final critical = alerts.where((a) => a.severity == AlertSeverity.critical).map((a) => '• ${a.message}').join('\n');
    final demo = '${patient.fullName}, ${patient.ageOn(when)}y ${patient.sex}, MRN ${patient.mrn}, ${encounter.location}';
    final lang = patient.interpreterNeeded ? ' Interpreter needed (${patient.preferredLanguage}).' : '';

    final sections = <String, String>{};
    if (format == HandoffFormat.sbar) {
      sections['Situation'] = '$demo.$lang\nPresenting: ${list(ItemCategory.complaint)}';
      sections['Background'] =
          'History: ${list(ItemCategory.history)}\nAllergies: ${list(ItemCategory.allergy)}\nMedications: ${list(ItemCategory.medication)}\nWeight: ${list(ItemCategory.weight)}\nCode status: ${list(ItemCategory.codeStatus)}\nIsolation: ${list(ItemCategory.isolation)}';
      sections['Assessment'] =
          'Working problems: ${list(ItemCategory.problem)}\nVitals: ${list(ItemCategory.vital)}${critical.isEmpty ? '' : '\nOpen safety alerts:\n$critical'}';
      sections['Recommendation'] = '$actions\n[Sender: add contingency plan]';
    } else {
      sections['Illness severity'] = '[Sender: stable / watcher / unstable]';
      sections['Patient summary'] =
          '$demo.$lang\nPresenting: ${list(ItemCategory.complaint)}\nProblems: ${list(ItemCategory.problem)}\nAllergies: ${list(ItemCategory.allergy)}\nMedications: ${list(ItemCategory.medication)}\nCode status: ${list(ItemCategory.codeStatus)}';
      sections['Action list'] = actions;
      sections['Situation awareness & contingency'] =
          '${critical.isEmpty ? '' : 'Open safety alerts:\n$critical\n'}[Sender: if/then contingency plans]';
      sections['Synthesis by receiver'] = '';
    }

    return Handoff(
      id: _uuid.v4(),
      encounterId: encounter.id,
      format: format,
      fromId: from.id,
      toId: toId,
      sections: sections,
      created: when,
      machineDrafted: true,
      reviewedSections: {},
      events: [HandoffEvent(when, from.id, 'drafted', 'Machine-generated draft from the ledger')],
    );
  }

  static List<String> senderSections(Handoff h) =>
      h.format.sections.where((s) => s != 'Synthesis by receiver').toList();

  static void markReviewed(Handoff h, String section, Clinician actor, {String? text}) {
    if (actor.id != h.fromId) throw HandoffException('Only the sending clinician edits the handoff.');
    if (h.status != HandoffStatus.draft) throw HandoffException('Handoff already sent.');
    if (text != null) h.sections[section] = text;
    h.reviewedSections = {...h.reviewedSections, section};
    h.events.add(HandoffEvent(DateTime.now(), actor.id, 'reviewed', section));
    if (senderSections(h).every(h.reviewedSections.contains)) h.machineDrafted = false;
  }

  static void verifyMedsAllergies(Handoff h, Clinician actor) {
    if (actor.id != h.fromId) throw HandoffException('Only the sending clinician can confirm this.');
    h.medsAllergiesVerified = true;
    h.events.add(HandoffEvent(DateTime.now(), actor.id, 'meds-allergies-verified'));
  }

  static List<String> sendBlockers(Handoff h) {
    final out = <String>[];
    if (h.toId.isEmpty) out.add('Choose a receiving clinician.');
    if (h.toId == h.fromId) out.add('Receiver must be a different clinician.');
    for (final s in senderSections(h)) {
      if (!h.reviewedSections.contains(s)) out.add('Review section "$s".');
      if ((h.sections[s] ?? '').contains('[Sender:')) out.add('Complete placeholder in "$s".');
    }
    if (!h.medsAllergiesVerified) out.add('Confirm medications and allergies.');
    return out;
  }

  static void send(Handoff h, Clinician actor) {
    Rbac.require(actor.role, Permission.createHandoff);
    if (actor.id != h.fromId) throw HandoffException('Only the sending clinician can approve.');
    if (h.status != HandoffStatus.draft && h.status != HandoffStatus.rejected) {
      throw HandoffException('Handoff is ${h.status.label}.');
    }
    final b = sendBlockers(h);
    if (b.isNotEmpty) throw HandoffException(b.join('\n'));
    h.status = HandoffStatus.senderApproved;
    h.events.add(HandoffEvent(DateTime.now(), actor.id, 'sender-approved'));
  }

  static void accept(Handoff h, Clinician actor, Encounter encounter, {String? synthesis}) {
    Rbac.require(actor.role, Permission.acceptHandoff);
    if (actor.id != h.toId) throw HandoffException('Only the named receiver can accept.');
    if (h.status != HandoffStatus.senderApproved) throw HandoffException('Handoff is not awaiting acceptance.');
    if (h.format == HandoffFormat.ipass) {
      final s = (synthesis ?? h.sections['Synthesis by receiver'] ?? '').trim();
      if (s.length < 10) throw HandoffException('I-PASS requires the receiver to summarise (synthesis).');
      h.sections['Synthesis by receiver'] = s;
    }
    h.status = HandoffStatus.accepted;
    encounter.responsibleClinicianId = actor.id;
    h.events.add(HandoffEvent(DateTime.now(), actor.id, 'accepted', 'Clinical responsibility transferred'));
  }

  static void reject(Handoff h, Clinician actor, String reason) {
    if (actor.id != h.toId) throw HandoffException('Only the named receiver can return a handoff.');
    if (h.status != HandoffStatus.senderApproved) throw HandoffException('Handoff is not awaiting acceptance.');
    if (reason.trim().isEmpty) throw HandoffException('Give a reason.');
    h.status = HandoffStatus.rejected;
    h.events.add(HandoffEvent(DateTime.now(), actor.id, 'returned', reason));
  }
}
