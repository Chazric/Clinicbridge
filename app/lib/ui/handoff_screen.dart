import 'package:flutter/material.dart';

import '../core/handoff.dart';
import '../core/models.dart';
import '../core/rbac.dart';
import 'common.dart';

class HandoffList extends StatelessWidget {
  const HandoffList({super.key, required this.encounterId});
  final String encounterId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final list = s.handoffsFor(encounterId);
    return ListView(padding: const EdgeInsets.all(8), children: [
      if (s.can(Permission.createHandoff))
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.swap_horiz),
              label: const Text('New SBAR'),
              onPressed: () => _new(context, HandoffFormat.sbar),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.swap_horiz),
              label: const Text('New I-PASS'),
              onPressed: () => _new(context, HandoffFormat.ipass),
            ),
          ),
        ]),
      const SizedBox(height: 8),
      if (list.isEmpty) const ListTile(title: Text('No handoffs yet.')),
      for (final h in list)
        Card(
          child: ListTile(
            leading: Icon(
              h.status == HandoffStatus.accepted ? Icons.check_circle : Icons.pending_actions,
              color: h.status == HandoffStatus.accepted ? Colors.green : Colors.orange,
            ),
            title: Text('${h.format.label}: ${s.clinician(h.fromId)?.name ?? h.fromId} → ${s.clinician(h.toId)?.name ?? h.toId}'),
            subtitle: Text('${h.status.label} · ${fmtTime(h.created)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HandoffEditor(handoffId: h.id))),
          ),
        ),
    ]);
  }

  Future<void> _new(BuildContext context, HandoffFormat f) async {
    final s = Services.of(context).state;
    final receivers = s.clinicians.where((c) => c.id != s.user.id && Rbac.can(c.role, Permission.acceptHandoff)).toList();
    final to = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Hand off to'),
        children: [for (final c in receivers) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c.id), child: Text('${c.name} · ${c.role.label}'))],
      ),
    );
    if (to == null || !context.mounted) return;
    await guarded(context, () async {
      final h = await s.draftHandoff(encounterId, f, to);
      if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => HandoffEditor(handoffId: h.id)));
    });
  }
}

class HandoffEditor extends StatefulWidget {
  const HandoffEditor({super.key, required this.handoffId});
  final String handoffId;

  @override
  State<HandoffEditor> createState() => _HandoffEditorState();
}

class _HandoffEditorState extends State<HandoffEditor> {
  final _controllers = <String, TextEditingController>{};

  TextEditingController _c(Handoff h, String s) => _controllers.putIfAbsent(s, () => TextEditingController(text: h.sections[s] ?? ''));

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final h = s.handoffs.firstWhere((x) => x.id == widget.handoffId);
        final enc = s.encounter(h.encounterId);
        final p = s.patient(enc.patientId);
        final isSender = s.user.id == h.fromId;
        final isReceiver = s.user.id == h.toId;
        final editable = isSender && (h.status == HandoffStatus.draft || h.status == HandoffStatus.rejected);
        final items = s.items(h.encounterId);
        final blockers = HandoffService.sendBlockers(h);
        return Scaffold(
          appBar: AppBar(title: Text('${h.format.label} · ${p.fullName}')),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              Pill(h.status.label, color: h.status == HandoffStatus.accepted ? Colors.green.shade700 : Colors.orange.shade800),
              Pill('From ${s.clinician(h.fromId)?.name}', color: Colors.blueGrey),
              Pill('To ${s.clinician(h.toId)?.name}', color: Colors.blueGrey),
              if (p.synthetic) const SyntheticBadge(),
            ]),
            if (h.machineDrafted)
              Card(
                color: Colors.purple.shade50,
                child: const ListTile(
                  leading: Icon(Icons.auto_awesome, color: Colors.purple),
                  title: Text('Machine-drafted from the record'),
                  subtitle: Text('Every section must be reviewed by the sending clinician before it can be sent.'),
                ),
              ),
            for (final sec in h.format.sections)
              if (sec != 'Synthesis by receiver' || h.status != HandoffStatus.draft)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(sec, style: const TextStyle(fontWeight: FontWeight.bold))),
                        if (h.reviewedSections.contains(sec)) const Pill('Reviewed', color: Colors.green, icon: Icons.check),
                      ]),
                      const SizedBox(height: 6),
                      if (sec == 'Synthesis by receiver')
                        isReceiver && h.status == HandoffStatus.senderApproved
                            ? TextField(controller: _c(h, sec), maxLines: 4, minLines: 2, decoration: const InputDecoration(hintText: 'Receiver: summarise back in your own words'))
                            : Text(h.sections[sec]?.isNotEmpty == true ? h.sections[sec]! : '—')
                      else if (editable)
                        TextField(controller: _c(h, sec), maxLines: null, minLines: 2)
                      else
                        Text(h.sections[sec] ?? ''),
                      if (editable && sec != 'Synthesis by receiver')
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.check),
                            label: Text(h.reviewedSections.contains(sec) ? 'Save edits' : 'Mark reviewed'),
                            onPressed: () => guarded(context, () => s.reviewHandoffSection(h, sec, _c(h, sec).text)),
                          ),
                        ),
                    ]),
                  ),
                ),
            if (editable) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Medication & allergy verification', style: TextStyle(fontWeight: FontWeight.bold)),
                    for (final i in items.where((i) => i.category == ItemCategory.allergy || i.category == ItemCategory.medication))
                      Text('• ${i.category.label}: ${i.value}  [${i.provenance.label}, ${i.verification.label}]'),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: h.medsAllergiesVerified,
                      onChanged: h.medsAllergiesVerified ? null : (_) => guarded(context, () => s.confirmHandoffMedsAllergies(h)),
                      title: const Text('I have reviewed medications and allergies for this handoff'),
                    ),
                  ]),
                ),
              ),
              if (blockers.isNotEmpty)
                Card(
                  color: Colors.orange.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Before sending:', style: TextStyle(fontWeight: FontWeight.bold)),
                      for (final b in blockers) Text('• $b'),
                    ]),
                  ),
                ),
              FilledButton.icon(
                icon: const Icon(Icons.send),
                label: const Text('Approve & send to receiver'),
                onPressed: blockers.isEmpty ? () => guarded(context, () => s.sendHandoff(h), success: 'Sent. Responsibility stays with you until accepted.') : null,
              ),
            ],
            if (isReceiver && h.status == HandoffStatus.senderApproved) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
                icon: const Icon(Icons.how_to_reg),
                label: const Text('Accept — I take clinical responsibility'),
                onPressed: () => guarded(context, () => s.acceptHandoff(h, synthesis: _controllers['Synthesis by receiver']?.text),
                    success: 'Accepted. You are now the responsible clinician.'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Return to sender with questions'),
                onPressed: () async {
                  final r = await promptText(context, 'What is missing or unclear?', lines: 3);
                  if (r != null && context.mounted) await guarded(context, () => s.rejectHandoff(h, r));
                },
              ),
            ],
            if (!isSender && !isReceiver && h.status == HandoffStatus.senderApproved)
              const Padding(padding: EdgeInsets.all(8), child: Text('Only the named receiver can accept this handoff.')),
            const Divider(height: 28),
            const Text('Handoff audit history', style: TextStyle(fontWeight: FontWeight.bold)),
            for (final ev in h.events.reversed)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history, size: 18),
                title: Text('${ev.action}${ev.detail == null ? '' : ' — ${ev.detail}'}'),
                subtitle: Text('${s.clinician(ev.actorId)?.name ?? ev.actorId} · ${fmtTime(ev.at)}'),
              ),
          ]),
        );
      },
    );
  }
}
