import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter/services.dart';
import 'app_settings.dart';
import 'device_crypto.dart';
import 'feedback_screen.dart';
import 'help_screen.dart';
import 'how_it_works_screen.dart';
import 'http_client.dart';
import 'qr_scanner_screen.dart';
import 'settings_screen.dart';
import 'totp.dart';
import 'totp_store.dart';
import 'transfer_accounts_screen.dart';
import 'zt_theme.dart';

void main() {
  runApp(const ZtAuthenticatorApp());
}

// Root app widget: theme + entry screen.
class ZtAuthenticatorApp extends StatelessWidget {
  const ZtAuthenticatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZT-Authenticator',
      theme: ztIamTheme(),
      home: const HomeScreen(),
    );
  }
}

// Landing screen with navigation to research flows.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AppSettings _settings = AppSettings();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _allowInsecureTls = false;
  bool _allowHttpDev = false;
  String _fallbackApiBaseUrl = '';
  final TotpStore _store = TotpStore();
  final List<TotpAccount> _totpAccounts = [];
  Timer? _ticker;
  Timer? _loginPoller;
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  bool _approvalDialogOpen = false;
  String _lastLoginId = '';
  bool _loginPollingEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _searchController.addListener(() {
      final next = _searchController.text.trim();
      if (next == _searchQuery) {
        return;
      }
      setState(() {
        _searchQuery = next;
      });
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final storedBaseUrl = await _settings.loadApiBaseUrl();
    final loginPollingEnabled = await _settings.loadLoginPollingEnabled();
    final allowInsecureTls = await _settings.loadAllowInsecureTls();
    final allowHttpDev = await _settings.loadAllowHttpDev();
    if (!mounted) {
      return;
    }
    setState(() {
      _loginPollingEnabled = loginPollingEnabled;
      _allowInsecureTls = allowInsecureTls;
      _allowHttpDev = allowHttpDev;
      _fallbackApiBaseUrl = storedBaseUrl ?? '';
    });
    _restartLoginPoller();
  }

  void _restartLoginPoller() {
    _loginPoller?.cancel();
    if (!_loginPollingEnabled) {
      _loginPoller = null;
      return;
    }
    _loginPoller = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollLoginApprovals();
    });
  }

  Future<void> _loadAccounts() async {
    final records = await _store.loadAll();
    setState(() {
      _totpAccounts
        ..clear()
        ..addAll(records.map(TotpAccount.fromRecord));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _loginPoller?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _addTotpAccount(TotpAccount account) {
    setState(() {
      _totpAccounts.add(account);
    });
  }

  Future<void> _updateAllAccountsBaseUrl(String baseUrl) async {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final normalized = trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';
    final accounts = List<TotpAccount>.from(_totpAccounts);
    for (final account in accounts) {
      final updated = TotpAccount(
        issuer: account.issuer,
        account: account.account,
        secret: account.secret,
        userId: account.userId,
        rpId: account.rpId,
        deviceId: account.deviceId,
        apiBaseUrl: normalized,
        keyId: account.keyId,
      );
      await _store.delete(account.toRecord());
      await _store.save(updated.toRecord());
      final idx = _totpAccounts.indexOf(account);
      if (idx >= 0) {
        _totpAccounts[idx] = updated;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _fallbackApiBaseUrl = normalized;
    });
  }

  Future<void> _showAccountInfo() async {
    final accounts = List<TotpAccount>.from(_totpAccounts);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Accounts'),
          content: SizedBox(
            width: double.maxFinite,
            child: accounts.isEmpty
                ? const Text('No accounts enrolled yet.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: accounts.length,
                    separatorBuilder: (_, __) => const Divider(height: 16),
                    itemBuilder: (_, index) {
                      final entry = accounts[index];
                      final issuer = entry.displayIssuer();
                      final account = entry.account.trim();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            issuer,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (account.isNotEmpty)
                            Text(
                              account,
                              style: const TextStyle(color: Colors.white70),
                            ),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _editAccount(TotpAccount account) async {
    final issuerController = TextEditingController(text: account.issuer);
    final accountController = TextEditingController(text: account.account);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: issuerController,
                decoration: const InputDecoration(labelText: 'Issuer'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: accountController,
                decoration: const InputDecoration(labelText: 'Email/Account'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final issuer = issuerController.text.trim();
                final accountLabel = accountController.text.trim();
                if (issuer.isEmpty || accountLabel.isEmpty) {
                  return;
                }
                Navigator.of(context).pop({
                  'issuer': issuer,
                  'account': accountLabel,
                });
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result == null) {
      return;
    }

    final updated = TotpAccount(
      issuer: result['issuer'] ?? account.issuer,
      account: result['account'] ?? account.account,
      secret: account.secret,
      userId: account.userId,
      rpId: account.rpId,
      deviceId: account.deviceId,
      apiBaseUrl: account.apiBaseUrl,
      keyId: account.keyId,
    );
    await _store.delete(account.toRecord());
    await _store.save(updated.toRecord());
    setState(() {
      final idx = _totpAccounts.indexOf(account);
      if (idx >= 0) {
        _totpAccounts[idx] = updated;
      }
    });
  }

  Future<void> _deleteAccount(TotpAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove account?'),
          content: Text('Remove ${account.account} from this device?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _store.delete(account.toRecord());
    setState(() {
      _totpAccounts.remove(account);
    });
  }

  String _profileInitial(List<TotpAccount> accounts) {
    if (accounts.isEmpty) {
      return 'P';
    }
    final raw = accounts.first.account.trim();
    if (raw.isEmpty) {
      return 'P';
    }
    final localPart = raw.contains('@') ? raw.split('@').first : raw;
    if (localPart.isEmpty) {
      return 'P';
    }
    return localPart[0].toUpperCase();
  }

  bool _isLocalHost(String host) {
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        RegExp(r'^[0-9.]+$').hasMatch(host) ||
        host.endsWith('.local') ||
        host.endsWith('.localdomain.com');
  }

  String _resolveAccountBaseUrl(TotpAccount account) {
    if (account.apiBaseUrl.trim().isNotEmpty) {
      final raw = account.apiBaseUrl.trim();
      final uri = Uri.tryParse(raw);
      if (_allowHttpDev && uri != null && _isLocalHost(uri.host)) {
        return uri.replace(scheme: 'http').toString();
      }
      return raw;
    }
    if (account.rpId.trim().isNotEmpty) {
      final scheme = _allowHttpDev && _isLocalHost(account.rpId.trim())
          ? 'http'
          : 'https';
      return '$scheme://${account.rpId.trim()}/api/auth';
    }
    return '';
  }

  String _resolveFeedbackBaseUrl() {
    return _totpAccounts
        .map(_resolveAccountBaseUrl)
        .firstWhere((value) => value.isNotEmpty, orElse: () => _fallbackApiBaseUrl);
  }

  Future<Map<String, dynamic>?> _accountGet(
    TotpAccount account,
    String path,
  ) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client = ApiClient(baseUrl: baseUrl, allowInsecureTls: _allowInsecureTls);
    try {
      final response = await client.get(path);
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> _accountPost(
    TotpAccount account,
    String path,
    Map<String, dynamic> payload,
  ) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return;
    }
    final client = ApiClient(baseUrl: baseUrl, allowInsecureTls: _allowInsecureTls);
    try {
      await client.postJson(path, payload);
    } finally {
      client.close();
    }
  }

  Future<void> _pollLoginApprovals() async {
    if (_totpAccounts.isEmpty) {
      return;
    }
    for (final account in _totpAccounts) {
      if (account.userId.isEmpty || account.rpId.isEmpty || account.deviceId.isEmpty) {
        continue;
      }
      try {
        final data = await _accountGet(account, '/login/pending?user_id=${account.userId}');
        if (data == null) {
          continue;
        }
        if (data['status'] != 'pending') {
          continue;
        }
        final pendingRp = data['rp_id'] as String? ?? '';
        final pendingDevice = data['device_id'] as String? ?? '';
        final loginId = data['login_id'] as String? ?? '';
        final nonce = data['nonce'] as String? ?? '';
        if (pendingRp != account.rpId ||
            pendingDevice != account.deviceId ||
            loginId.isEmpty ||
            nonce.isEmpty) {
          continue;
        }
        if (_approvalDialogOpen || loginId == _lastLoginId) {
          continue;
        }
        _lastLoginId = loginId;
        if (!mounted) {
          return;
        }
        _approvalDialogOpen = true;
        await _showApprovalDialog(
          account: account,
          loginId: loginId,
          nonce: nonce,
        );
        _approvalDialogOpen = false;
      } catch (_) {
        continue;
      }
    }
  }

  Future<void> _showApprovalDialog({
    required TotpAccount account,
    required String loginId,
    required String nonce,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Approve login?'),
          content: Text('Account: ${account.account}\nRP: ${account.rpId}'),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                await _accountPost(account, '/login/deny', {
                  'login_id': loginId,
                  'reason': 'user_denied',
                });
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Deny'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: ZtIamColors.accentGreen,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final otp = account.currentCode();
                final signature = await _deviceCrypto.sign(
                  rpId: account.rpId,
                  nonce: nonce,
                  deviceId: account.deviceId,
                  otp: otp,
                  keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
                );
                if (signature.isNotEmpty) {
                  await _accountPost(account, '/login/approve', {
                    'login_id': loginId,
                    'device_id': account.deviceId,
                    'rp_id': account.rpId,
                    'otp': otp,
                    'nonce': nonce,
                    'signature': signature,
                  });
                }
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Approve'),
            ),
          ],
        );
      },
    );
  }

  void _openActions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ZtIamColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const _BottomSheetHandle(),
              const SizedBox(height: 12),
              _SheetAction(
                icon: Icons.qr_code,
                label: 'TOTP setup (QR)',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TotpSetupScreen(
                        fallbackBaseUrl: _fallbackApiBaseUrl,
                        onBaseUrlDetected: (baseUrl) {
                          if (baseUrl.isEmpty) {
                            return;
                          }
                          _settings.saveApiBaseUrl(baseUrl);
                          setState(() {
                            _fallbackApiBaseUrl = baseUrl;
                          });
                        },
                        onRegistered: _addTotpAccount,
                      ),
                    ),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.approval_outlined,
                label: 'Login approvals',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LoginApprovalsScreen(
                        accounts: List<TotpAccount>.from(_totpAccounts),
                        deviceCrypto: _deviceCrypto,
                        allowInsecureTls: _allowInsecureTls,
                        fallbackBaseUrl: _fallbackApiBaseUrl,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = List<TotpAccount>.from(_totpAccounts);
    final filteredAccounts = _filterAccounts(accounts);
    final profileInitial = _profileInitial(accounts);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZT-Authenticator'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              onTap: _showAccountInfo,
              borderRadius: BorderRadius.circular(20),
              child: CircleAvatar(
                backgroundColor: ZtIamColors.card,
                child: Text(profileInitial),
              ),
            ),
          ),
        ],
      ),
      drawer: _AppDrawer(
        onTransferAccounts: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => TransferAccountsScreen(store: _store),
            ),
          );
          if (changed == true) {
            await _loadAccounts();
          }
        },
        onHowItWorks: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HowItWorksScreen()),
          );
        },
        onSettings: () async {
          final result = await Navigator.of(context).push<SettingsResult>(
            MaterialPageRoute(
              builder: (_) => SettingsScreen(
                initialLoginPolling: _loginPollingEnabled,
                initialAllowInsecureTls: _allowInsecureTls,
                initialAllowHttpDev: _allowHttpDev,
                settings: _settings,
              ),
            ),
          );
          if (result == null) {
            return;
          }
          setState(() {
            _loginPollingEnabled = result.loginPolling;
            _allowInsecureTls = result.allowInsecureTls;
            _allowHttpDev = result.allowHttpDev;
          });
          _restartLoginPoller();
        },
        onSendFeedback: () {
          final baseUrl = _resolveFeedbackBaseUrl();
          if (baseUrl.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No server available for feedback.')),
            );
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FeedbackScreen(
                apiClient: ApiClient(
                  baseUrl: baseUrl,
                  allowInsecureTls: _allowInsecureTls,
                ),
              ),
            ),
          );
        },
        onHelp: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HelpScreen()),
          );
        },
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      ),
              ),
            ),
            const SizedBox(height: 16),
            if (accounts.isEmpty)
              const _EmptyState()
            else if (filteredAccounts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No matching accounts found.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else
              ...filteredAccounts.map(
                (entry) => _AccountRow(
                  entry: entry,
                  onEdit: () => _editAccount(entry),
                  onDelete: () => _deleteAccount(entry),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openActions,
        child: const Icon(Icons.add),
      ),
    );
  }

  List<TotpAccount> _filterAccounts(List<TotpAccount> accounts) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return accounts;
    }
    return accounts.where((entry) {
      final issuer = entry.displayIssuer().toLowerCase();
      final account = entry.account.toLowerCase();
      final rpId = entry.rpId.toLowerCase();
      return issuer.contains(query) ||
          account.contains(query) ||
          rpId.contains(query);
    }).toList();
  }
}

class TotpAccount {
  TotpAccount({
    required this.issuer,
    required this.account,
    required this.secret,
    required this.userId,
    required this.rpId,
    required this.deviceId,
    required this.apiBaseUrl,
    required this.keyId,
  });

  final String issuer;
  final String account;
  final String secret;
  final String userId;
  final String rpId;
  final String deviceId;
  final String apiBaseUrl;
  final String keyId;

  String displayIssuer() {
    final issuerValue = issuer.trim();
    if (issuerValue.isEmpty) {
      return _shortenDomain(rpId);
    }
    final cleanedIssuer = _normalizeIssuer(issuerValue);
    final detectedDomain = _extractDomain(cleanedIssuer);
    if (detectedDomain.isNotEmpty) {
      return detectedDomain;
    }
    if (cleanedIssuer.contains('@')) {
      final domain = cleanedIssuer.split('@').last.trim();
      return _shortenDomain(domain);
    }
    return _shortenDomain(cleanedIssuer);
  }

  String _normalizeIssuer(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final dotParts = trimmed.split('.');
    if (dotParts.length == 2 && dotParts[0].toLowerCase() == dotParts[1].toLowerCase()) {
      return dotParts[0];
    }
    final colonParts = trimmed.split(':');
    if (colonParts.length == 2 && colonParts[0].toLowerCase() == colonParts[1].toLowerCase()) {
      return colonParts[0];
    }
    return trimmed;
  }

  String _extractDomain(String value) {
    final match = RegExp(r'([A-Za-z0-9-]+\.)+[A-Za-z]{2,}').firstMatch(value);
    if (match == null) {
      return '';
    }
    return _shortenDomain(match.group(0) ?? '');
  }

  String _shortenDomain(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Unknown issuer';
    }
    final cleaned = trimmed.replaceFirst(RegExp(r'^https?://'), '');
    return cleaned.split('/').first;
  }

  String currentCode() {
    return generateTotp(secret.replaceAll(' ', '').toUpperCase());
  }

  int secondsRemaining() {
    final seconds = DateTime.now().second % 30;
    return 30 - seconds;
  }

  double progress() {
    final elapsed = DateTime.now().second % 30;
    return elapsed / 30.0;
  }

  factory TotpAccount.fromRecord(TotpRecord record) {
    return TotpAccount(
      issuer: record.issuer,
      account: record.account,
      secret: record.secret,
      userId: record.userId,
      rpId: record.rpId,
      deviceId: record.deviceId,
      apiBaseUrl: record.apiBaseUrl,
      keyId: record.keyId,
    );
  }

  TotpRecord toRecord() {
    return TotpRecord(
      issuer: issuer,
      account: account,
      secret: secret,
      userId: userId,
      rpId: rpId,
      deviceId: deviceId,
      apiBaseUrl: apiBaseUrl,
      keyId: keyId,
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  final TotpAccount entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Slidable(
      key: ValueKey('${entry.issuer}|${entry.account}|${entry.deviceId}'),
      startActionPane: ActionPane(
        motion: const StretchMotion(),
        children: [
          SlidableAction(
            onPressed: (_) => onEdit(),
            backgroundColor: ZtIamColors.accentBlueDark,
            foregroundColor: Colors.white,
            icon: Icons.edit,
          ),
          SlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            icon: Icons.delete,
          ),
        ],
      ),
      child: _AccountTile(entry: entry),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.entry});

  final TotpAccount entry;

  @override
  Widget build(BuildContext context) {
    final code = entry.currentCode();
    final progress = entry.progress();
    final issuer = entry.displayIssuer();
    final account = entry.account.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      flex: 0,
                      child: Text(
                        issuer,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (account.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      const Text(
                        '•',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          account,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onLongPress: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('TOTP code copied')),
                      );
                    }
                  },
                  child: Text(
                    _formatCode(code),
                    style: const TextStyle(
                      fontSize: 28,
                      letterSpacing: 2.2,
                      color: ZtIamColors.accentSoft,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(color: ZtIamColors.divider),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ProgressRing(progress: progress),
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.progress,
  });

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ShaderMask(
            shaderCallback: (rect) {
              return SweepGradient(
                startAngle: -math.pi / 2,
                endAngle: math.pi * 1.5,
                colors: const [
                  ZtIamColors.accentBlue,
                  ZtIamColors.accentSoftMuted,
                ],
              ).createShader(rect);
            },
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 4,
              backgroundColor: ZtIamColors.divider,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              strokeCap: StrokeCap.round,
            ),
          ),
          const SizedBox.shrink(),
        ],
      ),
    );
  }
}

String _formatCode(String code) {
  if (code.length <= 3) {
    return code;
  }
  return '${code.substring(0, 3)} ${code.substring(3)}';
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: const [
          Icon(Icons.lock_outline, size: 48, color: Colors.white54),
          SizedBox(height: 12),
          Text(
            'No accounts yet',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 4),
          Text(
            'Add an account using TOTP setup.',
            style: TextStyle(color: Colors.white54),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.onTransferAccounts,
    required this.onHowItWorks,
    required this.onSettings,
    required this.onSendFeedback,
    required this.onHelp,
  });

  final VoidCallback onTransferAccounts;
  final VoidCallback onHowItWorks;
  final VoidCallback onSettings;
  final VoidCallback onSendFeedback;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: ZtIamColors.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'ZT-Authenticator',
              style: TextStyle(fontSize: 20, color: Colors.white),
            ),
            const SizedBox(height: 24),
            _DrawerItem(
              icon: Icons.sync_alt,
              label: 'Transfer accounts',
              onTap: onTransferAccounts,
            ),
            _DrawerItem(
              icon: Icons.info_outline,
              label: 'How it works',
              onTap: onHowItWorks,
            ),
            const Divider(color: ZtIamColors.divider),
            _DrawerItem(
              icon: Icons.settings,
              label: 'Settings',
              onTap: onSettings,
            ),
            _DrawerItem(
              icon: Icons.feedback_outlined,
              label: 'Send feedback',
              onTap: onSendFeedback,
            ),
            _DrawerItem(
              icon: Icons.help_outline,
              label: 'Help',
              onTap: onHelp,
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white70)),
      onTap: () {
        Navigator.of(context).pop();
        onTap?.call();
      },
    );
  }
}

class _BottomSheetHandle extends StatelessWidget {
  const _BottomSheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 4,
      decoration: BoxDecoration(
        color: ZtIamColors.divider,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      onTap: onTap,
    );
  }
}

// TOTP registration: calls backend to generate secret + QR.
class TotpSetupScreen extends StatefulWidget {
  const TotpSetupScreen({
    super.key,
    required this.fallbackBaseUrl,
    this.onBaseUrlDetected,
    required this.onRegistered,
  });

  final String fallbackBaseUrl;
  final ValueChanged<String>? onBaseUrlDetected;
  final ValueChanged<TotpAccount> onRegistered;

  @override
  State<TotpSetupScreen> createState() => _TotpSetupScreenState();
}

class _TotpSetupScreenState extends State<TotpSetupScreen> {
  final TotpStore _store = TotpStore();
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  final AppSettings _settings = AppSettings();
  final TextEditingController _setupKeyController = TextEditingController();
  String _status = '';
  List<String> _recoveryCodes = [];
  bool _loading = false;
  Map<String, dynamic>? _pendingPayload;
  String _detectedBaseUrl = '';
  String _connectivityHint = '';
  bool _allowInsecureTls = false;
  bool _allowHttpDev = false;
  String _lastEmail = '';
  String _lastRpId = '';
  String _lastIssuer = '';
  String _lastAccount = '';
  String _lastUserId = '';
  String _lastDeviceId = '';

  @override
  void dispose() {
    _setupKeyController.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (result == null || result.isEmpty) {
      return;
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(result) as Map<String, dynamic>;
    } catch (_) {
      setState(() {
        _status = 'Scanned QR is not a valid enrollment payload.';
      });
      return;
    }

    if (payload['type'] != 'zt_totp_enroll') {
      setState(() {
        _status = 'Enrollment QR type not recognized.';
      });
      return;
    }

    await _startEnrollment(payload);
  }

  @override
  void initState() {
    super.initState();
    _loadPendingEnrollment();
    _loadNetworkSettings();
  }

  Future<void> _loadPendingEnrollment() async {
    final raw = await _settings.loadPendingEnrollment();
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingPayload = decoded;
      });
    } catch (_) {
      await _settings.clearPendingEnrollment();
    }
  }

  Future<void> _loadNetworkSettings() async {
    final allowInsecureTls = await _settings.loadAllowInsecureTls();
    final allowHttpDev = await _settings.loadAllowHttpDev();
    if (!mounted) {
      return;
    }
    setState(() {
      _allowInsecureTls = allowInsecureTls;
      _allowHttpDev = allowHttpDev;
    });
  }

  String _resolveApiBaseUrl(Map<String, dynamic> payload) {
    final rawBase = (payload['api_base_url'] as String?)?.trim() ??
        (payload['base_url'] as String?)?.trim() ??
        (payload['enroll_url'] as String?)?.trim() ??
        '';
    if (rawBase.isNotEmpty) {
      final cleaned = _stripWhitespace(rawBase);
      if (cleaned.startsWith('http://') || cleaned.startsWith('https://')) {
        return _normalizeBaseUrl(cleaned);
      }
      return _normalizeBaseUrl('${_defaultScheme(cleaned)}://$cleaned');
    }
    final rpId = (payload['rp_id'] as String?)?.trim() ?? '';
    if (rpId.isEmpty) {
      return '';
    }
    return _normalizeBaseUrl('${_defaultScheme(rpId)}://$rpId/api/auth');
  }

  String _defaultScheme(String host) {
    final lowered = host.toLowerCase();
    if (_allowHttpDev && _isLocalAddress(lowered)) {
      return 'http';
    }
    return 'https';
  }

  String _normalizeBaseUrl(String value) {
    try {
      final cleaned = _stripWhitespace(value);
      final uri = Uri.parse(cleaned);
      var scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
      final host = uri.host.isEmpty ? uri.path : uri.host;
      final port = uri.hasPort ? ':${uri.port}' : '';
      if (_allowHttpDev && _isLocalAddress(host)) {
        scheme = 'http';
      }
      final path = uri.path;
      if (path.contains('/api/auth')) {
        return '$scheme://$host$port/api/auth';
      }
      if (path.endsWith('/enroll')) {
        final trimmed = path.substring(0, path.length - '/enroll'.length);
        return '$scheme://$host$port$trimmed';
      }
      if (path.isNotEmpty && path != '/') {
        return '$scheme://$host$port$path';
      }
      return '$scheme://$host$port/api/auth';
    } catch (_) {
      return '';
    }
  }

  String _stripWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), '');
  }

  String _normalizeSecret(String value) {
    return value.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  }

  bool _looksLikeBase32(String value) {
    return RegExp(r'^[A-Z2-7]+=*$').hasMatch(value);
  }

  Map<String, String>? _parseOtpauth(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'otpauth') {
      return null;
    }
    final secret = (uri.queryParameters['secret'] ?? '').trim();
    if (secret.isEmpty) {
      return null;
    }
    String issuer = (uri.queryParameters['issuer'] ?? '').trim();
    String account = '';
    if (uri.path.isNotEmpty) {
      final label = Uri.decodeComponent(uri.path.replaceFirst('/', ''));
      if (label.contains(':')) {
        final parts = label.split(':');
        if (issuer.isEmpty) {
          issuer = parts.first.trim();
        }
        account = parts.sublist(1).join(':').trim();
      } else {
        account = label.trim();
      }
    }
    return {
      'secret': secret,
      'issuer': issuer,
      'account': account,
    };
  }

  Future<Map<String, dynamic>?> _tryParseEnrollmentPayload(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic> && decoded['type'] == 'zt_totp_enroll') {
          return decoded;
        }
      } catch (_) {
        return null;
      }
    }
    final url = Uri.tryParse(trimmed);
    if (url != null && url.scheme.startsWith('http')) {
      final client = ApiClient(
        baseUrl: '${url.scheme}://${url.authority}',
        allowInsecureTls: _allowInsecureTls,
      );
      try {
        final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
        final response = await client.get(path);
        if (response.statusCode != 200) {
          return null;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['type'] == 'zt_totp_enroll') {
          return decoded;
        }
      } catch (_) {
        return null;
      } finally {
        client.close();
      }
    }

    const prefix = 'ZTENROLL:';
    if (!trimmed.toUpperCase().startsWith(prefix)) {
      return null;
    }
    final payloadPart = trimmed
        .substring(prefix.length)
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
    if (payloadPart.isEmpty) {
      return null;
    }
    try {
      final decodedBytes = base64Url.decode(base64Url.normalize(payloadPart));
      final decodedJson = utf8.decode(decodedBytes);
      final decoded = jsonDecode(decodedJson);
      if (decoded is Map<String, dynamic> && decoded['type'] == 'zt_totp_enroll') {
        return decoded;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _submitSetupKey() async {
    if (_loading) {
      return;
    }
    final raw = _setupKeyController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _status = 'Enter an enrollment code or otpauth URI.';
      });
      return;
    }

    final enrollmentPayload = await _tryParseEnrollmentPayload(raw);
    if (enrollmentPayload != null) {
      await _startEnrollment(enrollmentPayload);
      return;
    }

    final parsed = _parseOtpauth(raw);
    var secret = parsed?['secret'] ?? raw;
    var issuer = parsed?['issuer'] ?? '';
    var account = parsed?['account'] ?? '';

    secret = _normalizeSecret(secret);
    if (secret.isEmpty || !_looksLikeBase32(secret)) {
      setState(() {
        _status = 'Setup key must be a valid base32 secret.';
      });
      return;
    }
    if (issuer.isEmpty) {
      issuer = 'Local';
    }

    final record = TotpRecord(
      issuer: issuer,
      account: account,
      secret: secret,
      userId: '',
      rpId: '',
      deviceId: '',
      apiBaseUrl: '',
      keyId: '',
    );
    await _store.save(record);
    widget.onRegistered(TotpAccount.fromRecord(record));
    setState(() {
      _status = 'Setup key added.';
      _setupKeyController.clear();
    });
  }

  bool _isLoopbackHost(String host) {
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host.endsWith('.local') ||
        host.endsWith('.localdomain.com');
  }

  bool _isLocalAddress(String host) {
    return _isLoopbackHost(host) || RegExp(r'^[0-9.]+$').hasMatch(host);
  }

  String _buildKeyId(String rpId, String email) {
    final safeEmail = email.trim().toLowerCase();
    if (safeEmail.isEmpty) {
      return rpId.trim();
    }
    return '${rpId.trim()}|$safeEmail';
  }

  Future<void> _startEnrollment(Map<String, dynamic> payload) async {
    final email = (payload['email'] as String?)?.trim() ?? '';
    final rpId = (payload['rp_id'] as String?)?.trim() ?? '';
    final rpDisplayName =
        (payload['rp_display_name'] as String?)?.trim() ?? rpId;
    final issuer = (payload['issuer'] as String?)?.trim() ?? '';
    final accountName = (payload['account_name'] as String?)?.trim() ?? '';
    final enrollToken = (payload['enroll_token'] as String?)?.trim() ?? '';
    final deviceLabel =
        (payload['device_label'] as String?)?.trim() ?? 'Android Device';
    if (email.isEmpty ||
        rpId.isEmpty ||
        issuer.isEmpty ||
        accountName.isEmpty) {
      setState(() {
        _status = 'Enrollment QR is missing required fields.';
      });
      return;
    }

    final detectedBaseUrl = _resolveApiBaseUrl(payload);
    if (detectedBaseUrl.isNotEmpty) {
      await _settings.saveApiBaseUrl(detectedBaseUrl);
      widget.onBaseUrlDetected?.call(detectedBaseUrl);
    }
    if (mounted) {
      setState(() {
        _detectedBaseUrl = detectedBaseUrl;
        if (detectedBaseUrl.isNotEmpty) {
          final host = Uri.tryParse(detectedBaseUrl)?.host ?? '';
          _connectivityHint = _isLoopbackHost(host)
              ? 'Tip: use a LAN IP or tunnel URL for mobile devices.'
              : '';
        }
      });
    }

    setState(() {
      _loading = true;
      _status = 'Enrolling device...';
    });

    try {
      final baseUrl = detectedBaseUrl.isNotEmpty
          ? detectedBaseUrl
          : widget.fallbackBaseUrl.trim();
      if (baseUrl.isEmpty) {
        setState(() {
          _status = 'Enrollment needs a valid server URL.';
        });
        return;
      }
      final enrollClient = ApiClient(
        baseUrl: baseUrl,
        allowInsecureTls: _allowInsecureTls,
      );
      final keyId = _buildKeyId(rpId, email);
      final publicKey = await _deviceCrypto.generateKeypair(
        rpId: rpId,
        keyId: keyId,
      );
      if (publicKey.isEmpty) {
        setState(() {
          _status = 'Key generation failed.';
        });
        return;
      }
      final enrollPayload = {
        'email': email,
        'device_label': deviceLabel,
        'platform': Platform.isIOS ? 'ios' : Platform.isAndroid ? 'android' : 'unknown',
        'rp_id': rpId,
        'rp_display_name': rpDisplayName,
        'key_type': 'p256',
        'public_key': publicKey,
      };
      if (enrollToken.isNotEmpty) {
        enrollPayload['enroll_token'] = enrollToken;
      }
      final enrollResponse = await enrollClient.postJson(
        '/enroll',
        enrollPayload,
      );
      if (enrollResponse.statusCode != 200) {
        setState(() {
          _status = 'Enrollment failed: ${enrollResponse.body}';
        });
        await _settings.savePendingEnrollment(jsonEncode(payload));
        setState(() {
          _pendingPayload = payload;
        });
        return;
      }

      final enrollData = jsonDecode(enrollResponse.body) as Map<String, dynamic>;
      final userId = enrollData['user']['id'] as String;
      final deviceId = enrollData['device']['id'] as String;
      setState(() {
        _lastEmail = email;
        _lastRpId = rpId;
        _lastIssuer = issuer;
        _lastAccount = accountName;
        _lastUserId = userId;
        _lastDeviceId = deviceId;
        _status = 'Registering TOTP...';
      });

      final totpResponse = await enrollClient.postJson(
        '/totp/register',
        {
          'user_id': userId,
          'rp_id': rpId,
          'account_name': accountName,
          'issuer': issuer,
        },
      );
      if (totpResponse.statusCode != 200) {
        setState(() {
          _status = 'TOTP registration failed: ${totpResponse.body}';
        });
        return;
      }
      final totpData = jsonDecode(totpResponse.body) as Map<String, dynamic>;
      setState(() {
        _recoveryCodes =
            (totpData['recovery_codes'] as List<dynamic>).cast<String>();
      });
      if (totpData['otpauth_uri'] != null) {
        final uri = Uri.parse(totpData['otpauth_uri'] as String);
        final secret = uri.queryParameters['secret'] ?? '';
        final label = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
        if (secret.isNotEmpty) {
          final record = TotpRecord(
            issuer: issuer,
            account: label.isEmpty ? accountName : label,
            secret: secret,
            userId: userId,
            rpId: rpId,
            deviceId: deviceId,
            apiBaseUrl: detectedBaseUrl,
            keyId: keyId,
          );
          await _store.save(record);
          widget.onRegistered(TotpAccount.fromRecord(record));
        }
      }
      setState(() {
        _status = 'Enrollment complete.';
      });
      await _settings.clearPendingEnrollment();
      setState(() {
        _pendingPayload = null;
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
      await _settings.savePendingEnrollment(jsonEncode(payload));
      setState(() {
        _pendingPayload = payload;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TOTP Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Enrollment QR',
            subtitle: 'Scan a single QR to enroll and register TOTP.',
          ),
          if (_pendingPayload != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pending enrollment detected',
                      style: TextStyle(
                        color: ZtIamColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Retry enrollment when the connection improves.',
                      style: TextStyle(color: ZtIamColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              final payload = _pendingPayload;
                              if (payload != null) {
                                await _startEnrollment(payload);
                              }
                            },
                      child: const Text('Retry enrollment'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              await _settings.clearPendingEnrollment();
                              setState(() {
                                _pendingPayload = null;
                                _status = 'Pending enrollment cleared.';
                              });
                            },
                      child: const Text('Clear pending enrollment'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _scanQr,
            child: Text(_loading ? 'Working...' : 'Scan Enrollment QR'),
          ),
          if (_detectedBaseUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'API: $_detectedBaseUrl',
              style: const TextStyle(color: Colors.white70),
            ),
            if (_connectivityHint.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _connectivityHint,
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ],
          const SizedBox(height: 20),
          const _SectionHeader(
            title: 'Setup key',
            subtitle: 'Paste the enrollment link or a base32 secret.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _setupKeyController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Setup key or payload',
              hintText: 'https://.../enroll-code/XXXX or otpauth://totp/...',
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _loading ? null : _submitSetupKey,
            child: const Text('Add code'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Manual base32 setup is local-only and will show as Local.',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 12),
          if (_lastUserId.isNotEmpty || _lastDeviceId.isNotEmpty) ...[
            const _SectionHeader(
              title: 'Enrollment Summary',
              subtitle: 'Stored locally for verification.',
            ),
            const SizedBox(height: 8),
            Text('Email: $_lastEmail',
                style: const TextStyle(color: Colors.white70)),
            Text('RP ID: $_lastRpId',
                style: const TextStyle(color: Colors.white70)),
            Text('Account: $_lastAccount',
                style: const TextStyle(color: Colors.white70)),
            Text('Issuer: $_lastIssuer',
                style: const TextStyle(color: Colors.white70)),
            Text('User ID: $_lastUserId',
                style: const TextStyle(color: Colors.white70)),
            Text('Device ID: $_lastDeviceId',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class LoginApprovalsScreen extends StatefulWidget {
  const LoginApprovalsScreen({
    super.key,
    required this.accounts,
    required this.deviceCrypto,
    required this.allowInsecureTls,
    required this.fallbackBaseUrl,
  });

  final List<TotpAccount> accounts;
  final DeviceCrypto deviceCrypto;
  final bool allowInsecureTls;
  final String fallbackBaseUrl;

  @override
  State<LoginApprovalsScreen> createState() => _LoginApprovalsScreenState();
}

class _LoginApprovalsScreenState extends State<LoginApprovalsScreen> {
  String _status = '';
  bool _loading = false;
  Map<String, dynamic>? _pending;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  TotpAccount? _matchAccount(Map<String, dynamic> pending) {
    final rpId = pending['rp_id'] as String? ?? '';
    final deviceId = pending['device_id'] as String? ?? '';
    for (final account in widget.accounts) {
      if (account.rpId == rpId && account.deviceId == deviceId) {
        return account;
      }
    }
    return null;
  }

  String _resolveAccountBaseUrl(TotpAccount account) {
    if (account.apiBaseUrl.trim().isNotEmpty) {
      return account.apiBaseUrl.trim();
    }
    if (account.rpId.trim().isNotEmpty) {
      return 'https://${account.rpId.trim()}/api/auth';
    }
    return '';
  }

  Future<Map<String, dynamic>?> _accountGet(TotpAccount account, String path) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client = ApiClient(baseUrl: baseUrl, allowInsecureTls: widget.allowInsecureTls);
    try {
      final response = await client.get(path);
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>?> _accountPost(
    TotpAccount account,
    String path,
    Map<String, dynamic> payload,
  ) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client = ApiClient(baseUrl: baseUrl, allowInsecureTls: widget.allowInsecureTls);
    try {
      final response = await client.postJson(path, payload);
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      String? lastError;
      for (final account in widget.accounts) {
        if (account.userId.isEmpty) {
          continue;
        }
        try {
          final data =
              await _accountGet(account, '/login/pending?user_id=${account.userId}');
          if (data == null) {
            continue;
          }
          if (data['status'] == 'pending') {
            setState(() {
              _pending = data;
            });
            return;
          }
        } catch (error) {
          lastError = 'Error: $error';
        }
      }
      setState(() {
        _pending = null;
        _status = lastError ?? 'No pending logins.';
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _approve() async {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    final account = _matchAccount(pending);
    if (account == null) {
      setState(() {
        _status = 'No matching account for this login.';
      });
      return;
    }
    final loginId = pending['login_id'] as String? ?? '';
    final nonce = pending['nonce'] as String? ?? '';
    if (loginId.isEmpty || nonce.isEmpty) {
      setState(() {
        _status = 'Pending login is missing data.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final otp = account.currentCode();
      final signature = await widget.deviceCrypto.sign(
        rpId: account.rpId,
        nonce: nonce,
        deviceId: account.deviceId,
        otp: otp,
        keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
      );
      final response = await _accountPost(account, '/login/approve', {
        'login_id': loginId,
        'device_id': account.deviceId,
        'rp_id': account.rpId,
        'otp': otp,
        'nonce': nonce,
        'signature': signature,
      });
      setState(() {
        _status = response == null ? 'Approve failed.' : 'Approve: ok';
      });
      await _refresh();
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _deny() async {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    final account = _matchAccount(pending);
    if (account == null) {
      setState(() {
        _status = 'No matching account for this login.';
      });
      return;
    }
    final loginId = pending['login_id'] as String? ?? '';
    if (loginId.isEmpty) {
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final response = await _accountPost(account, '/login/deny', {
        'login_id': loginId,
        'reason': 'user_denied',
      });
      setState(() {
        _status = response == null ? 'Denied failed.' : 'Denied: ok';
      });
      await _refresh();
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _clearPending() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final pending = _pending;
      final account = pending == null ? null : _matchAccount(pending);
      if (account == null) {
        setState(() {
          _status = 'No pending login to clear.';
        });
        return;
      }
      final response = await _accountPost(account, '/login/clear', {
        'user_id': account.userId,
      });
      await _refresh();
      setState(() {
        _status = response != null
            ? 'Pending approvals cleared.'
            : 'Clear pending failed.';
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('Login approvals')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Pending login',
            subtitle: 'Approve or deny login requests.',
          ),
          const SizedBox(height: 16),
          if (pending == null)
            Text(_status, style: const TextStyle(color: Colors.white70)),
          if (pending != null) ...[
            Text('Login ID: ${pending['login_id']}',
                style: const TextStyle(color: Colors.white70)),
            Text('RP ID: ${pending['rp_id']}',
                style: const TextStyle(color: Colors.white70)),
            Text('Device ID: ${pending['device_id']}',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _loading ? null : _deny,
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZtIamColors.accentGreen,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _loading ? null : _approve,
                    child: const Text('Approve'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(color: Colors.white70)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _loading ? null : _refresh,
                  child: const Text('Refresh'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ZtIamColors.card,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _loading ? null : _clearPending,
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Clear pending',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Section header used across screens.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, color: Colors.white),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(color: Colors.white60),
        ),
      ],
    );
  }
}
