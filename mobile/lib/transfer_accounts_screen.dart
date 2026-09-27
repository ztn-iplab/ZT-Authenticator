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
  // A QR code has a hard physical capacity (a few KB at most). Exporting
  // every enrolled account as one blob can exceed it once enough accounts
  // are enrolled, which used to crash the screen with an uncaught
  // InputTooLongException from the QR encoder. _qrChunkSafeBudget keeps
  // each chunk comfortably inside that limit (and easy for a phone camera
  // to actually scan); _qrHardByteLimit is the last-resort guard that skips
  // rendering entirely rather than ever handing the encoder more than it
  // can hold.
  static const int _qrChunkSafeBudget = 900;
  static const int _qrHardByteLimit = 2900;

  final TextEditingController _importController = TextEditingController();
  List<TotpRecord> _records = [];
  String _exportCode = '';
  List<String> _qrChunks = [];
  int _qrChunkIndex = 0;
  String _status = '';
  bool _loading = false;
  bool _showCode = false;

  String? _pendingTransferId;
  final Map<int, List<dynamic>> _pendingParts = {};

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
      _qrChunks = _buildQrChunks(records);
      _qrChunkIndex = 0;
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

  /// Splits accounts across as many QR-sized parts as needed so export never
  /// exceeds a QR code's capacity, no matter how many accounts are enrolled.
  /// Each part carries a shared transfer id plus its own part/total index so
  /// the scanner can reassemble them in any scan order. The clipboard/paste
  /// path is unaffected -- it always uses the single, unlimited-size
  /// _buildExportCode blob above.
  List<String> _buildQrChunks(List<TotpRecord> records) {
    if (records.isEmpty) {
      return [];
    }
    final transferId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final batches = <List<TotpRecord>>[];
    var current = <TotpRecord>[];
    for (final record in records) {
      final candidate = [...current, record];
      final probe = _encodeTransferPart(transferId, 0, 1, candidate);
      if (probe.length > _qrChunkSafeBudget && current.isNotEmpty) {
        batches.add(current);
        current = [record];
      } else {
        current = candidate;
      }
    }
    if (current.isNotEmpty) {
      batches.add(current);
    }
    final total = batches.length;
    return [
      for (var i = 0; i < batches.length; i++)
        _encodeTransferPart(transferId, i + 1, total, batches[i]),
    ];
  }

  String _encodeTransferPart(String transferId, int part, int total, List<TotpRecord> records) {
    final payload = {
      'type': 'zt_totp_transfer_part',
      'version': 1,
      'transfer_id': transferId,
      'part': part,
      'total': total,
      'accounts': records.map((record) => record.normalized().toJson()).toList(),
    };
    final encoded = base64UrlEncode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    return 'ZTXFERP:$encoded';
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
      if (payload['type'] == 'zt_totp_transfer_part') {
        await _handleTransferPart(payload);
      } else {
        final List<dynamic> accounts = _extractAccounts(payload);
        await _finishImport(accounts);
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

  /// Accumulates one QR-sized slice of a chunked export (see _buildQrChunks)
  /// until every part sharing its transfer id has been scanned, then imports
  /// the merged account list. Parts can arrive in any order; scanning a part
  /// from a different transfer clears whatever was pending so accounts from
  /// two unrelated exports never get merged together.
  Future<void> _handleTransferPart(Map<String, dynamic> payload) async {
    final transferId = payload['transfer_id']?.toString() ?? '';
    final part = int.tryParse('${payload['part']}') ?? 0;
    final total = int.tryParse('${payload['total']}') ?? 0;
    final accounts = payload['accounts'];
    if (transferId.isEmpty || part < 1 || total < 1 || accounts is! List<dynamic>) {
      throw const FormatException('Malformed transfer part.');
    }
    if (_pendingTransferId != null && _pendingTransferId != transferId) {
      _pendingParts.clear();
    }
    _pendingTransferId = transferId;
    _pendingParts[part] = accounts;

    if (_pendingParts.length < total) {
      _importController.clear();
      setState(() {
        _status = 'Received part ${_pendingParts.length} of $total. Tap "Scan QR" again for the next code.';
      });
      return;
    }

    final merged = <dynamic>[
      for (var i = 1; i <= total; i++) ...?_pendingParts[i],
    ];
    _pendingTransferId = null;
    _pendingParts.clear();
    await _finishImport(merged);
  }

  Future<void> _finishImport(List<dynamic> accounts) async {
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
  }

  Map<String, dynamic> _decodePayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      return jsonDecode(trimmed) as Map<String, dynamic>;
    }
    final cleaned = trimmed.replaceAll(RegExp(r'\s+'), '');
    const partPrefix = 'ZTXFERP:';
    const fullPrefix = 'ZTXFER:';
    final upperCleaned = cleaned.toUpperCase();
    String payloadRaw;
    if (upperCleaned.startsWith(partPrefix)) {
      payloadRaw = cleaned.substring(partPrefix.length);
    } else if (upperCleaned.startsWith(fullPrefix)) {
      payloadRaw = cleaned.substring(fullPrefix.length);
    } else {
      payloadRaw = cleaned;
    }
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

  List<Widget> _buildQrSection() {
    final chunk = _qrChunks[_qrChunkIndex];
    if (chunk.length > _qrHardByteLimit) {
      // Last-resort guard: even a single account's data was too large to
      // fit safely in one QR code (e.g. an unusually long relying-party
      // URL). Never hand that to the QR encoder -- fall back to the
      // clipboard/paste path instead of crashing the screen.
      return const [
        Text(
          'This account\'s data is too large for a QR code. Use "Copy transfer code" below and paste it on the other device instead.',
          style: TextStyle(color: ZtIamColors.textSecondary),
        ),
      ];
    }
    return [
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(
            data: chunk,
            version: QrVersions.auto,
            size: 200,
            // Belt-and-suspenders alongside the _qrHardByteLimit check above:
            // if the QR encoder still rejects the payload for any reason,
            // show a plain-text fallback instead of an uncaught
            // InputTooLongException crashing the screen.
            errorStateBuilder: (context, error) => const SizedBox(
              width: 200,
              height: 200,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Could not render this QR code. Use "Copy transfer code" below instead.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ZtIamColors.textSecondary),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      if (_qrChunks.length > 1) ...[
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              onPressed: _qrChunkIndex > 0
                  ? () => setState(() => _qrChunkIndex -= 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            // Expanded so long "QR N of M -- ..." labels (double-digit
            // chunk counts especially) wrap within the available width
            // instead of forcing the Row wider than its parent, which
            // used to overflow off the right edge of the screen.
            Expanded(
              child: Text(
                'QR ${_qrChunkIndex + 1} of ${_qrChunks.length} -- scan each in turn on the receiving device',
                textAlign: TextAlign.center,
                style: const TextStyle(color: ZtIamColors.textSecondary),
              ),
            ),
            IconButton(
              onPressed: _qrChunkIndex < _qrChunks.length - 1
                  ? () => setState(() => _qrChunkIndex += 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    ];
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
                  if (_qrChunks.isNotEmpty) ..._buildQrSection(),
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
