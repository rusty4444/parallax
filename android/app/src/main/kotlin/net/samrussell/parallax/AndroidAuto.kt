package net.samrussell.parallax

import android.app.Application
import android.os.Handler
import android.os.Looper
import androidx.car.app.connection.CarConnection
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Android Auto support shared by the car screen (ParallaxCarApp.kt), the
 * notifications and the Dart side (lib/features/android_auto/).
 *
 * - Tracks whether the phone is projecting to a car. While it is, the shared
 *   engine (and so the Matrix client) is kept running, so a voice reply or
 *   "mark as read" from the car is sent at once rather than waiting until
 *   Parallax is next opened.
 * - Carries the car screen's requests (conversations, reply, mark as read) to
 *   the signed-in Dart host over `parallax/android_auto`, and the host's
 *   "something changed" signals back.
 *
 * Main thread only, except [projecting], which any thread may read.
 */
object AndroidAuto {
    const val CHANNEL = "parallax/android_auto"

    /** The Dart host has not attached yet (signed out or still starting). */
    class NotReady : Exception("Parallax is not ready")

    private val main = Handler(Looper.getMainLooper())
    private var started = false

    /** [CarConnection] type, or null until the first answer arrives. */
    @Volatile
    private var connectionType: Int? = null

    /** True while projecting to a car; null while still unknown. */
    val projecting: Boolean?
        get() = connectionType?.let { it != CarConnection.CONNECTION_TYPE_NOT_CONNECTED }

    /** The main engine's channel; car screen requests go through it. */
    private var channel: MethodChannel? = null

    /** Whether the signed-in Dart host is listening on [channel]. */
    var hostAttached = false
        private set

    private var activeScreens = 0
    private val listeners = LinkedHashSet<() -> Unit>()

    /** Stands in for the Dart host in JVM tests (src/test). */
    @androidx.annotation.VisibleForTesting
    var testHost: ((String, Map<String, Any?>, (Result<Any?>) -> Unit) -> Unit)? = null

    /**
     * Starts following the car connection. Called once per (main) process
     * from [ParallaxApplication]; never in the isolated PDF process.
     */
    fun start(app: Application) {
        if (started) return
        started = true
        try {
            CarConnection(app).type.observeForever { type ->
                connectionType = type
                if (type == CarConnection.CONNECTION_TYPE_PROJECTION) {
                    // Keep the client running while driving. A no-op when the
                    // engine already exists (app open or background connection).
                    try {
                        ParallaxEngine.obtain(app)
                    } catch (error: Exception) {
                        // The next push, action or car screen tries again.
                    }
                }
            }
        } catch (error: Exception) {
            connectionType = null
        }
    }

    /** The main engine: full bridge for the car screen. */
    fun attach(messenger: BinaryMessenger) {
        val bridge = MethodChannel(messenger, CHANNEL)
        bridge.setMethodCallHandler { call, result ->
            when (call.method) {
                "isProjecting" -> result.success(projecting)
                "hostAttached" -> {
                    hostAttached = call.argument<Boolean>("attached") == true
                    result.success(mapOf("carScreenActive" to (activeScreens > 0)))
                    notifyListeners()
                }
                "invalidate" -> {
                    result.success(null)
                    notifyListeners()
                }
                else -> result.notImplemented()
            }
        }
        channel = bridge
        hostAttached = false
    }

    /** Other engines (UnifiedPush): only the projection state, for rendering. */
    fun attachStateOnly(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isProjecting") result.success(projecting) else result.notImplemented()
        }
    }

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    private fun notifyListeners() {
        for (listener in listeners.toList()) listener()
    }

    /** A car screen started or stopped; the host only pushes updates while one shows. */
    fun setCarScreenActive(active: Boolean) {
        activeScreens = if (active) activeScreens + 1 else maxOf(0, activeScreens - 1)
        val bridge = channel ?: return
        if (!hostAttached) return
        bridge.invokeMethod("carScreenActive", mapOf("active" to (activeScreens > 0)))
    }

    /**
     * Asks the Dart host. [callback] runs on the main thread with the answer,
     * or with [NotReady] when no signed-in host is listening.
     */
    fun request(method: String, arguments: Map<String, Any?>, callback: (Result<Any?>) -> Unit) {
        testHost?.let {
            it(method, arguments, callback)
            return
        }
        val bridge = channel
        if (bridge == null) {
            main.post { callback(Result.failure(NotReady())) }
            return
        }
        bridge.invokeMethod(
            method,
            arguments,
            object : MethodChannel.Result {
                override fun success(result: Any?) = callback(Result.success(result))

                override fun error(code: String, message: String?, details: Any?) =
                    callback(Result.failure(IllegalStateException(code)))

                override fun notImplemented() = callback(Result.failure(NotReady()))
            },
        )
    }
}
