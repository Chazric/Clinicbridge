import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/fhir.dart';
import '../core/rbac.dart';
import '../core/vault.dart';
import 'common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = Services.of(context);
    final s = svc.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final ledgerBreak = s.ledger.verifyChain();
        final auditBreak = s.verifyAuditChain();
        return Scaffold(
          appBar: AppBar(title: const Text('Settings & governance')),
          body: ListView(children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(s.user.name),
              subtitle: Text('Role: ${s.user.role.label} · permissions: ${Rbac.matrix[s.user.role]!.map((p) => p.name).join(', ')}'),
            ),
            _LicenceTile(s: s),
            const Divider(),
            ListTile(
              leading: Icon(ledgerBreak == -1 && auditBreak == -1 ? Icons.verified_user : Icons.gpp_bad,
                  color: ledgerBreak == -1 && auditBreak == -1 ? Colors.green : Colors.red),
              title: const Text('Record integrity'),
              subtitle: Text('Clinical Truth Ledger: ${ledgerBreak == -1 ? 'intact (${s.ledger.entries.length} versions)' : 'BROKEN at entry $ledgerBreak'}\n'
                  'Audit log: ${auditBreak == -1 ? 'intact (${s.audit.length} events)' : 'BROKEN at event $auditBreak'}'),
              isThreeLine: true,
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: const Text('Audit log'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuditScreen())),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('FHIR export profile'),
              subtitle: Text(s.settings.fhirProfile.label),
              trailing: DropdownButton<FhirProfile>(
                value: s.settings.fhirProfile,
                underline: const SizedBox(),
                items: [for (final p in FhirProfile.values) DropdownMenuItem(value: p, child: Text(p.name))],
                onChanged: (v) => s.updateSettings((x) => x.fhirProfile = v ?? x.fhirProfile),
              ),
            ),
            const ListTile(
              leading: Icon(Icons.sync_disabled),
              title: Text('EHR synchronization'),
              subtitle: Text('Not connected. This build is device-only; export FHIR bundles manually. EHR connectors are configured per hospital.'),
            ),
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text('Qualified interpreter line'),
              subtitle: Text(s.settings.interpreterServicePhone.isEmpty ? 'Not set' : s.settings.interpreterServicePhone),
              onTap: () async {
                final v = await promptText(context, 'Interpreter service phone', initial: s.settings.interpreterServicePhone);
                if (v != null) await s.updateSettings((x) => x.interpreterServicePhone = v);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Auto-lock'),
              trailing: DropdownButton<int>(
                value: s.settings.autoLockMinutes,
                underline: const SizedBox(),
                items: const [1, 2, 5, 10].map((m) => DropdownMenuItem(value: m, child: Text('$m min'))).toList(),
                onChanged: (v) => s.updateSettings((x) => x.autoLockMinutes = v ?? x.autoLockMinutes),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.auto_delete_outlined),
              title: const Text('Retention: closed encounters'),
              subtitle: const Text('Purged from this device after'),
              trailing: DropdownButton<int>(
                value: s.settings.retentionDays,
                underline: const SizedBox(),
                items: const [1, 7, 30, 90].map((d) => DropdownMenuItem(value: d, child: Text('$d days'))).toList(),
                onChanged: (v) => s.updateSettings((x) => x.retentionDays = v ?? x.retentionDays),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Apply retention now'),
              onTap: () async {
                final n = await s.applyRetention();
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n encounter(s) purged.')));
              },
            ),
            const Divider(),
            if (s.can(Permission.exportData))
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('Encrypted backup'),
                subtitle: const Text('Passphrase-protected (AES-256-GCM). Store it only where your organisation allows.'),
                onTap: () async {
                  final pass = await promptText(context, 'Backup passphrase (10+ characters)');
                  if (pass == null || !context.mounted) return;
                  await guarded(context, () async {
                    final blob = await Vault.exportBackup(s.toJson(), pass);
                    s.log('backup-exported', 'vault');
                    await s.commit();
                    await SharePlus.instance.share(ShareParams(text: blob, subject: 'ClinicBridge encrypted backup'));
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Restore from backup'),
              onTap: () async {
                final blob = await promptText(context, 'Paste backup', lines: 4);
                if (blob == null || !context.mounted) return;
                final pass = await promptText(context, 'Passphrase');
                if (pass == null || !context.mounted) return;
                await guarded(context, () async {
                  final data = await Vault.importBackup(blob, pass);
                  s.loadJson(data);
                  await s.reloadLicence();
                  s.log('backup-restored', 'vault');
                  await s.commit();
                }, success: 'Restored.');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Erase all data on this device', style: TextStyle(color: Colors.red)),
              subtitle: const Text('Destroys the encryption key and every record, profile and PIN. Cannot be undone.'),
              onTap: () async {
                final ok = await promptText(context, 'Type ERASE to confirm');
                if (ok != 'ERASE' || !context.mounted) return;
                try {
                  await s.removeLicence().timeout(const Duration(seconds: 10));
                } catch (_) {}
                await svc.vault.destroy();
                await svc.pin.clear();
                s.clearAll();
                svc.onLock();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.policy_outlined),
              title: const Text('Privacy policy'),
              onTap: () => launchUrl(Uri.parse('https://chazric.github.io/Clinicbridge/privacy.html')),
            ),
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Support'),
              subtitle: const Text(supportEmail),
              onTap: () => launchUrl(Uri(scheme: 'mailto', path: supportEmail, query: 'subject=ClinicBridge support')),
            ),
            const AboutListTile(
              icon: Icon(Icons.info_outline),
              applicationName: 'ClinicBridge AI',
              applicationVersion: '1.0.0 (prototype)',
              applicationLegalese: '© RED REISHI LLC\n\n$clinicalDisclaimer',
            ),
          ]),
        );
      },
    );
  }
}

class AuditScreen extends StatelessWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context).state;
    final list = s.audit.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text('Audit log (${list.length})')),
      body: ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final a = list[i];
          return ListTile(
            dense: true,
            title: Text('${a.action} · ${a.target.length > 18 ? '${a.target.substring(0, 18)}…' : a.target}'),
            subtitle: Text('${s.clinician(a.actorId)?.name ?? a.actorId} (${a.role.label}) · ${fmtTime(a.at)}${a.detail == null ? '' : '\n${a.detail}'}'),
            trailing: Text(a.hash.substring(0, 8), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          );
        },
      ),
    );
  }
}

class _LicenceTile extends StatelessWidget {
  const _LicenceTile({required this.s});
  final AppState s;

  String _summary() {
    final l = s.licence;
    if (s.settings.licenceKey.isEmpty || l == null) {
      return 'Synthetic demo only. Enter your clinic\'s licence key to record real patients.';
    }
    if (!s.licensed) {
      return 'Licence ${l.status == 'inactive' ? 'inactive' : 'expired'}. Ask your clinic administrator to renew, then tap Refresh.';
    }
    final until = l.expiresAt == null ? '' : ' until ${fmtTime(l.expiresAt!)}';
    return '${l.status == 'trialing' ? 'Free trial' : 'Active'}$until · ${l.devicesUsed}/${l.seats} seat(s) in use';
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = s.settings.licenceKey.isNotEmpty;
    return ListTile(
      leading: Icon(s.licensed ? Icons.verified_user : Icons.verified_user_outlined, color: s.licensed ? Colors.teal : null),
      title: const Text('Licence'),
      subtitle: Text(_summary()),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.key),
              title: Text(hasKey ? 'Change licence key' : 'Enter licence key'),
              onTap: () async {
                Navigator.pop(ctx);
                final key = await promptText(context, 'Clinic licence key', hint: 'CB-XXXX-XXXX-XXXX-XXXX');
                if (key == null || !context.mounted) return;
                await guarded(context, () => s.activateLicence(key), success: 'Licence activated on this device.');
              },
            ),
            if (hasKey)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Refresh licence'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await guarded(context, () => s.refreshLicence(), success: 'Licence refreshed.');
                },
              ),
            if (hasKey)
              ListTile(
                leading: const Icon(Icons.phonelink_erase),
                title: const Text('Remove licence from this device'),
                subtitle: const Text('Frees the seat for another clinician.'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await guarded(context, () => s.removeLicence(), success: 'Licence removed.');
                },
              ),
            const ListTile(
              dense: true,
              leading: Icon(Icons.info_outline),
              title: Text('Licences are issued to your clinic by RED REISHI LLC. Only the licence key and a random '
                  'install id are sent to the licence server; no patient information is ever sent.'),
            ),
          ]),
        ),
      ),
    );
  }
}
