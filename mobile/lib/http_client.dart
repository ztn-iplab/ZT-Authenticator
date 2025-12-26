import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiClient {
  ApiClient({http.Client? client, required this.baseUrl})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

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
