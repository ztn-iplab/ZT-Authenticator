import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

Uint8List _base32Decode(String input) {
  final cleaned = input.replaceAll('=', '').replaceAll(' ', '').toUpperCase();
  var bits = 0;
  var value = 0;
  final output = <int>[];

  for (final rune in cleaned.runes) {
    final char = String.fromCharCode(rune);
    final index = _base32Alphabet.indexOf(char);
    if (index < 0) {
      continue;
    }
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      output.add((value >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }

  return Uint8List.fromList(output);
}

String generateTotp(
  String secret, {
  int interval = 30,
  int digits = 6,
  int? timeMillis,
}) {
  final key = _base32Decode(secret);
  final millis = timeMillis ?? DateTime.now().millisecondsSinceEpoch;
  final counter = (millis ~/ 1000) ~/ interval;

  final counterBytes = Uint8List(8);
  var value = counter;
  for (var i = 7; i >= 0; i--) {
    counterBytes[i] = value & 0xFF;
    value = value >> 8;
  }

  final hmac = Hmac(sha1, key).convert(counterBytes).bytes;
  final offset = hmac.last & 0x0F;
  final binary = ((hmac[offset] & 0x7F) << 24) |
      ((hmac[offset + 1] & 0xFF) << 16) |
      ((hmac[offset + 2] & 0xFF) << 8) |
      (hmac[offset + 3] & 0xFF);

  final mod = pow(10, digits).toInt();
  final code = (binary % mod).toString().padLeft(digits, '0');
  return code;
}
