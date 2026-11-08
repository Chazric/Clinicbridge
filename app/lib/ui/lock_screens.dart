import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/vault.dart';
import 'common.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onDone});
  final Future<void> Function(bool loadDemo) onDone;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  bool _accepted = false;
  bool _demo = true;
  String? _error;
  bool _busy = false;

  Future<void> _finish() async {
    final w = PinGuard.weakness(_pin.text);
    if (w != null) return setState(() => _error = w);
    if (_pin.text != _pin2.text) return setState(() => _error = 'PINs do not match.');
    setState(() => _busy = true);
    await Services.of(context).pin.setPin(_pin.text);
    await widget.onDone(_demo);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const SizedBox(height: 12),
            Image.asset('assets/logo.png', height: 84),
            const SizedBox(height: 12),
            Text('ClinicBridge AI', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
            const Text('One Patient. One Connected Encounter. One Continuous Clinical Record.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Clinical safety notice', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(clinicalDisclaimer),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _accepted,
                    onChanged: (v) => setState(() => _accepted = v ?? false),
                    title: const Text('I understand and accept'),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Create an app PIN (6+ digits). Biometrics can be used after setup.'),
            const SizedBox(height: 8),
            TextField(controller: _pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'PIN')),
            const SizedBox(height: 8),
            TextField(controller: _pin2, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Confirm PIN')),
            SwitchListTile(
              value: _demo,
              onChanged: (v) => setState(() => _demo = v),
              title: const Text('Load synthetic demo patients'),
              subtitle: const Text('Fictional records for training and evaluation. Off = start with an empty, real workspace.'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _accepted && !_busy ? _finish : null, child: const Text('Continue')),
          ]),
        ),
      );
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  Future<void> _bio() async {
    final b = Services.of(context).biometric;
    if (b != null && await b()) widget.onUnlocked();
  }

  Future<void> _check() async {
    final g = Services.of(context).pin;
    final locked = await g.lockedFor();
    if (locked != null) {
      return setState(() => _error = 'Too many attempts. Try again in ${locked.inMinutes + 1} min.');
    }
    if (await g.check(_pin.text)) {
      widget.onUnlocked();
    } else {
      _pin.clear();
      setState(() => _error = 'Incorrect PIN.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: brandNavy,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Image.asset('assets/logo.png', height: 96),
                  const SizedBox(height: 16),
                  const Text('ClinicBridge AI', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  const Text('Locked — patient data is encrypted', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _check(),
                    style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 8),
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      hintText: 'PIN',
                      hintStyle: TextStyle(color: Colors.white38, letterSpacing: 2),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                    ),
                  ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.orangeAccent))),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: brandTeal, minimumSize: const Size.fromHeight(48)),
                    onPressed: _check,
                    child: const Text('Unlock'),
                  ),
                  TextButton.icon(
                    onPressed: _bio,
                    icon: const Icon(Icons.fingerprint, color: Colors.white),
                    label: const Text('Use Face ID / fingerprint', style: TextStyle(color: Colors.white)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Second step after unlocking: pick the signed-in clinician profile.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    return Scaffold(
      appBar: AppBar(title: const Text('Who is using this device?')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Every action is recorded in the audit log under the selected profile and role.'),
          ),
          for (final c in s.clinicians)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(c.name.replaceAll(RegExp(r'^(Dr\.|RN)\s*'), '').substring(0, 1))),
                title: Text(c.name),
                subtitle: Text(c.role.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => s.signIn(c),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.person_add),
              label: const Text('Add profile'),
              onPressed: () => _add(context),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController();
    var role = Role.physician;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New profile'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 10),
            DropdownButtonFormField<Role>(
              initialValue: role,
              items: [for (final r in Role.values) DropdownMenuItem(value: r, child: Text(r.label))],
              onChanged: (v) => set(() => role = v ?? role),
              decoration: const InputDecoration(labelText: 'Role'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty && context.mounted) {
      await Services.of(context).state.addClinician(name.text.trim(), role);
    }
  }
}
