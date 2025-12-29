import CryptoKit
import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "zt_device_crypto",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterError(code: "unavailable", message: "Host unavailable", details: nil))
          return
        }
        switch call.method {
        case "generateKeypair":
          guard
            let args = call.arguments as? [String: Any],
            let rpId = args["rp_id"] as? String
          else {
            result(FlutterError(code: "bad_args", message: "rp_id is required", details: nil))
            return
          }
          let keyId = args["key_id"] as? String ?? ""
          do {
            let key = try self.getOrCreateKey(rpId: rpId, keyId: keyId)
            let pubData = key.publicKey.derRepresentation
            result(pubData.base64EncodedString())
          } catch {
            result(FlutterError(code: "keygen_failed", message: error.localizedDescription, details: nil))
          }
        case "sign":
          guard
            let args = call.arguments as? [String: Any],
            let rpId = args["rp_id"] as? String,
            let nonce = args["nonce"] as? String,
            let deviceId = args["device_id"] as? String,
            let otp = args["otp"] as? String
          else {
            result(FlutterError(code: "bad_args", message: "missing sign fields", details: nil))
            return
          }
          let keyId = args["key_id"] as? String ?? ""
          do {
            guard let key = try self.loadKey(rpId: rpId, keyId: keyId) else {
              result(FlutterError(code: "key_missing", message: "device key not found", details: nil))
              return
            }
            let message = "\(nonce)|\(deviceId)|\(rpId)|\(otp)"
            let messageData = message.data(using: .utf8) ?? Data()
            let signature = try key.signature(for: messageData).derRepresentation
            result(signature.base64EncodedString())
          } catch {
            result(FlutterError(code: "sign_failed", message: error.localizedDescription, details: nil))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func keyTag(for rpId: String, keyId: String) -> Data {
    let base = keyId.isEmpty ? rpId : keyId
    return "zt_device_crypto.\(base)".data(using: .utf8) ?? Data()
  }

  private func loadKey(rpId: String, keyId: String) throws -> P256.Signing.PrivateKey? {
    let tag = keyTag(for: rpId, keyId: keyId)
    let query: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnData: true
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = item as? Data else {
      throw NSError(domain: "Keychain", code: Int(status), userInfo: nil)
    }
    return try P256.Signing.PrivateKey(rawRepresentation: data)
  }

  private func saveKey(_ key: P256.Signing.PrivateKey, rpId: String, keyId: String) throws {
    let tag = keyTag(for: rpId, keyId: keyId)
    let deleteQuery: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData: key.rawRepresentation
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status != errSecSuccess {
      throw NSError(domain: "Keychain", code: Int(status), userInfo: nil)
    }
  }

  private func getOrCreateKey(rpId: String, keyId: String) throws -> P256.Signing.PrivateKey {
    if let existing = try loadKey(rpId: rpId, keyId: keyId) {
      return existing
    }
    let newKey = P256.Signing.PrivateKey()
    try saveKey(newKey, rpId: rpId, keyId: keyId)
    return newKey
  }
}
