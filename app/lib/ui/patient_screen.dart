import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/models.dart';
import '../core/rbac.dart';
import '../core/workflow_intel.dart';
import 'common.dart';
import 'handoff_screen.dart';
import 'interpreter_screen.dart';

class PatientScreen extends StatelessWidget {
  const PatientScreen({super.key, required this.encounterId});
  final String encounterId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        if (!s.encounters.any((e) => e.id == encounterId)) return const Scaffold();
        final e = s.encounter(encounterId);
        final p = s.patient(e.patientId);
        final alerts = s.alerts(encounterId);
        return DefaultTabController(
          length: 5,
          child: Scaffold(
            appBar: AppBar(
              title: Text(p.fullName),
              actions: [
                IconButton(
                  tooltip: 'Interpreter',
                  icon: const Icon(Icons.translate),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InterpreterScreen(encounterId: encounterId))),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => _menu(context, v),
                  itemBuilder: (_) => [
                    if (s.can(Permission.verifyIdentity)) const PopupMenuItem(value: 'id', child: Text('Verify identity (2 identifiers)')),
                    if (s.can(Permission.addEntry)) const PopupMenuItem(value: 'consent', child: Text('Record consent / authorization')),
                    if (s.can(Permission.exportData)) const PopupMenuItem(value: 'fhir', child: Text('Export HL7 FHIR R4 bundle')),
                    if (s.can(Permission.verifyEntry)) const PopupMenuItem(value: 'close', child: Text('Close encounter')),
                  ],
                ),
              ],
              bottom: TabBar(
                isScrollable: true,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: brandTeal,
                tabs: [
                  const Tab(text: 'Record'),
                  Tab(text: 'Alerts (${alerts.length})'),
                  Tab(text: 'Tasks (${s.tasksFor(encounterId).where((t) => t.isOpen).length})'),
                  const Tab(text: 'Timeline'),
                  const Tab(text: 'Handoff'),
                ],
              ),
            ),
            body: Column(children: [
              _Header(patient: p, encounter: e),
              Expanded(
                child: TabBarView(children: [
                  _RecordTab(encounterId: encounterId),
                  _AlertsTab(alerts: alerts),
                  _TasksTab(encounterId: encounterId),
                  _TimelineTab(encounterId: encounterId),
                  HandoffList(encounterId: encounterId),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _menu(BuildContext context, String v) async {
    final s = Services.of(context).state;
    final e = s.encounter(encounterId);
    final p = s.patient(e.patientId);
    switch (v) {
      case 'id':
        final name = await promptText(context, 'Ask the patient to state full name', hint: 'As stated / wristband');
        if (name == null || !context.mounted) return;
        final dob = await showDatePicker(
            context: context, firstDate: DateTime(1900), lastDate: DateTime.now(), initialDate: DateTime(1980), helpText: 'DATE OF BIRTH AS STATED');
        if (dob == null || !context.mounted) return;
        final ok = await s.verifyIdentity(p, statedName: name, statedDob: dob);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
            content: Text(ok ? 'Identity verified with two identifiers.' : 'MISMATCH — stop and re-check identity before any care.'),
          ));
        }
      case 'consent':
        final ref = await promptText(context, 'Consent / authorization reference', hint: 'e.g. verbal consent via interpreter, form #');
        if (ref != null && ref.isNotEmpty && context.mounted) await guarded(context, () => s.recordConsent(e, ref));
      case 'fhir':
        await guarded(context, () async {
          final b = s.exportFhir(encounterId);
          await SharePlus.instance.share(ShareParams(
            text: const JsonEncoder.withIndent('  ').convert(b),
            subject: 'FHIR R4 Bundle — ${p.mrn}',
          ));
        });
      case 'close':
        await guarded(context, () => s.closeEncounter(e), success: 'Encounter closed.');
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.patient, required this.encounter});
  final Patient patient;
  final Encounter encounter;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final p = patient;
    return Container(
      width: double.infinity,
      color: brandNavy.withValues(alpha: 0.06),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${p.ageOn(DateTime.now())}y ${p.sex} · DOB ${fmtDate(p.birthDate)} · MRN ${p.mrn} · ${encounter.location}'),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (p.synthetic) const SyntheticBadge(),
          p.identityVerified
              ? Pill('ID verified · ${s.clinician(p.identityVerifiedBy!)?.name ?? ''}', color: Colors.green.shade700, icon: Icons.badge)
              : const Pill('ID NOT VERIFIED', color: Colors.red, icon: Icons.badge_outlined),
          Pill('${languageName(p.preferredLanguage)}${p.interpreterNeeded ? ' · interpreter' : ''}', color: Colors.indigo, icon: Icons.translate),
          Pill(encounter.consentRef == null ? 'No consent recorded' : 'Consent on file',
              color: encounter.consentRef == null ? Colors.orange.shade800 : Colors.green.shade700, icon: Icons.assignment_turned_in_outlined),
          Pill('Responsible: ${s.clinician(encounter.responsibleClinicianId)?.name ?? '—'}', color: Colors.blueGrey, icon: Icons.person),
        ]),
      ]),
    );
  }
}

class _RecordTab extends StatelessWidget {
  const _RecordTab({required this.encounterId});
  final String encounterId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final items = s.items(encounterId);
    final pending = items.where((i) => i.pendingReview).length;
    return Scaffold(
      floatingActionButton: s.can(Permission.addEntry)
          ? FloatingActionButton(onPressed: () => _add(context), tooltip: 'Add information', child: const Icon(Icons.add))
          : null,
      body: ListView(padding: const EdgeInsets.only(bottom: 90, top: 6), children: [
        if (pending > 0)
          Card(
            color: Colors.purple.shade50,
            child: ListTile(
              leading: const Icon(Icons.auto_awesome, color: Colors.purple),
              title: Text('$pending item(s) are machine-generated or translated'),
              subtitle: const Text('They stay labelled and unconfirmed until a clinician approves them.'),
            ),
          ),
        for (final c in ItemCategory.values)
          if (items.any((i) => i.category == c)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text(c.label.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54, letterSpacing: 0.8)),
            ),
            for (final i in items.where((i) => i.category == c)) ItemCard(entry: i),
          ],
        if (items.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Nothing recorded yet. Tap + to add.')),
      ]),
    );
  }

  Future<void> _add(BuildContext context) async {
    final s = Services.of(context).state;
    var cat = ItemCategory.allergy;
    var prov = s.user.role == Role.interpreter ? Provenance.patientReported : Provenance.clinicianObserved;
    final value = TextEditingController();
    final source = TextEditingController(text: 'Bedside');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Add clinical information'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<ItemCategory>(
                initialValue: cat,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [for (final c in ItemCategory.values) DropdownMenuItem(value: c, child: Text(c.label))],
                onChanged: (v) => set(() => cat = v ?? cat),
              ),
              const SizedBox(height: 8),
              TextField(controller: value, maxLines: 3, minLines: 1, decoration: const InputDecoration(labelText: 'Value')),
              const SizedBox(height: 8),
              DropdownButtonFormField<Provenance>(
                initialValue: prov,
                decoration: const InputDecoration(labelText: 'Where does this come from?'),
                items: [
                  for (final p in [Provenance.patientReported, Provenance.clinicianObserved, Provenance.imported])
                    if (p != Provenance.clinicianObserved || s.can(Permission.verifyEntry)) DropdownMenuItem(value: p, child: Text(p.label)),
                ],
                onChanged: (v) => set(() => prov = v ?? prov),
              ),
              const SizedBox(height: 8),
              TextField(controller: source, decoration: const InputDecoration(labelText: 'Source detail (who / what document)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Record')),
          ],
        ),
      ),
    );
    if (ok == true && value.text.trim().isNotEmpty && context.mounted) {
      await guarded(context, () async {
        await s.record(encounterId: encounterId, category: cat, label: cat.label, value: value.text.trim(), provenance: prov, source: source.text.trim());
      });
    }
  }
}

class ItemCard extends StatelessWidget {
  const ItemCard({super.key, required this.entry});
  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final verColor = switch (e.verification) {
      Verification.verified => Colors.green.shade700,
      Verification.unverified => Colors.orange.shade800,
      Verification.disputed => Colors.red.shade700,
      Verification.retracted => Colors.grey,
    };
    return Card(
      shape: e.pendingReview
          ? RoundedRectangleBorder(side: BorderSide(color: provenanceColor(e.provenance), width: 1.5), borderRadius: BorderRadius.circular(12))
          : null,
      child: InkWell(
        onTap: () => showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => ItemSheet(itemId: e.itemId)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.value, style: const TextStyle(fontSize: 15.5)),
            if (e.originalText != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Original (${languageName(e.language ?? '')}): ${e.originalText}',
                    style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.black54)),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              Pill(e.provenance.label, color: provenanceColor(e.provenance), icon: provenanceIcon(e.provenance)),
              if (e.originProvenance != e.provenance) Pill('from ${e.originProvenance.label}', color: Colors.black45),
              Pill(e.verification.label, color: verColor),
              if (e.pendingReview) const Pill('NEEDS CLINICIAN REVIEW', color: Colors.purple, icon: Icons.rate_review),
              if (e.version > 1) Pill('v${e.version}', color: Colors.blueGrey, icon: Icons.history),
            ]),
          ]),
        ),
      ),
    );
  }
}

class ItemSheet extends StatelessWidget {
  const ItemSheet({super.key, required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final hist = s.ledger.history(itemId);
        final cur = hist.last;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          builder: (context, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
            Text(cur.category.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            ItemCard(entry: cur),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (cur.pendingReview && s.can(Permission.approveMachineContent)) ...[
                FilledButton.icon(
                  icon: const Icon(Icons.verified),
                  label: const Text('Approve as is'),
                  onPressed: () => guarded(context, () => s.approve(itemId), success: 'Approved — provenance kept.'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Edit & approve'),
                  onPressed: () async {
                    final v = await promptText(context, 'Edit before approval', initial: cur.value, lines: 4);
                    if (v != null && v.isNotEmpty && context.mounted) await guarded(context, () => s.approve(itemId, editedValue: v));
                  },
                ),
              ],
              if (!cur.pendingReview && cur.verification != Verification.verified && s.can(Permission.verifyEntry))
                FilledButton.icon(
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Verify'),
                  onPressed: () => guarded(context, () => s.verify(itemId), success: 'Verified.'),
                ),
              if (s.can(Permission.addEntry))
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Amend'),
                  onPressed: () async {
                    final v = await promptText(context, 'New value', initial: cur.value, lines: 3);
                    if (v == null || v.isEmpty || !context.mounted) return;
                    final r = await promptText(context, 'Reason for change (required)');
                    if (r != null && context.mounted) await guarded(context, () => s.amend(itemId, v, r));
                  },
                ),
              if (s.can(Permission.addEntry))
                OutlinedButton.icon(
                  icon: const Icon(Icons.report_gmailerrorred),
                  label: const Text('Dispute'),
                  onPressed: () async {
                    final r = await promptText(context, 'Why is this disputed?');
                    if (r != null && r.isNotEmpty && context.mounted) await guarded(context, () => s.dispute(itemId, r));
                  },
                ),
              if (s.can(Permission.verifyEntry))
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text('Entered in error', style: TextStyle(color: Colors.red)),
                  onPressed: () async {
                    final r = await promptText(context, 'Reason (kept in history)');
                    if (r != null && context.mounted) {
                      await guarded(context, () => s.retract(itemId, r));
                      if (context.mounted) Navigator.pop(context);
                    }
                  },
                ),
            ]),
            const Divider(height: 28),
            Text('Provenance & modification history', style: Theme.of(context).textTheme.titleMedium),
            for (final h in hist.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(radius: 14, child: Text('${h.version}', style: const TextStyle(fontSize: 12))),
                title: Text(h.value),
                subtitle: Text([
                  '${h.provenance.label} · ${h.verification.label}',
                  'By ${s.clinician(h.authorId)?.name ?? h.authorId} (${h.authorRole.label}) · ${fmtTime(h.timestamp)}',
                  'Source: ${h.source}',
                  if (h.changeReason != null) 'Reason: ${h.changeReason}',
                  if (h.consentRef != null) 'Consent: ${h.consentRef}',
                  if (h.confidence != null) 'Translation agreement: ${(h.confidence! * 100).round()}%',
                  'Hash ${h.hash.substring(0, 12)}…',
                ].join('\n')),
                isThreeLine: true,
              ),
          ]),
        );
      },
    );
  }
}

class _AlertsTab extends StatelessWidget {
  const _AlertsTab({required this.alerts});
  final List<WorkflowAlert> alerts;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Text('Documentation and safety prompts. They are not diagnoses or orders.', style: TextStyle(color: Colors.black54)),
        ),
        if (alerts.isEmpty) const ListTile(leading: Icon(Icons.check_circle, color: Colors.green), title: Text('No open alerts')),
        for (final a in alerts)
          Card(
            child: ListTile(
              leading: Icon(severityIcon(a.severity), color: severityColor(a.severity)),
              title: Text(a.message),
              subtitle: Text(a.code, style: const TextStyle(fontSize: 11)),
              onTap: a.itemIds.isEmpty
                  ? null
                  : () => showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => ItemSheet(itemId: a.itemIds.first)),
            ),
          ),
      ]);
}

class _TasksTab extends StatelessWidget {
  const _TasksTab({required this.encounterId});
  final String encounterId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final tasks = s.tasksFor(encounterId)..sort((a, b) => a.status.index.compareTo(b.status.index));
    final now = DateTime.now();
    return Scaffold(
      floatingActionButton: s.can(Permission.manageTasks)
          ? FloatingActionButton(
              tooltip: 'Add task',
              child: const Icon(Icons.add_task),
              onPressed: () async {
                final t = await promptText(context, 'Outstanding responsibility', hint: 'e.g. Chase CT result');
                if (t == null || t.isEmpty || !context.mounted) return;
                final pending = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Is this a pending investigation result?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No, a task')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
                    ],
                  ),
                );
                if (context.mounted) {
                  await guarded(context, () => s.addTask(encounterId, t, pending == true ? TaskKind.pendingInvestigation : TaskKind.task,
                      due: DateTime.now().add(const Duration(hours: 1))));
                }
              },
            )
          : null,
      body: ListView(padding: const EdgeInsets.only(bottom: 90, top: 6), children: [
        if (tasks.isEmpty) const ListTile(title: Text('No tasks.')),
        for (final t in tasks)
          Card(
            child: CheckboxListTile(
              value: !t.isOpen,
              onChanged: t.isOpen && s.can(Permission.manageTasks) ? (_) => guarded(context, () => s.completeTask(t)) : null,
              title: Text(t.title, style: TextStyle(decoration: t.isOpen ? null : TextDecoration.lineThrough)),
              subtitle: Text([
                switch (t.kind) { TaskKind.pendingInvestigation => 'Pending result', TaskKind.followUp => 'Follow-up', TaskKind.task => 'Task' },
                'Owner ${s.clinician(t.ownerId)?.name ?? t.ownerId}',
                if (t.due != null) '${t.isOpen && t.due!.isBefore(now) ? 'OVERDUE · ' : ''}due ${fmtTime(t.due!)}',
              ].join(' · ')),
            ),
          ),
      ]),
    );
  }
}

class _TimelineTab extends StatelessWidget {
  const _TimelineTab({required this.encounterId});
  final String encounterId;

  @override
  Widget build(BuildContext context) {
    final t = Services.of(context).state.timeline(encounterId);
    return ListView.separated(
      itemCount: t.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => ListTile(
        dense: true,
        leading: Text(fmtTime(t[i].$1).substring(11), style: const TextStyle(fontWeight: FontWeight.bold)),
        title: Text(t[i].$2),
        subtitle: Text(t[i].$3),
      ),
    );
  }
}
