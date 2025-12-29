import 'package:flutter/material.dart';

import 'zt_theme.dart';

class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How It Works')),
      body: Container(
        decoration: const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            _InfoCard(
              title: '1. Enroll your device',
              body:
                  'Scan the enrollment QR code or paste a setup key. The app registers the device when available and stores the account.',
            ),
            SizedBox(height: 12),
            _InfoCard(
              title: '2. Register TOTP',
              body:
                  'After enrollment (or manual setup), the app begins generating time-based one-time passwords.',
            ),
            SizedBox(height: 12),
            _InfoCard(
              title: '3. Approve logins',
              body:
                  'Login approvals combine OTPs and device-bound signatures to confirm sign-in challenges.',
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: ZtIamColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(color: ZtIamColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
