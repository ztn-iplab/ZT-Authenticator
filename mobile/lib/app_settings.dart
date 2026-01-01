import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppSettings {
  static const _storage = FlutterSecureStorage();
  static const _apiBaseUrlKey = 'settings:api_base_url';
  static const _loginPollingKey = 'settings:login_polling';
  static const _pendingEnrollmentKey = 'settings:pending_enrollment';
  static const _allowInsecureKey = 'settings:allow_insecure_tls';
  static const _allowHttpDevKey = 'settings:allow_http_dev';
  static const _feedbackUrlKey = 'settings:feedback_url';

  Future<String?> loadApiBaseUrl() async {
    final value = await _storage.read(key: _apiBaseUrlKey);
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }

  Future<void> saveApiBaseUrl(String? value) async {
    if (value == null || value.trim().isEmpty) {
      await _storage.delete(key: _apiBaseUrlKey);
      return;
    }
    await _storage.write(key: _apiBaseUrlKey, value: value.trim());
  }

  Future<bool> loadLoginPollingEnabled() async {
    final value = await _storage.read(key: _loginPollingKey);
    if (value == null) {
      return true;
    }
    return value.toLowerCase() == 'true';
  }

  Future<void> saveLoginPollingEnabled(bool enabled) async {
    await _storage.write(key: _loginPollingKey, value: enabled.toString());
  }

  Future<bool> loadAllowInsecureTls() async {
    final value = await _storage.read(key: _allowInsecureKey);
    if (value == null) {
      return false;
    }
    return value.toLowerCase() == 'true';
  }

  Future<void> saveAllowInsecureTls(bool enabled) async {
    await _storage.write(key: _allowInsecureKey, value: enabled.toString());
  }

  Future<bool> loadAllowHttpDev() async {
    final value = await _storage.read(key: _allowHttpDevKey);
    if (value == null) {
      return false;
    }
    return value.toLowerCase() == 'true';
  }

  Future<void> saveAllowHttpDev(bool enabled) async {
    await _storage.write(key: _allowHttpDevKey, value: enabled.toString());
  }

  Future<String?> loadFeedbackUrl() async {
    final value = await _storage.read(key: _feedbackUrlKey);
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }

  Future<void> saveFeedbackUrl(String? value) async {
    if (value == null || value.trim().isEmpty) {
      await _storage.delete(key: _feedbackUrlKey);
      return;
    }
    await _storage.write(key: _feedbackUrlKey, value: value.trim());
  }

  Future<void> savePendingEnrollment(String payloadJson) async {
    await _storage.write(key: _pendingEnrollmentKey, value: payloadJson);
  }

  Future<String?> loadPendingEnrollment() async {
    return _storage.read(key: _pendingEnrollmentKey);
  }

  Future<void> clearPendingEnrollment() async {
    await _storage.delete(key: _pendingEnrollmentKey);
  }
}
