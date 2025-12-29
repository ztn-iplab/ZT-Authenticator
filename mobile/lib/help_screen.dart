import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'zt_theme.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const String supportEmail = 'support@example.com';

  Future<void> _copyEmail(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: supportEmail));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Support email copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: Container(
        decoration: const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _HelpCard(
              title: 'Common issues',
              body:
                  '• QR scan fails: Ensure the camera has permission and retry under good lighting.\n'
                  '• OTP rejected: Confirm device time is synced and try again.\n'
                  '• Login approvals missing: Check that polling is enabled in Settings.',
            ),
            const SizedBox(height: 12),
            _HelpCard(
              title: 'Contact support',
              body: 'Email us at $supportEmail for help with enrollment or access.',
              trailing: TextButton(
                onPressed: () => _copyEmail(context),
                child: const Text('Copy email'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({required this.title, required this.body, this.trailing});

  final String title;
  final String body;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: ZtIamColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(color: ZtIamColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
