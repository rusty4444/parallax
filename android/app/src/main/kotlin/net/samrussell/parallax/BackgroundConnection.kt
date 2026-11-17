package net.samrussell.parallax

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine of this process, shared by MainActivity and
 * [BackgroundConnectionService]. It outlives the activity, so the Matrix client
 * keeps syncing (and raising notifications) after Parallax is closed, with no
 * push gateway, Firebase or distributor app. Main thread only.
 */
object ParallaxEngine {
    const val ID = "parallax_main"

    @androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        BackgroundConnection.attachChannel(app, engine)
        VideoTools.register(app, engine.dartExecutor.binaryMessenger)
        PdfTools.register(app, engine.dartExecutor.binaryMessenger)
        ShareShortcuts.register(app, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }
}

/** Dart control of the background connection (lib/features/platform/background_connection.dart). */
object BackgroundConnection {
    private const val CHANNEL = "parallax/background_connection"
    private const val PREFS = "parallax_background_connection"
    private const val KEY_ENABLED = "enabled"

    fun attachChannel(app: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success(start(app))
                    "stop" -> {
                        stop(app)
                        result.success(null)
                    }
                    "isRunning" -> result.success(BackgroundConnectionService.running)
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations(app))
                    "requestIgnoreBatteryOptimizations" ->
                        result.success(requestIgnoreBatteryOptimizations(app))
                    else -> result.notImplemented()
                }
            }
    }

    /** Whether the connection should run; read at boot and after updates. */
    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

    private fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    /** True when the service is running or was started. */
    fun start(context: Context): Boolean {
        setEnabled(context, true)
        if (BackgroundConnectionService.running) return true
        return launch(context)
    }

    fun launch(context: Context): Boolean = try {
        ContextCompat.startForegroundService(
            context,
            Intent(context, BackgroundConnectionService::class.java),
        )
        true
    } catch (error: Exception) {
        // For example ForegroundServiceStartNotAllowedException from the
        // background; the next foreground start tries again.
        false
    }

    fun stop(context: Context) {
        setEnabled(context, false)
        context.stopService(Intent(context, BackgroundConnectionService::class.java))
    }

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return power?.isIgnoringBatteryOptimizations(context.packageName) ?: false
    }

    /** Shows Android's "Let Parallax always run in the background?" dialog. */
    fun requestIgnoreBatteryOptimizations(context: Context): Boolean {
        if (isIgnoringBatteryOptimizations(context)) return true
        return try {
            context.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (error: Exception) {
            false
        }
    }
}

/**
 * Keeps the Parallax process (and its Matrix sync) alive while the app is
 * closed, with a low-priority ongoing notification as Android requires. After
 * Android restarts the process, it brings the shared engine back headless so
 * the signed-in client resumes syncing.
 */
class BackgroundConnectionService : Service() {
    companion object {
        @Volatile
        var running = false
            private set
        private const val CHANNEL_ID = "parallax_background_v1"
        private const val NOTIFICATION_ID = 7301
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!BackgroundConnection.isEnabled(this)) {
            // Turned off (or signed out) while Android was restarting us.
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            ParallaxEngine.obtain(applicationContext)
        } catch (error: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL_ID) == null
        ) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Background connection",
                NotificationManager.IMPORTANCE_MIN,
            )
            channel.description =
                "Keeps Parallax connected so new messages arrive. You can hide this notification; the connection keeps running."
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val open = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_parallax)
            .setContentTitle("Parallax is connected")
            .setContentText("Checking for new messages")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}

/** Restarts the connection after a reboot or an app update. */
class BackgroundConnectionBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                if (BackgroundConnection.isEnabled(context)) {
                    BackgroundConnection.launch(context)
                }
            }
        }
    }
}
