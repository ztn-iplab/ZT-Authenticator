import 'dart:io';

import 'package:flutter/services.dart';

class NetworkResolver {
  static const MethodChannel _channel = MethodChannel('zt_network_resolver');

  static Future<List<InternetAddress>> resolveHost(String host) async {
    if (!Platform.isAndroid) {
      return const [];
    }
    try {
      final values = await _channel.invokeListMethod<String>(
        'resolveHost',
        {'host': host},
      );
      return (values ?? const <String>[])
          .map(InternetAddress.tryParse)
          .whereType<InternetAddress>()
          .toList(growable: false);
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }
}
