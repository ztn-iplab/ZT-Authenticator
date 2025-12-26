import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'device_crypto.dart';
import 'http_client.dart';
import 'qr_scanner_screen.dart';
import 'totp.dart';
import 'totp_store.dart';

// Android emulator reaches host localhost via 10.0.2.2.
const String apiBaseUrl = 'http://10.0.2.2:8000';

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

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(baseUrl: apiBaseUrl);
    _loadAccounts();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
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
    _apiClient.close();
    super.dispose();
  }

  void _addTotpAccount(TotpAccount account) {
    setState(() {
      _totpAccounts.add(account);
    });
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
  final _emailController = TextEditingController(text: 'alice@example.com');
  final _userIdController =
      TextEditingController(text: '00000000-0000-0000-0000-000000000000');
  final _rpIdController = TextEditingController(text: 'example.com');
  final _rpDisplayNameController = TextEditingController(text: 'Example RP');
  final _deviceLabelController = TextEditingController(text: 'Research Phone');
  final _deviceIdController = TextEditingController();
  final _accountController = TextEditingController(text: 'alice@example.com');
  final _issuerController = TextEditingController(text: 'Example');
  String _status = '';
  List<String> _recoveryCodes = [];
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _userIdController.dispose();
    _rpIdController.dispose();
    _rpDisplayNameController.dispose();
    _deviceLabelController.dispose();
    _deviceIdController.dispose();
    _accountController.dispose();
    _issuerController.dispose();
    super.dispose();
  }

  Future<void> _createUser() async {
    setState(() {
      _loading = true;
      _status = '';
    });

    final payload = {'email': _emailController.text.trim()};

    try {
      final response = await widget.apiClient.postJson('/users', payload);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _userIdController.text = data['id'] as String;
          _accountController.text = data['email'] as String;
          _status = 'User created.';
        });
      } else {
        setState(() {
          _status = 'Create user failed: ${response.body}';
        });
      }
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

  Future<void> _register() async {
    setState(() {
      _loading = true;
      _status = '';
    });

    final payload = {
      'user_id': _userIdController.text.trim(),
      'rp_id': _rpIdController.text.trim(),
      'account_name': _accountController.text.trim(),
      'issuer': _issuerController.text.trim(),
    };

    try {
      final response = await widget.apiClient.postJson(
        '/totp/register',
        payload,
      );
      setState(() {
        _status = 'Status: ${response.statusCode}';
      });
      if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        _recoveryCodes =
            (data['recovery_codes'] as List<dynamic>).cast<String>();
      });
      if (data['otpauth_uri'] != null) {
          final uri = Uri.parse(data['otpauth_uri'] as String);
          final secret = uri.queryParameters['secret'] ?? '';
          final issuer = uri.queryParameters['issuer'] ?? _issuerController.text;
          final label = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
          if (secret.isNotEmpty) {
            final record = TotpRecord(
              issuer: issuer,
              account: label,
              secret: secret,
              userId: _userIdController.text.trim(),
              rpId: _rpIdController.text.trim(),
              deviceId: _deviceIdController.text.trim(),
            );
            await _store.save(record);
            widget.onRegistered(TotpAccount.fromRecord(record));
          }
        }
      }
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

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (result == null || result.isEmpty) {
      return;
    }

    final uri = Uri.tryParse(result);
    if (uri == null || uri.scheme != 'otpauth') {
      setState(() {
        _status = 'Scanned QR is not an otpauth URI.';
      });
      return;
    }

    final label = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
    final issuer = uri.queryParameters['issuer'] ?? '';
    final secret = uri.queryParameters['secret'] ?? '';

    setState(() {
      _accountController.text = label;
      _issuerController.text = issuer;
      _status = 'QR scanned. Ready to register.';
    });

    if (secret.isNotEmpty) {
      final record = TotpRecord(
        issuer: issuer,
        account: label,
        secret: secret,
        userId: _userIdController.text.trim(),
        rpId: _rpIdController.text.trim(),
        deviceId: _deviceIdController.text.trim(),
      );
      await _store.save(record);
      widget.onRegistered(TotpAccount.fromRecord(record));
    }
  }

  Future<void> _ztEnroll() async {
    final email = _emailController.text.trim();
    final rpId = _rpIdController.text.trim();
    if (email.isEmpty || rpId.isEmpty) {
      setState(() {
        _status = 'Email and RP ID are required for ZT enrollment.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });

    try {
      final publicKey = await _deviceCrypto.generateKeypair(rpId: rpId);
      if (publicKey.isEmpty) {
        setState(() {
          _status = 'Key generation failed.';
        });
        return;
      }
      final payload = {
        'email': email,
        'device_label': _deviceLabelController.text.trim().isEmpty
            ? 'Android Device'
            : _deviceLabelController.text.trim(),
        'platform': 'android',
        'rp_id': rpId,
        'rp_display_name': _rpDisplayNameController.text.trim().isEmpty
            ? rpId
            : _rpDisplayNameController.text.trim(),
        'key_type': 'p256',
        'public_key': publicKey,
      };
      final response = await widget.apiClient.postJson('/enroll', payload);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _userIdController.text = data['user']['id'] as String;
          _deviceIdController.text = data['device']['id'] as String;
          _accountController.text = data['user']['email'] as String;
          _status = 'ZT enrollment complete.';
        });
      } else {
        setState(() {
          _status = 'Enrollment failed: ${response.body}';
        });
      }
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
            title: 'ZT Enrollment',
            subtitle: 'Generate a device keypair and enroll with the server.',
          ),
          const SizedBox(height: 16),
          _Field(label: 'Email', controller: _emailController),
          _Field(label: 'RP ID', controller: _rpIdController),
          _Field(label: 'RP Display Name', controller: _rpDisplayNameController),
          _Field(label: 'Device Label', controller: _deviceLabelController),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _loading ? null : _ztEnroll,
            child: Text(_loading ? 'Enrolling...' : 'ZT Enroll Device'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _loading ? null : _createUser,
            child: const Text('Create User'),
          ),
          const SizedBox(height: 16),
          _Field(label: 'User ID', controller: _userIdController),
          _Field(label: 'Device ID', controller: _deviceIdController),
          _Field(label: 'Account Name', controller: _accountController),
          _Field(label: 'Issuer', controller: _issuerController),
          const SizedBox(height: 12),
          const _SectionHeader(
            title: 'TOTP Registration',
            subtitle: 'Scan a QR or register from the server.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _scanQr,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _loading ? null : _register,
                  child: Text(_loading ? 'Registering...' : 'Register TOTP'),
                ),
              ),
            ],
          ),
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
