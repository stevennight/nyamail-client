package com.nyatori.nyamail

import android.accounts.Account
import android.accounts.AccountManager
import android.app.Activity
import android.content.IntentSender
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.AccountPicker
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val GOOGLE_ACCOUNT_PICKER_REQUEST_CODE = 7203
        private const val GOOGLE_AUTHORIZATION_REQUEST_CODE = 7204
    }

    private data class PendingGoogleAuthorization(
        val result: MethodChannel.Result,
        val scopes: List<Scope>,
        val serverClientId: String,
        val forceRefreshToken: Boolean,
    )

    private var oauthCallbackChannel: MethodChannel? = null
    private var pendingOAuthRedirect: String? = null
    private var pendingGoogleAuthorization: PendingGoogleAuthorization? = null

    // The engine lives at process level so background mail sync survives the
    // activity being destroyed; see NyaMailEngine.
    override fun getCachedEngineId(): String = NyaMailEngine.ensure(this)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        configureBackgroundSyncChannel(flutterEngine)
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
                    val loginHint = call.argument<String>("loginHint") ?: ""
                    val forceAccountPicker = call.argument<Boolean>("forceAccountPicker") ?: false
                    val androidClientId = call.argument<String>("androidClientId") ?: ""
                    val serverClientId = call.argument<String>("serverClientId") ?: ""
                    val forceRefreshToken =
                        call.argument<Boolean>("forceRefreshToken") ?: true
                    authorizeGmail(
                        rawScopes,
                        loginHint,
                        forceAccountPicker,
                        androidClientId,
                        serverClientId,
                        forceRefreshToken,
                        result
                    )
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
        when (requestCode) {
            GOOGLE_ACCOUNT_PICKER_REQUEST_CODE -> {
                val pending = pendingGoogleAuthorization ?: return
                if (resultCode != Activity.RESULT_OK || data == null) {
                    pendingGoogleAuthorization = null
                    pending.result.error(
                        "account_selection_cancelled",
                        "Google account selection was cancelled.",
                        null
                    )
                    return
                }
                val accountName = data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
                if (accountName.isNullOrBlank()) {
                    pendingGoogleAuthorization = null
                    pending.result.error(
                        "account_selection_failed",
                        "Google account selection did not return an account.",
                        null
                    )
                    return
                }
                val accountType =
                    data.getStringExtra(AccountManager.KEY_ACCOUNT_TYPE) ?: "com.google"
                startGoogleAuthorization(Account(accountName, accountType))
            }

            GOOGLE_AUTHORIZATION_REQUEST_CODE -> {
                val pending = pendingGoogleAuthorization ?: return
                pendingGoogleAuthorization = null
                if (resultCode != Activity.RESULT_OK || data == null) {
                    pending.result.error(
                        "authorization_cancelled",
                        "Google authorization was cancelled.",
                        null
                    )
                    return
                }

                try {
                    val authorizationResult = Identity.getAuthorizationClient(this)
                        .getAuthorizationResultFromIntent(data)
                    pending.result.success(googleAuthorizationPayload(authorizationResult))
                } catch (error: ApiException) {
                    pending.result.error(
                        "authorization_failed",
                        error.localizedMessage ?: "Google authorization failed.",
                        error.statusCode
                    )
                } catch (error: Exception) {
                    pending.result.error(
                        "authorization_failed",
                        error.localizedMessage ?: "Google authorization failed.",
                        null
                    )
                }
            }
        }
    }

    private fun configureBackgroundSyncChannel(flutterEngine: FlutterEngine) {
        // Uses the application context: the engine, and so this handler,
        // outlives the activity while the sync service runs.
        val appContext = applicationContext
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nyatori.nyamail/background_sync"
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        MailSyncService.start(appContext)
                        result.success(true)
                    }
                    "stop" -> {
                        MailSyncService.stop(appContext)
                        result.success(null)
                    }
                    "acquireWakeLock" -> {
                        val timeout = call.argument<Number>("timeoutMs")?.toLong() ?: 60_000L
                        MailSyncService.acquireWakeLock(appContext, timeout)
                        result.success(null)
                    }
                    "releaseWakeLock" -> {
                        MailSyncService.releaseWakeLock()
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val power = appContext.getSystemService(POWER_SERVICE) as PowerManager
                        result.success(power.isIgnoringBatteryOptimizations(appContext.packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        // Ask directly for this app; some ROMs lack the dialog,
                        // so fall back to the full list.
                        val request = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:${appContext.packageName}")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            appContext.startActivity(request)
                        } catch (_: Exception) {
                            appContext.startActivity(
                                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }
                        result.success(null)
                    }
                    "openAppDetailsSettings" -> {
                        // Vendor auto-start and background limits live here.
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${appContext.packageName}")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        appContext.startActivity(intent)
                        result.success(null)
                    }
                    "openNotificationSettings" -> {
                        val intent = if (android.os.Build.VERSION.SDK_INT >= 26) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, appContext.packageName)
                        } else {
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${appContext.packageName}")
                            )
                        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        appContext.startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                // e.g. ForegroundServiceStartNotAllowedException when asked to
                // start while the app is already in the background.
                result.error(
                    "background_sync_failed",
                    error.localizedMessage ?: error.javaClass.simpleName,
                    null
                )
            }
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

    private fun authorizeGmail(
        rawScopes: List<String>,
        loginHint: String,
        forceAccountPicker: Boolean,
        androidClientId: String,
        serverClientId: String,
        forceRefreshToken: Boolean,
        result: MethodChannel.Result
    ) {
        if (pendingGoogleAuthorization != null) {
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

        if (androidClientId.isBlank()) {
            result.error(
                "missing_android_client_id",
                "Google Android client ID is required.",
                null
            )
            return
        }
        if (serverClientId.isBlank()) {
            result.error(
                "missing_server_client_id",
                "Google Web client ID is required for offline access.",
                null
            )
            return
        }
        pendingGoogleAuthorization = PendingGoogleAuthorization(
            result,
            scopes,
            serverClientId.trim(),
            forceRefreshToken
        )
        if (forceAccountPicker) {
            startGoogleAccountPicker(loginHint.trim())
            return
        }
        val account =
            if (loginHint.isBlank()) null else Account(loginHint.trim(), "com.google")
        startGoogleAuthorization(account)
    }

    private fun startGoogleAccountPicker(loginHint: String) {
        val pending = pendingGoogleAuthorization ?: return
        try {
            val builder = AccountPicker.AccountChooserOptions.Builder()
                .setAllowableAccountsTypes(listOf("com.google"))
                .setAlwaysShowAccountPicker(true)
                .setTitleOverrideText("Choose Google account")
            if (loginHint.isNotBlank()) {
                builder.setSelectedAccount(Account(loginHint, "com.google"))
            }
            startActivityForResult(
                AccountPicker.newChooseAccountIntent(builder.build()),
                GOOGLE_ACCOUNT_PICKER_REQUEST_CODE
            )
        } catch (error: Exception) {
            pendingGoogleAuthorization = null
            pending.result.error(
                "account_picker_failed",
                error.localizedMessage ?: "Could not open Google account picker.",
                null
            )
        }
    }

    private fun startGoogleAuthorization(account: Account?) {
        val pending = pendingGoogleAuthorization ?: return
        val builder = AuthorizationRequest.builder()
            .setRequestedScopes(pending.scopes)
            .requestOfflineAccess(
                pending.serverClientId,
                pending.forceRefreshToken
            )
        if (account != null) {
            builder.setAccount(account)
        }
        val request = builder.build()

        Identity.getAuthorizationClient(this)
            .authorize(request)
            .addOnSuccessListener { authorizationResult ->
                if (authorizationResult.hasResolution()) {
                    try {
                        startIntentSenderForResult(
                            authorizationResult.pendingIntent!!.intentSender,
                            GOOGLE_AUTHORIZATION_REQUEST_CODE,
                            null,
                            0,
                            0,
                            0
                        )
                    } catch (error: IntentSender.SendIntentException) {
                        pendingGoogleAuthorization = null
                        pending.result.error(
                            "authorization_resolution_failed",
                            error.localizedMessage ?: "Could not open Google authorization.",
                            null
                        )
                    }
                } else {
                    pendingGoogleAuthorization = null
                    pending.result.success(googleAuthorizationPayload(authorizationResult))
                }
            }
            .addOnFailureListener { error ->
                pendingGoogleAuthorization = null
                val statusCode = if (error is ApiException) error.statusCode else null
                pending.result.error(
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
            "serverAuthCode" to result.serverAuthCode,
            "accountEmail" to result.toGoogleSignInAccount()?.email
        )
    }
}
