import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_resolver.dart';

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
    // Gate on kDebugMode, not `dart.vm.product` (which is false in BOTH
    // debug and profile builds): a profile build can be installed on a real
    // device and distributed to testers, and dart.vm.product==false there
    // would otherwise silently keep the TLS bypass live outside an actual
    // attached debug session.
    final httpClient = HttpClient();
    httpClient.findProxy = (_) => 'DIRECT';
    httpClient.connectionFactory = (uri, proxyHost, proxyPort) async {
      final port = uri.hasPort
          ? uri.port
          : uri.scheme.toLowerCase() == 'https'
              ? 443
              : 80;
      List<InternetAddress> addresses;
      try {
        addresses = await InternetAddress.lookup(uri.host);
      } on SocketException {
        addresses = await NetworkResolver.resolveHost(uri.host);
      }
      if (addresses.isEmpty) {
        throw SocketException(
          'No DNS server resolved ${uri.host}',
          address: InternetAddress.tryParse(uri.host),
          port: port,
        );
      }

      Future<ConnectionTask<Socket>> connect(List<InternetAddress> candidates) async {
        Object? failure;
        for (final address in candidates) {
          final task = await Socket.startConnect(address, port);
          try {
            final socket = await task.socket.timeout(const Duration(seconds: 2));
            return ConnectionTask.fromSocket(Future.value(socket), task.cancel);
          } catch (error) {
            task.cancel();
            failure = error;
          }
        }
        throw failure ?? const SocketException('No reachable server address');
      }
      ConnectionTask<Socket> socketTask;
      try {
        socketTask = await connect(addresses);
      } catch (_) {
        // Retry configured DNS after a stale system-cache address fails.
        final refreshed = await NetworkResolver.resolveHost(uri.host);
        socketTask = await connect(refreshed);
      }
      if (uri.scheme.toLowerCase() != 'https') {
        return socketTask;
      }
      final secureSocket = socketTask.socket.then(
        (socket) => SecureSocket.secure(
          socket,
          host: uri.host,
          onBadCertificate: allowInsecureTls && kDebugMode ? (_) => true : null,
        ),
      );
      return ConnectionTask.fromSocket(secureSocket, socketTask.cancel);
    };
    return IOClient(httpClient);
  }

  Future<http.Response> get(String path, {Map<String, String>? headers}) {
    final uri = Uri.parse('$baseUrl$path');
    _requireSecureTransport(uri);
    return _client.get(uri, headers: headers);
  }

  Future<http.Response> postJson(String path, Map<String, dynamic> body) {
    final uri = Uri.parse('$baseUrl$path');
    _requireSecureTransport(uri);
    return _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
  }

  static void _requireSecureTransport(Uri uri) {
    if (!kDebugMode && uri.scheme.toLowerCase() != 'https') {
      throw StateError('Only debug builds may use plain HTTP.');
    }
  }

  void close() {
    _client.close();
  }
}
