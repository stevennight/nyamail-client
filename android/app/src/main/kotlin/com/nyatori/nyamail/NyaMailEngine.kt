package com.nyatori.nyamail

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the app's single Flutter engine outside of any Activity.
 *
 * By default the engine (and the Dart isolate holding the unlocked vault,
 * IMAP connections and timers) dies with MainActivity, e.g. when the task is
 * swiped away. Caching it at process level lets [MailSyncService] keep mail
 * sync running, and reopening the app reattaches to the live state.
 */
object NyaMailEngine {
    const val ID = "nyamail_main"

    fun ensure(context: Context): String {
        val cache = FlutterEngineCache.getInstance()
        if (!cache.contains(ID)) {
            val engine = FlutterEngine(context.applicationContext)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            cache.put(ID, engine)
        }
        return ID
    }
}
