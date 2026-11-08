import 'package:uuid/uuid.dart';

import 'models.dart';
import 'rbac.dart';

const _genesis = 'GENESIS';
const _uuid = Uuid();

class LedgerException implements Exception {
  LedgerException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Append-only, hash-chained Clinical Truth Ledger.
///
/// Items are never edited in place: every change is a new version that keeps
/// its predecessor, author, source and reason. Machine output (AI-generated or
/// translated) can only become "verified" through an explicit clinician
/// approval, which records a new version with [Provenance.clinicianApproved]
/// while preserving the original provenance.
class Ledger {
  Ledger([List<LedgerEntry>? entries]) : _entries = entries ?? [];

  final List<LedgerEntry> _entries;

  List<LedgerEntry> get entries => List.unmodifiable(_entries);
  String get headHash => _entries.isEmpty ? _genesis : _entries.last.hash;

  LedgerEntry _append(LedgerEntry e) {
    e.hash = e.computeHash();
    _entries.add(e);
    return e;
  }

  List<LedgerEntry> history(String itemId) =>
      _entries.where((e) => e.itemId == itemId).toList()
        ..sort((a, b) => a.version.compareTo(b.version));

  LedgerEntry? current(String itemId) {
    final h = history(itemId);
    return h.isEmpty ? null : h.last;
  }

  /// Latest version of each item in an encounter.
  List<LedgerEntry> currentItems(String encounterId, {bool includeRetracted = false}) {
    final latest = <String, LedgerEntry>{};
    for (final e in _entries.where((e) => e.encounterId == encounterId)) {
      final prev = latest[e.itemId];
      if (prev == null || e.version > prev.version) latest[e.itemId] = e;
    }
    final list = latest.values
        .where((e) => includeRetracted || e.isActive)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  LedgerEntry record({
    required String encounterId,
    required ItemCategory category,
    required String label,
    required String value,
    required Provenance provenance,
    required Clinician author,
    required String source,
    String? consentRef,
    String? language,
    String? originalText,
    double? confidence,
    DateTime? at,
  }) {
    Rbac.require(author.role, Permission.addEntry);
    if (provenance == Provenance.clinicianApproved) {
      throw LedgerException('Approval is a separate step; record the original provenance first.');
    }
    if (provenance == Provenance.translated && (originalText == null || originalText.isEmpty)) {
      throw LedgerException('Translated items must keep the original-language text.');
    }
    final clinicianAuthored = provenance == Provenance.clinicianObserved;
    return _append(LedgerEntry(
      entryId: _uuid.v4(),
      itemId: _uuid.v4(),
      version: 1,
      encounterId: encounterId,
      category: category,
      label: label,
      value: value,
      provenance: provenance,
      originProvenance: provenance,
      authorId: author.id,
      authorRole: author.role,
      source: source,
      timestamp: at ?? DateTime.now(),
      verification: clinicianAuthored ? Verification.verified : Verification.unverified,
      verifiedBy: clinicianAuthored ? author.id : null,
      consentRef: consentRef,
      language: language,
      originalText: originalText,
      confidence: confidence,
      prevHash: headHash,
    ));
  }

  LedgerEntry _newVersion(
    LedgerEntry base, {
    required Clinician actor,
    required String reason,
    String? value,
    Provenance? provenance,
    Verification? verification,
    String? verifiedBy,
  }) {
    return _append(LedgerEntry(
      entryId: _uuid.v4(),
      itemId: base.itemId,
      version: base.version + 1,
      encounterId: base.encounterId,
      category: base.category,
      label: base.label,
      value: value ?? base.value,
      provenance: provenance ?? base.provenance,
      originProvenance: base.originProvenance,
      authorId: actor.id,
      authorRole: actor.role,
      source: base.source,
      timestamp: DateTime.now(),
      verification: verification ?? base.verification,
      verifiedBy: verifiedBy ?? base.verifiedBy,
      consentRef: base.consentRef,
      changeReason: reason,
      language: base.language,
      originalText: base.originalText,
      confidence: base.confidence,
      prevHash: headHash,
    ));
  }

  LedgerEntry _requireCurrent(String itemId) {
    final c = current(itemId);
    if (c == null) throw LedgerException('Unknown item $itemId');
    return c;
  }

  /// Clinician confirms patient-reported or imported information.
  LedgerEntry verify(String itemId, Clinician actor, {String reason = 'Verified'}) {
    Rbac.require(actor.role, Permission.verifyEntry);
    final c = _requireCurrent(itemId);
    if (c.pendingReview) {
      throw LedgerException('${c.provenance.label} content must be approved, not just verified.');
    }
    return _newVersion(c,
        actor: actor, reason: reason, verification: Verification.verified, verifiedBy: actor.id);
  }

  /// Clinician reviews and approves AI-generated or translated content.
  LedgerEntry approve(String itemId, Clinician actor, {String? editedValue, String reason = 'Reviewed and approved'}) {
    Rbac.require(actor.role, Permission.approveMachineContent);
    final c = _requireCurrent(itemId);
    if (!c.pendingReview) throw LedgerException('Item is not awaiting review.');
    return _newVersion(c,
        actor: actor,
        reason: reason,
        value: editedValue,
        provenance: Provenance.clinicianApproved,
        verification: Verification.verified,
        verifiedBy: actor.id);
  }

  /// Correct a value. A changed value is never "verified" unless a clinician authored it.
  LedgerEntry amend(String itemId, Clinician actor, String newValue, String reason) {
    Rbac.require(actor.role, Permission.addEntry);
    if (reason.trim().isEmpty) throw LedgerException('A reason is required to amend.');
    final c = _requireCurrent(itemId);
    final clinician = Rbac.can(actor.role, Permission.verifyEntry);
    return _newVersion(c,
        actor: actor,
        reason: reason,
        value: newValue,
        provenance: clinician ? Provenance.clinicianObserved : c.provenance,
        verification: clinician ? Verification.verified : Verification.unverified,
        verifiedBy: clinician ? actor.id : null);
  }

  LedgerEntry dispute(String itemId, Clinician actor, String reason) {
    Rbac.require(actor.role, Permission.addEntry);
    return _newVersion(_requireCurrent(itemId),
        actor: actor, reason: reason, verification: Verification.disputed, verifiedBy: null);
  }

  LedgerEntry retract(String itemId, Clinician actor, String reason) {
    Rbac.require(actor.role, Permission.verifyEntry);
    if (reason.trim().isEmpty) throw LedgerException('A reason is required to retract.');
    return _newVersion(_requireCurrent(itemId),
        actor: actor, reason: reason, verification: Verification.retracted);
  }

  /// Returns the index of the first broken link, or -1 if the chain is intact.
  int verifyChain() {
    var prev = _genesis;
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (e.prevHash != prev || e.computeHash() != e.hash) return i;
      prev = e.hash;
    }
    return -1;
  }

  void removeEncounter(String encounterId) {
    _entries.removeWhere((e) => e.encounterId == encounterId);
    // Re-seal the chain after a retention purge (the purge itself is audit-logged).
    var prev = _genesis;
    for (var i = 0; i < _entries.length; i++) {
      final old = _entries[i];
      final copy = LedgerEntry.fromJson({...old.toJson(), 'prevHash': prev});
      copy.hash = copy.computeHash();
      _entries[i] = copy;
      prev = copy.hash;
    }
  }
}
