import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'qr_scanner_screen.dart';
import 'totp_store.dart';
import 'zt_theme.dart';

class TransferAccountsScreen extends StatefulWidget {
  const TransferAccountsScreen({super.key, required this.store});

  final TotpStore store;

  @override
  State<TransferAccountsScreen> createState() => _TransferAccountsScreenState();
}

class _TransferAccountsScreenState extends State<TransferAccountsScreen> {
  final TextEditingController _importController = TextEditingController();
  List<TotpRecord> _records = [];
  String _exportCode = '';
  String _status = '';
  bool _loading = false;
  bool _showCode = false;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    final records = await widget.store.loadAll();
    setState(() {
      _records = records;
      _exportCode = _buildExportCode(records);
    });
  }

  String _buildExportCode(List<TotpRecord> records) {
    if (records.isEmpty) {
      return '';
    }
    final payload = {
      'type': 'zt_totp_transfer',
      'version': 1,
      'accounts': records.map((record) => record.normalized().toJson()).toList(),
    };
    final encoded = base64UrlEncode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    return 'ZTXFER:$encoded';
  }

  String _formatExportCode(String code) {
    if (code.isEmpty) {
      return '';
    }
    final cleaned = code.replaceAll(RegExp(r'\s+'), '');
    final groups = <String>[];
    for (var i = 0; i < cleaned.length; i += 4) {
      groups.add(cleaned.substring(i, i + 4 > cleaned.length ? cleaned.length : i + 4));
    }
    final lines = <String>[];
    for (var i = 0; i < groups.length; i += 8) {
      lines.add(groups.sublist(i, i + 8 > groups.length ? groups.length : i + 8).join(' '));
    }
    return lines.join('\n');
  }

  Future<void> _copyExportCode() async {
    if (_exportCode.isEmpty) {
      setState(() {
        _status = 'No accounts to export yet.';
      });
      return;
    }
    await Clipboard.setData(ClipboardData(text: _exportCode));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transfer code copied to clipboard.')),
    );
  }

  Future<void> _importAccounts() async {
    final raw = _importController.text.trim();
    await _importAccountsFromRaw(raw);
  }

  Future<void> _scanImportCode() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (result == null || result.trim().isEmpty) {
      return;
    }
    _importController.text = result.trim();
    await _importAccountsFromRaw(result.trim());
  }

  Future<void> _importAccountsFromRaw(String raw) async {
    if (raw.isEmpty) {
      setState(() {
        _status = 'Paste a transfer code to import accounts.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });

    try {
      final payload = _decodePayload(raw);
      final List<dynamic> accounts = _extractAccounts(payload);
      if (accounts.isEmpty) {
        throw const FormatException('No accounts found in transfer payload.');
      }
      for (final entry in accounts) {
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final record = TotpRecord.fromJson(entry);
        if (record.issuer.isEmpty || record.account.isEmpty || record.secret.isEmpty) {
          continue;
        }
        await widget.store.save(record);
      }
      await _loadRecords();
      _importController.clear();
      if (mounted) {
        setState(() {
          _status = 'Accounts imported successfully.';
        });
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      setState(() {
        _status = 'Import failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Map<String, dynamic> _decodePayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      return jsonDecode(trimmed) as Map<String, dynamic>;
    }
    final cleaned = trimmed.replaceAll(RegExp(r'\s+'), '');
    const prefix = 'ZTXFER:';
    final payloadRaw = cleaned.toUpperCase().startsWith(prefix)
        ? cleaned.substring(prefix.length)
        : cleaned;
    final normalized = base64Url.normalize(payloadRaw);
    try {
      final decoded = utf8.decode(base64Url.decode(normalized));
      return jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      final decoded = utf8.decode(base64.decode(payloadRaw));
      return jsonDecode(decoded) as Map<String, dynamic>;
    }
  }

  List<dynamic> _extractAccounts(Map<String, dynamic> payload) {
    if (payload['type'] != 'zt_totp_transfer') {
      throw const FormatException('Unsupported transfer payload type.');
    }
    final accounts = payload['accounts'];
    if (accounts is List<dynamic>) {
      return accounts;
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transfer Accounts')),
      body: Container(
        decoration: const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Move accounts between devices by copying a transfer code.',
              style: TextStyle(color: ZtIamColors.textSecondary),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Export',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _records.isEmpty
                        ? 'No accounts to export yet.'
                        : 'Export ${_records.length} account(s).',
                    style: const TextStyle(color: ZtIamColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  if (_exportCode.isNotEmpty)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: QrImageView(
                          data: _exportCode,
                          version: QrVersions.auto,
                          size: 200,
                        ),
                      ),
                    ),
                  if (_exportCode.isNotEmpty) const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _copyExportCode,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy transfer code'),
                  ),
                  const SizedBox(height: 12),
                  if (_exportCode.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _showCode = !_showCode;
                        });
                      },
                      child: Text(_showCode ? 'Hide code' : 'Show code'),
                    ),
                  if (_exportCode.isNotEmpty && _showCode)
                    SelectableText(
                      _formatExportCode(_exportCode),
                      style: const TextStyle(color: ZtIamColors.textMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Import',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Scan a transfer QR or paste a transfer code.',
                    style: TextStyle(color: ZtIamColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _importController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Paste transfer code or scanned QR payload...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _loading ? null : _scanImportCode,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan QR'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _loading ? null : _importAccounts,
                          icon: const Icon(Icons.file_download),
                          label: Text(_loading ? 'Importing...' : 'Import'),
                        ),
                      ),
                    ],
                  ),
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(_status, style: const TextStyle(color: ZtIamColors.textSecondary)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

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
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
