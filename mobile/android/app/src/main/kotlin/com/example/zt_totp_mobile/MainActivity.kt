package com.example.zt_totp_mobile

import android.content.Context
import android.net.ConnectivityManager
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
import java.net.Inet4Address
import java.time.Duration
import java.util.concurrent.Executors
import org.xbill.DNS.ARecord
import org.xbill.DNS.Lookup
import org.xbill.DNS.Name
import org.xbill.DNS.SimpleResolver
import org.xbill.DNS.Type

class MainActivity : FlutterActivity() {
    private val channelName = "zt_device_crypto"
    private val networkChannelName = "zt_network_resolver"
    private val networkExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "generateKeypair" -> {
                        val rpId = call.argument<String>("rp_id") ?: ""
                        val keyId = call.argument<String>("key_id") ?: ""
                        if (rpId.isBlank()) {
                            result.error("bad_args", "rp_id is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val publicKey = generateKeypair(rpId, keyId)
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
                        val keyId = call.argument<String>("key_id") ?: ""
                        if (rpId.isBlank() || nonce.isBlank() || deviceId.isBlank() || otp.isBlank()) {
                            result.error("bad_args", "rp_id, nonce, device_id, and otp are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val signature = signPayload(rpId, nonce, deviceId, otp, keyId)
                            result.success(signature)
                        } catch (error: Exception) {
                            result.error("sign_failed", error.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkChannelName)
            .setMethodCallHandler { call, methodResult ->
                when (call.method) {
                    "resolveHost" -> {
                        val host = call.argument<String>("host")?.trim().orEmpty()
                        if (host.isBlank()) {
                            methodResult.error("bad_args", "host is required", null)
                            return@setMethodCallHandler
                        }
                        networkExecutor.execute {
                            try {
                                val addresses = resolveViaActiveIpv4Dns(host)
                                runOnUiThread { methodResult.success(addresses) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    methodResult.error("dns_failed", error.toString(), null)
                                }
                            }
                        }
                    }
                    else -> methodResult.notImplemented()
                }
            }
    }

    private fun resolveViaActiveIpv4Dns(host: String): List<String> {
        val connectivity =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork
            ?: throw IllegalStateException("No active Android network")
        val dnsServers = connectivity.getLinkProperties(network)?.dnsServers
            ?.filterIsInstance<Inet4Address>()
            .orEmpty()
        if (dnsServers.isEmpty()) {
            throw IllegalStateException("The active network has no IPv4 DNS server")
        }

        val absoluteName = Name.fromString("${host.trimEnd('.')}.")
        for (server in dnsServers) {
            try {
                val resolver = SimpleResolver(server.hostAddress)
                resolver.setTimeout(Duration.ofMillis(1200))
                val lookup = Lookup(absoluteName, Type.A)
                lookup.setResolver(resolver)
                val addresses = lookup.run()
                    ?.filterIsInstance<ARecord>()
                    ?.mapNotNull { it.address.hostAddress }
                    ?.distinct()
                    .orEmpty()
                if (addresses.isNotEmpty()) {
                    return addresses
                }
            } catch (_: Exception) {
                continue
            }
        }
        throw IllegalStateException("No IPv4 DNS server resolved $host")
    }

    override fun onDestroy() {
        networkExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun aliasForKey(rpId: String, keyId: String): String {
        val base = if (keyId.isNotBlank()) keyId else rpId
        val sanitized = base.replace(Regex("[^a-zA-Z0-9._-]"), "_")
        return "zt_totp_$sanitized"
    }

    private fun generateKeypair(rpId: String, keyId: String): String {
        val alias = aliasForKey(rpId, keyId)
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

    private fun signPayload(rpId: String, nonce: String, deviceId: String, otp: String, keyId: String): String {
        val alias = aliasForKey(rpId, keyId)
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
