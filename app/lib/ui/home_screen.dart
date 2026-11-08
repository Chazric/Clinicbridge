import 'package:flutter/material.dart';

import '../core/interpreter.dart';
import '../core/models.dart';
import '../core/rbac.dart';
import '../core/workflow_intel.dart';
import 'common.dart';
import 'handoff_screen.dart';
import 'patient_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = Services.of(context);
    final s = svc.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final u = s.user;
        final inbox = s.inbox;
        final active = s.encounters.where((e) => e.status != EncounterStatus.closed).toList()
          ..sort((a, b) => b.start.compareTo(a.start));
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('ClinicBridge AI'),
              Text('${u.name} · ${u.role.label}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ]),
            actions: [
              IconButton(tooltip: 'Lock', icon: const Icon(Icons.lock), onPressed: svc.onLock),
              IconButton(
                tooltip: 'Settings & governance',
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
              IconButton(tooltip: 'Switch profile', icon: const Icon(Icons.switch_account), onPressed: s.signOut),
            ],
          ),
          floatingActionButton: s.can(Permission.addEntry)
              ? FloatingActionButton.extended(
                  onPressed: () => _register(context),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('New encounter'),
                )
              : null,
          body: ListView(padding: const EdgeInsets.only(bottom: 90), children: [
            if (inbox.isNotEmpty)
              Card(
                color: Colors.amber.shade50,
                child: Column(children: [
                  const ListTile(
                    leading: Icon(Icons.move_to_inbox, color: Colors.orange),
                    title: Text('Handoffs awaiting your acceptance', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final h in inbox)
                    ListTile(
                      dense: true,
                      title: Text(s.patient(s.encounter(h.encounterId).patientId).fullName),
                      subtitle: Text('${h.format.label} from ${s.clinician(h.fromId)?.name ?? h.fromId}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => HandoffEditor(handoffId: h.id))),
                    ),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Active encounters (${active.length})', style: Theme.of(context).textTheme.titleMedium),
            ),
            if (active.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('No active encounters.')),
            for (final e in active) _EncounterCard(encounterId: e.id),
          ]),
        );
      },
    );
  }

  Future<void> _register(BuildContext context) async {
    final given = TextEditingController();
    final family = TextEditingController();
    final loc = TextEditingController(text: 'ED');
    DateTime? dob;
    var sex = 'female';
    var lang = 'en';
    var interp = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New patient encounter'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: given, decoration: const InputDecoration(labelText: 'Given name')),
              const SizedBox(height: 8),
              TextField(controller: family, decoration: const InputDecoration(labelText: 'Family name')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.cake_outlined),
                label: Text(dob == null ? 'Date of birth' : fmtDate(dob!)),
                onPressed: () async {
                  final d = await showDatePicker(context: ctx, firstDate: DateTime(1900), lastDate: DateTime.now(), initialDate: DateTime(1980));
                  if (d != null) set(() => dob = d);
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: sex,
                decoration: const InputDecoration(labelText: 'Sex'),
                items: const [
                  DropdownMenuItem(value: 'female', child: Text('Female')),
                  DropdownMenuItem(value: 'male', child: Text('Male')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                  DropdownMenuItem(value: 'unknown', child: Text('Unknown')),
                ],
                onChanged: (v) => set(() => sex = v ?? sex),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: lang,
                decoration: const InputDecoration(labelText: 'Preferred language'),
                items: [for (final l in interpreterLanguages) DropdownMenuItem(value: l.code, child: Text(l.name))],
                onChanged: (v) => set(() {
                  lang = v ?? lang;
                  interp = lang != 'en';
                }),
              ),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: interp, onChanged: (v) => set(() => interp = v), title: const Text('Interpreter needed')),
              TextField(controller: loc, decoration: const InputDecoration(labelText: 'Location')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (given.text.trim().isEmpty || family.text.trim().isEmpty || dob == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and date of birth are required.')));
      return;
    }
    await guarded(context, () async {
      await Services.of(context).state.registerPatient(
            givenName: given.text.trim(),
            familyName: family.text.trim(),
            birthDate: dob!,
            sex: sex,
            preferredLanguage: lang,
            interpreterNeeded: interp,
            location: loc.text.trim().isEmpty ? 'Unspecified' : loc.text.trim(),
          );
    });
  }
}

class _EncounterCard extends StatelessWidget {
  const _EncounterCard({required this.encounterId});
  final String encounterId;

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final e = s.encounter(encounterId);
    final p = s.patient(e.patientId);
    final alerts = s.alerts(e.id);
    final crit = alerts.where((a) => a.severity == AlertSeverity.critical).length;
    final warn = alerts.where((a) => a.severity == AlertSeverity.warning).length;
    final open = s.tasksFor(e.id).where((t) => t.isOpen).length;
    return Card(
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PatientScreen(encounterId: e.id))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(p.fullName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
              if (p.synthetic) const SyntheticBadge(),
            ]),
            const SizedBox(height: 2),
            Text('${p.ageOn(DateTime.now())}y ${p.sex} · DOB ${fmtDate(p.birthDate)} · MRN ${p.mrn}'),
            Text('${e.location} · ${s.clinician(e.responsibleClinicianId)?.name ?? '—'}', style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (!p.identityVerified) const Pill('ID not verified', color: Colors.red, icon: Icons.badge_outlined),
              if (p.interpreterNeeded) Pill('Interpreter: ${languageName(p.preferredLanguage)}', color: Colors.indigo, icon: Icons.translate),
              if (crit > 0) Pill('$crit critical', color: Colors.red.shade700, icon: Icons.error),
              if (warn > 0) Pill('$warn warnings', color: Colors.orange.shade800, icon: Icons.warning_amber),
              if (open > 0) Pill('$open open tasks', color: Colors.blueGrey, icon: Icons.checklist),
              if (e.status == EncounterStatus.handedOff) const Pill('Handed off', color: Colors.teal, icon: Icons.swap_horiz),
            ]),
          ]),
        ),
      ),
    );
  }
}
