import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'device_crypto.dart';
import 'http_client.dart';
import 'qr_scanner_screen.dart';
import 'totp.dart';
import 'totp_store.dart';

// Android emulator reaches host localhost via 10.0.2.2.
const String apiBaseUrl = 'http://192.168.60.2:8000';

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
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121212),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1F1F1F),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF1F1F1F),
          foregroundColor: Colors.white,
        ),
      ),
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
  late final ApiClient _apiClient;
  final TotpStore _store = TotpStore();
  final List<TotpAccount> _totpAccounts = [];
  Timer? _ticker;
  Timer? _loginPoller;
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  bool _approvalDialogOpen = false;
  String _lastLoginId = '';

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(baseUrl: apiBaseUrl);
    print('API base URL: $apiBaseUrl');
    _loadAccounts();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
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
    _apiClient.close();
    super.dispose();
  }

  void _addTotpAccount(TotpAccount account) {
    setState(() {
      _totpAccounts.add(account);
    });
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
        final response = await _apiClient.get('/login/pending?user_id=${account.userId}');
        if (response.statusCode != 200) {
          continue;
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
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
            TextButton(
              onPressed: () async {
                await _apiClient.postJson('/login/deny', {
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
              onPressed: () async {
                final otp = account.currentCode();
                final signature = await _deviceCrypto.sign(
                  rpId: account.rpId,
                  nonce: nonce,
                  deviceId: account.deviceId,
                  otp: otp,
                );
                if (signature.isNotEmpty) {
                  await _apiClient.postJson('/login/approve', {
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
      backgroundColor: const Color(0xFF1F1F1F),
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
                        apiClient: _apiClient,
                        onRegistered: _addTotpAccount,
                      ),
                    ),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.verified_user,
                label: 'Verify',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VerifyScreen(
                        apiClient: _apiClient,
                        accounts: List<TotpAccount>.from(_totpAccounts),
                      ),
                    ),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.shield_outlined,
                label: 'ZT Verify',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ZtVerifyScreen(
                        apiClient: _apiClient,
                        accounts: List<TotpAccount>.from(_totpAccounts),
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
                        apiClient: _apiClient,
                        accounts: List<TotpAccount>.from(_totpAccounts),
                        deviceCrypto: _deviceCrypto,
                      ),
                    ),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.delete_outline,
                label: 'Clear local accounts',
                onTap: () async {
                  await _store.clearAll();
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _totpAccounts.clear();
                  });
                  Navigator.of(context).pop();
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZT-Authenticator'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_done),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Sync placeholder')),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: CircleAvatar(
              backgroundColor: Color(0xFF2A2A2A),
              child: Text('P'),
            ),
          ),
        ],
      ),
      drawer: const _AppDrawer(),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            decoration: const InputDecoration(
              hintText: 'Search...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 16),
          if (accounts.isEmpty)
            const _EmptyState()
          else
            ...accounts.map((entry) => _AccountTile(entry: entry)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openActions,
        child: const Icon(Icons.add),
      ),
    );
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
  });

  final String issuer;
  final String account;
  final String secret;
  final String userId;
  final String rpId;
  final String deviceId;

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

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.issuer}: ${entry.account}',
                  style: const TextStyle(fontSize: 15, color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Text(
                  _formatCode(code),
                  style: const TextStyle(
                    fontSize: 36,
                    letterSpacing: 2,
                    color: Color(0xFFB3C7FF),
                  ),
                ),
                const Divider(color: Color(0xFF2A2A2A)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 4,
              color: const Color(0xFF7AA2FF),
              backgroundColor: const Color(0xFF2A2A2A),
            ),
          ),
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
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF1A1A1A),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            Text(
              'ZT-Authenticator',
              style: TextStyle(fontSize: 20, color: Colors.white),
            ),
            SizedBox(height: 24),
            _DrawerItem(icon: Icons.sync_alt, label: 'Transfer accounts'),
            _DrawerItem(icon: Icons.info_outline, label: 'How it works'),
            Divider(color: Color(0xFF2A2A2A)),
            _DrawerItem(icon: Icons.settings, label: 'Settings'),
            _DrawerItem(icon: Icons.feedback_outlined, label: 'Send feedback'),
            _DrawerItem(icon: Icons.help_outline, label: 'Help'),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white70)),
      onTap: () => Navigator.of(context).pop(),
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
        color: const Color(0xFF3A3A3A),
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
    required this.apiClient,
    required this.onRegistered,
  });

  final ApiClient apiClient;
  final ValueChanged<TotpAccount> onRegistered;

  @override
  State<TotpSetupScreen> createState() => _TotpSetupScreenState();
}

class _TotpSetupScreenState extends State<TotpSetupScreen> {
  final TotpStore _store = TotpStore();
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  String _status = '';
  List<String> _recoveryCodes = [];
  bool _loading = false;
  String _lastEmail = '';
  String _lastRpId = '';
  String _lastIssuer = '';
  String _lastAccount = '';
  String _lastUserId = '';
  String _lastDeviceId = '';

  @override
  void dispose() {
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

    final email = (payload['email'] as String?)?.trim() ?? '';
    final rpId = (payload['rp_id'] as String?)?.trim() ?? '';
    final rpDisplayName =
        (payload['rp_display_name'] as String?)?.trim() ?? rpId;
    final issuer = (payload['issuer'] as String?)?.trim() ?? '';
    final accountName = (payload['account_name'] as String?)?.trim() ?? '';
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

    setState(() {
      _loading = true;
      _status = 'Enrolling device...';
    });

    try {
      final publicKey = await _deviceCrypto.generateKeypair(rpId: rpId);
      if (publicKey.isEmpty) {
        setState(() {
          _status = 'Key generation failed.';
        });
        return;
      }
      final enrollPayload = {
        'email': email,
        'device_label': deviceLabel,
        'platform': 'android',
        'rp_id': rpId,
        'rp_display_name': rpDisplayName,
        'key_type': 'p256',
        'public_key': publicKey,
      };
      final enrollResponse = await widget.apiClient.postJson(
        '/enroll',
        enrollPayload,
      );
      if (enrollResponse.statusCode != 200) {
        setState(() {
          _status = 'Enrollment failed: ${enrollResponse.body}';
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

      final totpResponse = await widget.apiClient.postJson(
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
          );
          await _store.save(record);
          widget.onRegistered(TotpAccount.fromRecord(record));
        }
      }
      setState(() {
        _status = 'Enrollment complete.';
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
    return Scaffold(
      appBar: AppBar(title: const Text('TOTP Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Enrollment QR',
            subtitle: 'Scan a single QR to enroll and register TOTP.',
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _scanQr,
            child: Text(_loading ? 'Working...' : 'Scan Enrollment QR'),
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
          if (_recoveryCodes.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _SectionHeader(
              title: 'Recovery Codes',
              subtitle: 'Save these offline. They will not be shown again.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _recoveryCodes
                  .map(
                    (code) => Chip(
                      label: Text(code),
                      backgroundColor: const Color(0xFF2A2A2A),
                      labelStyle: const TextStyle(color: Colors.white),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// Verification flow: calls backend /totp/verify.
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({
    super.key,
    required this.apiClient,
    required this.accounts,
  });

  final ApiClient apiClient;
  final List<TotpAccount> accounts;

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

// ZT-TOTP verification flow with server challenge + placeholder signature.
class ZtVerifyScreen extends StatefulWidget {
  const ZtVerifyScreen({
    super.key,
    required this.apiClient,
    required this.accounts,
  });

  final ApiClient apiClient;
  final List<TotpAccount> accounts;

  @override
  State<ZtVerifyScreen> createState() => _ZtVerifyScreenState();
}

class _ZtVerifyScreenState extends State<ZtVerifyScreen> {
  String? _selectedKey;
  String _status = '';
  bool _loading = false;
  String _nonce = '';
  final TotpStore _store = TotpStore();
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  final _userIdController = TextEditingController();
  final _rpIdController = TextEditingController();
  final _deviceIdController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.accounts.isNotEmpty) {
      final first = widget.accounts.first;
      _selectedKey = _accountKey(first);
    }
    _syncControllers();
  }

  void _syncControllers() {
    final account = _currentAccount();
    if (account == null) {
      return;
    }
    _userIdController.text = account.userId;
    _rpIdController.text = account.rpId;
    _deviceIdController.text = account.deviceId;
  }

  TotpAccount? _currentAccount() {
    final key = _selectedKey;
    if (key == null) {
      return null;
    }
    for (final account in widget.accounts) {
      if (_accountKey(account) == key) {
        return account;
      }
    }
    return null;
  }

  String _accountKey(TotpAccount account) {
    return '${account.issuer}|${account.account}';
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _rpIdController.dispose();
    _deviceIdController.dispose();
    super.dispose();
  }

  Future<void> _saveIds() async {
    final account = _currentAccount();
    if (account == null) {
      return;
    }
    final updated = TotpAccount(
      issuer: account.issuer,
      account: account.account,
      secret: account.secret,
      userId: _userIdController.text.trim(),
      rpId: _rpIdController.text.trim(),
      deviceId: _deviceIdController.text.trim(),
    );
    await _store.save(updated.toRecord());
    setState(() {
      _selectedKey = _accountKey(updated);
      _status = 'Account IDs updated.';
    });
  }

  Future<void> _requestNonce() async {
    final deviceId = _deviceIdController.text.trim();
    final rpId = _rpIdController.text.trim();
    if (deviceId.isEmpty || rpId.isEmpty) {
      setState(() {
        _status = 'Missing device_id or rp_id.';
      });
      return;
    }
    try {
      final response = await widget.apiClient.postJson(
        '/zt/challenge',
        {'device_id': deviceId, 'rp_id': rpId},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _nonce = data['nonce'] as String? ?? '';
          _status = 'Nonce issued.';
        });
      } else {
        setState(() {
          _status = 'Challenge failed: ${response.body}';
        });
      }
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    }
  }

  Future<void> _submit() async {
    final account = _currentAccount();
    if (account == null) {
      setState(() {
        _status = 'No account selected.';
      });
      return;
    }
    if (_userIdController.text.trim().isEmpty ||
        _rpIdController.text.trim().isEmpty ||
        _deviceIdController.text.trim().isEmpty) {
      setState(() {
        _status = 'Missing user_id, rp_id, or device_id.';
      });
      return;
    }
    if (_nonce.isEmpty) {
      setState(() {
        _status = 'No nonce. Request a challenge first.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });

    try {
      final otp = account.currentCode();
      final signature = await _deviceCrypto.sign(
        rpId: _rpIdController.text.trim(),
        nonce: _nonce,
        deviceId: _deviceIdController.text.trim(),
        otp: otp,
      );
      if (signature.isEmpty) {
        setState(() {
          _status = 'Signature failed. Ensure device is enrolled.';
        });
        return;
      }
      final payload = {
        'user_id': _userIdController.text.trim(),
        'device_id': _deviceIdController.text.trim(),
        'rp_id': _rpIdController.text.trim(),
        'otp': otp,
        'device_proof': {
          'nonce': _nonce,
          'signature': signature,
        },
      };
      final response = await widget.apiClient.postJson('/zt/verify', payload);
      setState(() {
        _status = 'Status: ${response.statusCode}\n${response.body}';
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

  Future<void> _debugProof() async {
    final account = _currentAccount();
    if (account == null) {
      setState(() {
        _status = 'No account selected.';
      });
      return;
    }
    if (_userIdController.text.trim().isEmpty ||
        _rpIdController.text.trim().isEmpty ||
        _deviceIdController.text.trim().isEmpty) {
      setState(() {
        _status = 'Missing user_id, rp_id, or device_id.';
      });
      return;
    }
    if (_nonce.isEmpty) {
      setState(() {
        _status = 'No nonce. Request a challenge first.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });

    try {
      final otp = account.currentCode();
      final signature = await _deviceCrypto.sign(
        rpId: _rpIdController.text.trim(),
        nonce: _nonce,
        deviceId: _deviceIdController.text.trim(),
        otp: otp,
      );
      final payload = {
        'user_id': _userIdController.text.trim(),
        'device_id': _deviceIdController.text.trim(),
        'rp_id': _rpIdController.text.trim(),
        'otp': otp,
        'device_proof': {
          'nonce': _nonce,
          'signature': signature,
        },
      };
      final response = await widget.apiClient.postJson('/zt/debug-proof', payload);
      setState(() {
        _status = 'Debug: ${response.statusCode}\n${response.body}';
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
    final accounts = widget.accounts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZT Verify'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'ZT-TOTP Verification',
            subtitle: 'Uses server nonce + device-bound signature.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _selectedKey,
            items: accounts
                .map(
                  (account) => DropdownMenuItem(
                    value: _accountKey(account),
                    child: Text('${account.issuer}: ${account.account}'),
                  ),
                )
                .toList(),
            onChanged: (value) {
              setState(() {
                _selectedKey = value;
                _syncControllers();
              });
            },
            decoration: const InputDecoration(
              labelText: 'Account',
            ),
          ),
          const SizedBox(height: 16),
          _Field(label: 'User ID', controller: _userIdController),
          _Field(label: 'RP ID', controller: _rpIdController),
          _Field(label: 'Device ID', controller: _deviceIdController),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _saveIds,
            child: const Text('Save IDs'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _requestNonce,
            child: const Text('Request Nonce'),
          ),
          const SizedBox(height: 8),
          if (_nonce.isNotEmpty)
            Text('Nonce: $_nonce', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: Text(_loading ? 'Submitting...' : 'ZT Verify Now'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _loading ? null : _debugProof,
            child: const Text('Debug Proof'),
          ),
          const SizedBox(height: 16),
          Text(_status, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class LoginApprovalsScreen extends StatefulWidget {
  const LoginApprovalsScreen({
    super.key,
    required this.apiClient,
    required this.accounts,
    required this.deviceCrypto,
  });

  final ApiClient apiClient;
  final List<TotpAccount> accounts;
  final DeviceCrypto deviceCrypto;

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

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      for (final account in widget.accounts) {
        if (account.userId.isEmpty) {
          continue;
        }
        final response = await widget.apiClient.get(
          '/login/pending?user_id=${account.userId}',
        );
        if (response.statusCode != 200) {
          continue;
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['status'] == 'pending') {
          setState(() {
            _pending = data;
          });
          return;
        }
      }
      setState(() {
        _pending = null;
        _status = 'No pending logins.';
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
      );
      final response = await widget.apiClient.postJson('/login/approve', {
        'login_id': loginId,
        'device_id': account.deviceId,
        'rp_id': account.rpId,
        'otp': otp,
        'nonce': nonce,
        'signature': signature,
      });
      setState(() {
        _status = 'Approve: ${response.statusCode} ${response.body}';
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
    final loginId = pending['login_id'] as String? ?? '';
    if (loginId.isEmpty) {
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final response = await widget.apiClient.postJson('/login/deny', {
        'login_id': loginId,
        'reason': 'user_denied',
      });
      setState(() {
        _status = 'Denied: ${response.statusCode} ${response.body}';
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
                    onPressed: _loading ? null : _deny,
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
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
          ElevatedButton(
            onPressed: _loading ? null : _refresh,
            child: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

class _VerifyScreenState extends State<VerifyScreen> {
  String? _selectedKey;
  String _status = '';
  bool _loading = false;
  final TotpStore _store = TotpStore();
  final _userIdController = TextEditingController();
  final _rpIdController = TextEditingController();
  String _debug = '';

  @override
  void initState() {
    super.initState();
    if (widget.accounts.isNotEmpty) {
      final first = widget.accounts.first;
      _selectedKey = _accountKey(first);
    }
    _syncControllers();
  }

  void _syncControllers() {
    final account = _currentAccount();
    if (account == null) {
      return;
    }
    _userIdController.text = account.userId;
    _rpIdController.text = account.rpId;
  }

  TotpAccount? _currentAccount() {
    final key = _selectedKey;
    if (key == null) {
      return null;
    }
    for (final account in widget.accounts) {
      if (_accountKey(account) == key) {
        return account;
      }
    }
    return null;
  }

  String _accountKey(TotpAccount account) {
    return '${account.issuer}|${account.account}';
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _rpIdController.dispose();
    super.dispose();
  }

  Future<void> _saveIds() async {
    final account = _currentAccount();
    if (account == null) {
      return;
    }
    final updated = TotpAccount(
      issuer: account.issuer,
      account: account.account,
      secret: account.secret,
      userId: _userIdController.text.trim(),
      rpId: _rpIdController.text.trim(),
      deviceId: account.deviceId,
    );
    await _store.save(updated.toRecord());
    setState(() {
      _selectedKey = _accountKey(updated);
      _status = 'Account IDs updated.';
    });
  }

  Future<void> _compareWithServer() async {
    final account = _currentAccount();
    if (account == null) {
      setState(() {
        _debug = 'No account selected.';
      });
      return;
    }
    final userId = _userIdController.text.trim();
    final rpId = _rpIdController.text.trim();
    if (userId.isEmpty || rpId.isEmpty) {
      setState(() {
        _debug = 'Missing user_id or rp_id.';
      });
      return;
    }

    final localSecret = account.secret.replaceAll(' ', '').toUpperCase();
    try {
      final response = await widget.apiClient.get(
        '/totp/debug-state?user_id=$userId&rp_id=$rpId',
      );
      final serverData = jsonDecode(response.body) as Map<String, dynamic>;
      final serverOtp = serverData['otp'] as String? ?? 'n/a';
      final serverTime = serverData['server_time'] as int? ?? 0;
      final localNow = DateTime.now().millisecondsSinceEpoch;
      final localOtpNow = account.currentCode();
      final localOtpAtServerTime = generateTotp(
        localSecret,
        timeMillis: serverTime * 1000,
      );
      final driftSeconds = (localNow ~/ 1000) - serverTime;

      final secretResponse = await widget.apiClient.get(
        '/totp/debug-secret?user_id=$userId&rp_id=$rpId',
      );
      final secretData =
          jsonDecode(secretResponse.body) as Map<String, dynamic>;
      final serverSecret =
          (secretData['secret'] as String? ?? '').replaceAll(' ', '').toUpperCase();
      final secretMatch = serverSecret == localSecret;

      setState(() {
        _debug = 'Local OTP: $localOtpNow\n'
            'Local@ServerTime: $localOtpAtServerTime\n'
            'Server OTP: $serverOtp\n'
            'Drift (s): $driftSeconds\n'
            'Secret match: $secretMatch';
      });
    } catch (error) {
      setState(() {
        _debug = 'Debug error: $error';
      });
    }
  }

  Future<void> _submit() async {
    final account = _currentAccount();
    if (account == null) {
      setState(() {
        _status = 'No account selected.';
      });
      return;
    }
    if (_userIdController.text.trim().isEmpty ||
        _rpIdController.text.trim().isEmpty) {
      setState(() {
        _status = 'Missing user_id or rp_id for this account.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });

    final payload = {
      'user_id': _userIdController.text.trim(),
      'rp_id': _rpIdController.text.trim(),
      'otp': account.currentCode(),
    };

    try {
      final response = await widget.apiClient.postJson('/totp/verify', payload);
      setState(() {
        _status = 'Status: ${response.statusCode}\n${response.body}';
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
    final accounts = widget.accounts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Verification Payload',
            subtitle: 'Uses current code from the selected account.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _selectedKey,
            items: accounts
                .map(
                  (account) => DropdownMenuItem(
                    value: _accountKey(account),
                    child: Text('${account.issuer}: ${account.account}'),
                  ),
                )
                .toList(),
            onChanged: (value) {
              setState(() {
                _selectedKey = value;
                _syncControllers();
              });
            },
            decoration: const InputDecoration(
              labelText: 'Account',
            ),
          ),
          const SizedBox(height: 16),
          _Field(label: 'User ID', controller: _userIdController),
          _Field(label: 'RP ID', controller: _rpIdController),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _saveIds,
            child: const Text('Save IDs'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _compareWithServer,
            child: const Text('Compare With Server'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: Text(_loading ? 'Submitting...' : 'Verify Now'),
          ),
          const SizedBox(height: 16),
          Text(_status, style: const TextStyle(color: Colors.white70)),
          if (_debug.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_debug, style: const TextStyle(color: Colors.white70)),
          ],
        ],
      ),
    );
  }
}

// Consistent form field styling.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller});

  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF1F1F1F),
        ),
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
