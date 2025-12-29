import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class ApiClient {
  ApiClient({
    http.Client? client,
    required this.baseUrl,
    this.allowInsecureTls = false,
  }) : _client = client ?? _buildClient(allowInsecureTls);

  final http.Client _client;
  final String baseUrl;
  final bool allowInsecureTls;

  static http.Client _buildClient(bool allowInsecureTls) {
    if (!allowInsecureTls) {
      return http.Client();
    }
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return IOClient(httpClient);
  }

  Future<http.Response> get(String path) {
    final uri = Uri.parse('$baseUrl$path');
    return _client.get(uri);
  }

  Future<http.Response> postJson(String path, Map<String, dynamic> body) {
    final uri = Uri.parse('$baseUrl$path');
    return _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
  }

  void close() {
    _client.close();
  }
}
