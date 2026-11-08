import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/platform_services.dart';
import 'core/vault.dart';
import 'demo/synthetic_data.dart';
import 'ui/common.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final secrets = KeychainSecretStore();
  final vault = Vault(dir: await vaultDirectory(), secrets: secrets);
  final state = AppState(persist: vault.save);
  final saved = await vault.load();
  if (saved != null) state.loadJson(saved);
  final pin = PinGuard(secrets);
  final bio = BiometricGate();
  runApp(ClinicBridgeApp(
    state: state,
    vault: vault,
    pin: pin,
    biometric: await bio.available() ? bio.authenticate : null,
    needsSetup: !await pin.isSet,
  ));
}

class ClinicBridgeApp extends StatefulWidget {
  const ClinicBridgeApp({
    super.key,
    required this.state,
    required this.vault,
    required this.pin,
    required this.biometric,
    required this.needsSetup,
  });

  final AppState state;
  final Vault vault;
  final PinGuard pin;
  final Future<bool> Function()? biometric;
  final bool needsSetup;

  @override
  State<ClinicBridgeApp> createState() => _ClinicBridgeAppState();
}

class _ClinicBridgeAppState extends State<ClinicBridgeApp> with WidgetsBindingObserver {
  late bool _setup = widget.needsSetup;
  bool _locked = true;
  DateTime? _backgroundedAt;
  final _translator = OnDeviceTranslation();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.applyRetention();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (s == AppLifecycleState.resumed) {
      final t = _backgroundedAt;
      _backgroundedAt = null;
      if (t != null && DateTime.now().difference(t).inMinutes >= widget.state.settings.autoLockMinutes) _lock();
    }
  }

  void _lock() {
    if (!mounted) return;
    setState(() {
      _locked = true;
      _setup = false;
    });
    widget.pin.isSet.then((set) {
      if (!set && mounted) setState(() => _setup = true);
    });
  }

  Future<void> _finishSetup(bool demo) async {
    if (demo) await SyntheticData.load(widget.state);
    widget.state.log('device-setup', 'device', demo ? 'synthetic demo' : 'empty workspace');
    await widget.state.commit();
    setState(() {
      _setup = false;
      _locked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Services(
      state: widget.state,
      vault: widget.vault,
      pin: widget.pin,
      translator: _translator,
      biometric: widget.biometric,
      onLock: _lock,
      child: MaterialApp(
        title: 'ClinicBridge AI',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            if (_setup) return SetupScreen(onDone: _finishSetup);
            if (_locked) {
              return LockScreen(onUnlocked: () {
                widget.state.log('unlock', 'device');
                setState(() => _locked = false);
              });
            }
            if (widget.state.currentUser == null) return const ProfileScreen();
            return const HomeScreen();
          },
        ),
      ),
    );
  }
}
