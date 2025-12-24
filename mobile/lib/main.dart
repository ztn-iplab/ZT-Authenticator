import 'package:flutter/material.dart';

import 'http_client.dart';

void main() {
  runApp(const ZtTotpApp());
}

class ZtTotpApp extends StatelessWidget {
  const ZtTotpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZT-TOTP',
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ApiClient _apiClient;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(baseUrl: 'http://localhost:8000');
  }

  @override
  void dispose() {
    _apiClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZT-TOTP'),
      ),
      body: const Center(
        child: Text('ZT-TOTP mobile scaffold'),
      ),
    );
  }
}
