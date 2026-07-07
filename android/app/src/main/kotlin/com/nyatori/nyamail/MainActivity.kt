package com.nyatori.nyamail

import android.app.Activity
import android.content.IntentSender
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.core.content.FileProvider
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val GOOGLE_AUTHORIZATION_REQUEST_CODE = 7204
    }

    private var oauthCallbackChannel: MethodChannel? = null
    private var pendingOAuthRedirect: String? = null
    private var pendingGoogleAuthorizationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nyatori.nyamail/update_installer"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "APK path is required.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        installApk(path)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "install_failed",
                            error.message ?: "Could not open Android package installer.",
                            null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nyatori.nyamail/google_authorization"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "authorizeGmail" -> {
                    val rawScopes = call.argument<List<String>>("scopes") ?: emptyList()
                    authorizeGmail(rawScopes, result)
                }
                else -> result.notImplemented()
            }
        }
        oauthCallbackChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nyatori.nyamail/oauth_callback"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeInitialOAuthRedirect" -> {
                        result.success(pendingOAuthRedirect)
                        pendingOAuthRedirect = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        handleOAuthRedirect(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleOAuthRedirect(intent)
    }

    @Deprecated("Deprecated in Android framework, but still used by Google Identity Services here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != GOOGLE_AUTHORIZATION_REQUEST_CODE) return

        val result = pendingGoogleAuthorizationResult ?: return
        pendingGoogleAuthorizationResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.error("authorization_cancelled", "Google authorization was cancelled.", null)
            return
        }

        try {
            val authorizationResult = Identity.getAuthorizationClient(this)
                .getAuthorizationResultFromIntent(data)
            result.success(googleAuthorizationPayload(authorizationResult))
        } catch (error: ApiException) {
            result.error(
                "authorization_failed",
                error.localizedMessage ?: "Google authorization failed.",
                error.statusCode
            )
        } catch (error: Exception) {
            result.error(
                "authorization_failed",
                error.localizedMessage ?: "Google authorization failed.",
                null
            )
        }
    }

    private fun installApk(path: String) {
        val apk = File(path)
        if (!apk.isFile || apk.extension.lowercase() != "apk") {
            throw IllegalArgumentException("APK file was not found: $path")
        }
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            apk
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun handleOAuthRedirect(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val redirect = intent.dataString ?: return
        val channel = oauthCallbackChannel
        if (channel == null) {
            pendingOAuthRedirect = redirect
            return
        }
        channel.invokeMethod("onOAuthRedirect", redirect)
    }

    private fun authorizeGmail(rawScopes: List<String>, result: MethodChannel.Result) {
        if (pendingGoogleAuthorizationResult != null) {
            result.error(
                "authorization_in_progress",
                "Another Google authorization request is already in progress.",
                null
            )
            return
        }
        val scopes = rawScopes
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { Scope(it) }
        if (scopes.isEmpty()) {
            result.error("missing_scopes", "Google authorization scopes are required.", null)
            return
        }

        val request = AuthorizationRequest.builder()
            .setRequestedScopes(scopes)
            .build()

        Identity.getAuthorizationClient(this)
            .authorize(request)
            .addOnSuccessListener { authorizationResult ->
                if (authorizationResult.hasResolution()) {
                    try {
                        pendingGoogleAuthorizationResult = result
                        startIntentSenderForResult(
                            authorizationResult.pendingIntent!!.intentSender,
                            GOOGLE_AUTHORIZATION_REQUEST_CODE,
                            null,
                            0,
                            0,
                            0
                        )
                    } catch (error: IntentSender.SendIntentException) {
                        pendingGoogleAuthorizationResult = null
                        result.error(
                            "authorization_resolution_failed",
                            error.localizedMessage ?: "Could not open Google authorization.",
                            null
                        )
                    }
                } else {
                    result.success(googleAuthorizationPayload(authorizationResult))
                }
            }
            .addOnFailureListener { error ->
                val statusCode = if (error is ApiException) error.statusCode else null
                result.error(
                    "authorization_failed",
                    error.localizedMessage ?: "Google authorization failed.",
                    statusCode
                )
            }
    }

    private fun googleAuthorizationPayload(result: AuthorizationResult): Map<String, Any?> {
        return mapOf(
            "accessToken" to result.accessToken,
            "tokenType" to "Bearer",
            "refreshToken" to "",
            "grantedScopes" to result.grantedScopes.joinToString(" "),
            "serverAuthCode" to result.serverAuthCode
        )
    }
}
