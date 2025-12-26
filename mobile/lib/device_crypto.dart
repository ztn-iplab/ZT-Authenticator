import 'package:flutter/services.dart';

class DeviceCrypto {
  static const MethodChannel _channel = MethodChannel('zt_device_crypto');

  Future<String> generateKeypair({required String rpId}) async {
    final result = await _channel.invokeMethod<String>(
      'generateKeypair',
      {'rp_id': rpId},
    );
    return result ?? '';
  }

  Future<String> sign({
    required String rpId,
    required String nonce,
    required String deviceId,
    required String otp,
  }) async {
    final result = await _channel.invokeMethod<String>(
      'sign',
      {
        'rp_id': rpId,
        'nonce': nonce,
        'device_id': deviceId,
        'otp': otp,
      },
    );
    return result ?? '';
  }
}
