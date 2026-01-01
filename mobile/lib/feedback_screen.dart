import 'package:flutter/material.dart';

import 'http_client.dart';
import 'zt_theme.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key, required this.apiClient});

  final ApiClient apiClient;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  String _category = 'Bug';
  String _status = '';
  bool _sending = false;

  @override
  void dispose() {
    _emailController.dispose();
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _sendFeedback() async {
    final subject = _subjectController.text.trim();
    final message = _messageController.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      setState(() {
        _status = 'Subject and message are required.';
      });
      return;
    }

    setState(() {
      _sending = true;
      _status = '';
    });

    final payload = {
      'email': _emailController.text.trim(),
      'subject': subject,
      'category': _category,
      'message': message,
      'source': 'zt-authenticator-mobile',
    };

    try {
      final response = await widget.apiClient.postJson('/feedback', payload);
      if (response.statusCode != 200) {
        setState(() {
          _status = 'Failed to send feedback: ${response.body}';
        });
        return;
      }
      setState(() {
        _status = 'Feedback sent. Thank you!';
      });
      _subjectController.clear();
      _messageController.clear();
    } catch (error) {
      setState(() {
        _status = 'Failed to send feedback: $error';
      });
    } finally {
      setState(() {
        _sending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Feedback')),
      body: Container(
        decoration: const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'We use feedback to improve ZT-Authenticator. Tell us what you need.',
              style: TextStyle(color: ZtIamColors.textSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              'Sending to ${widget.apiClient.baseUrl}',
              style: const TextStyle(color: ZtIamColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
                hintText: 'name@example.com',
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _category,
              items: const [
                DropdownMenuItem(value: 'Bug', child: Text('Bug report')),
                DropdownMenuItem(value: 'Feature', child: Text('Feature request')),
                DropdownMenuItem(value: 'Support', child: Text('Support')),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _category = value);
              },
              decoration: const InputDecoration(labelText: 'Category'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(labelText: 'Subject'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _sending ? null : _sendFeedback,
              child: Text(_sending ? 'Sending...' : 'Send feedback'),
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
