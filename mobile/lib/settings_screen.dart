import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'zt_theme.dart';

class SettingsResult {
  const SettingsResult({
    required this.loginPolling,
    required this.allowInsecureTls,
  });

  final bool loginPolling;
  final bool allowInsecureTls;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialLoginPolling,
    required this.initialAllowInsecureTls,
    required this.settings,
  });

  final bool initialLoginPolling;
  final bool initialAllowInsecureTls;
  final AppSettings settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loginPolling = true;
  bool _allowInsecureTls = false;
  String _status = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loginPolling = widget.initialLoginPolling;
    _allowInsecureTls = widget.initialAllowInsecureTls;
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _status = '';
    });
    await widget.settings.saveLoginPollingEnabled(_loginPolling);
    await widget.settings.saveAllowInsecureTls(_allowInsecureTls);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(
      SettingsResult(
        loginPolling: _loginPolling,
        allowInsecureTls: _allowInsecureTls,
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
