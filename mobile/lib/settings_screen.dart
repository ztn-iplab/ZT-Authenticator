import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'zt_theme.dart';

class SettingsResult {
  const SettingsResult({
    required this.loginPolling,
    required this.allowInsecureTls,
    required this.allowHttpDev,
  });

  final bool loginPolling;
  final bool allowInsecureTls;
  final bool allowHttpDev;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialLoginPolling,
    required this.initialAllowInsecureTls,
    required this.initialAllowHttpDev,
    required this.settings,
  });

  final bool initialLoginPolling;
  final bool initialAllowInsecureTls;
  final bool initialAllowHttpDev;
  final AppSettings settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loginPolling = true;
  bool _allowInsecureTls = false;
  bool _allowHttpDev = false;
  String _status = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loginPolling = widget.initialLoginPolling;
    _allowInsecureTls = widget.initialAllowInsecureTls;
    _allowHttpDev = widget.initialAllowHttpDev;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _status = '';
    });
    await widget.settings.saveLoginPollingEnabled(_loginPolling);
    await widget.settings.saveAllowInsecureTls(_allowInsecureTls);
    await widget.settings.saveAllowHttpDev(_allowHttpDev);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(
      SettingsResult(
        loginPolling: _loginPolling,
        allowInsecureTls: _allowInsecureTls,
        allowHttpDev: _allowHttpDev,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Container(
        decoration: const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Behavior',
              style: TextStyle(
                color: ZtIamColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _loginPolling,
              title: const Text('Login approval polling'),
              subtitle: const Text('Check for login approvals every few seconds.'),
              onChanged: (value) => setState(() => _loginPolling = value),
            ),
            SwitchListTile(
              value: _allowInsecureTls,
              title: const Text('Allow self-signed TLS'),
              subtitle: const Text('Use for local testing only.'),
              onChanged: (value) => setState(() => _allowInsecureTls = value),
            ),
            SwitchListTile(
              value: _allowHttpDev,
              title: const Text('Allow HTTP for local testing'),
              subtitle: const Text('Use only when HTTPS is unavailable on LAN.'),
              onChanged: (value) => setState(() => _allowHttpDev = value),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving...' : 'Save settings'),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_status, style: const TextStyle(color: ZtIamColors.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}
