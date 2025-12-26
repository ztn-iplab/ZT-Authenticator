package com.example.zt_totp_mobile

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class MainActivity : FlutterActivity() {
    private val channelName = "zt_device_crypto"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "generateKeypair" -> {
                        val rpId = call.argument<String>("rp_id") ?: ""
                        if (rpId.isBlank()) {
                            result.error("bad_args", "rp_id is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val publicKey = generateKeypair(rpId)
                            result.success(publicKey)
                        } catch (error: Exception) {
                            result.error("keygen_failed", error.toString(), null)
                        }
                    }
                    "sign" -> {
                        val rpId = call.argument<String>("rp_id") ?: ""
                        val nonce = call.argument<String>("nonce") ?: ""
                        val deviceId = call.argument<String>("device_id") ?: ""
                        val otp = call.argument<String>("otp") ?: ""
                        if (rpId.isBlank() || nonce.isBlank() || deviceId.isBlank() || otp.isBlank()) {
                            result.error("bad_args", "rp_id, nonce, device_id, and otp are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val signature = signPayload(rpId, nonce, deviceId, otp)
                            result.success(signature)
                        } catch (error: Exception) {
                            result.error("sign_failed", error.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun aliasForRp(rpId: String): String {
        val sanitized = rpId.replace(Regex("[^a-zA-Z0-9._-]"), "_")
        return "zt_totp_$sanitized"
    }

    private fun generateKeypair(rpId: String): String {
        val alias = aliasForRp(rpId)
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)

        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }

        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore",
        )
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .build()
        keyPairGenerator.initialize(spec)
        keyPairGenerator.generateKeyPair()

        val entry = keyStore.getEntry(alias, null) as KeyStore.PrivateKeyEntry
        val publicKey = entry.certificate.publicKey
        val encoded = publicKey.encoded
        return Base64.encodeToString(encoded, Base64.NO_WRAP)
    }

    private fun signPayload(rpId: String, nonce: String, deviceId: String, otp: String): String {
        val alias = aliasForRp(rpId)
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        val entry = keyStore.getEntry(alias, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("No key for rp_id. Enroll first.")

        val message = "$nonce|$deviceId|$rpId|$otp".toByteArray(Charsets.UTF_8)
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(entry.privateKey)
        signature.update(message)
        val signed = signature.sign()
        return Base64.encodeToString(signed, Base64.NO_WRAP)
    }
}
