package net.samrussell.parallax

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.unifiedpush.flutter.connector.UnifiedPushService
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors

// FragmentActivity is required by local_auth (biometric app lock).
class MainActivity : FlutterFragmentActivity() {
    private val permissionRequests = mutableMapOf<Int, Pair<MethodChannel.Result, List<String>>>()
    private var nextPermissionRequest = 4100
    private var intentChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SharedIntentStore.pruneStale(applicationContext)
        // A recreated activity or a launch from Recents re-delivers the original
        // share/VIEW intent; only a fresh launch may act on it.
        if (savedInstanceState == null &&
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
        ) {
            handleIncomingIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parallax/secure_window")
            .setMethodCallHandler { call, result ->
                if (call.method != "setSecure") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val enabled = call.argument<Boolean>("enabled")
                if (enabled == null) {
                    result.error("INVALID_ARGUMENT", "Missing enabled flag", null)
                    return@setMethodCallHandler
                }
                runOnUiThread {
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
            }
        // Minimal runtime-permission bridge (camera/microphone for calls).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parallax/permissions")
            .setMethodCallHandler { call, result ->
                val permissions = call.argument<List<String>>("permissions")
                if (permissions == null || permissions.isEmpty()) {
                    result.error("INVALID_ARGUMENT", "Missing permissions", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "check" -> result.success(grantedMap(permissions))
                    "request" -> {
                        val missing = permissions.filter { !isGranted(it) }
                        if (missing.isEmpty()) {
                            result.success(grantedMap(permissions))
                        } else {
                            val code = nextPermissionRequest++
                            if (nextPermissionRequest > 4999) nextPermissionRequest = 4100
                            permissionRequests[code] = result to permissions
                            ActivityCompat.requestPermissions(this, missing.toTypedArray(), code)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // Share (ACTION_SEND/SEND_MULTIPLE) and matrix.to / matrix: VIEW intents.
        // Dart pulls the queue, so intents that arrive before Dart listens wait.
        val appContext = applicationContext
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parallax/platform_intents")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> result.success(SharedIntentStore.takePending())
                "discard" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    SharedIntentStore.discard(appContext, paths)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        intentChannel = channel
        SharedIntentStore.listener = { channel.invokeMethod("pending", null) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        intentChannel?.setMethodCallHandler(null)
        intentChannel = null
        SharedIntentStore.listener = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val app = applicationContext
        when (intent.action) {
            Intent.ACTION_VIEW -> {
                val data = intent.data ?: return
                val value = data.toString()
                if (value.length > SharedIntentStore.MAX_LINK_LENGTH) return
                val scheme = data.scheme?.lowercase()
                val host = data.host?.lowercase()
                val isMatrixLink = scheme == "matrix" ||
                    ((scheme == "https" || scheme == "http") &&
                        (host == "matrix.to" || host == "www.matrix.to"))
                if (isMatrixLink) {
                    SharedIntentStore.enqueue(app, mapOf("kind" to "link", "uri" to value))
                }
            }
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                // Copy off the main thread; URI grants belong to this app's UID.
                val detached = Intent(intent)
                SharedIntentStore.executor.execute {
                    val payload = try {
                        SharedIntentStore.readShare(app, detached)
                    } catch (error: Exception) {
                        null
                    }
                    if (payload != null) SharedIntentStore.enqueue(app, payload)
                }
            }
        }
    }

    private fun isGranted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun grantedMap(permissions: List<String>) = permissions.associateWith { isGranted(it) }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val pending = permissionRequests.remove(requestCode) ?: return
        pending.first.success(grantedMap(pending.second))
    }
}

/**
 * Runs UnifiedPush events in a headless engine with a dedicated Dart entrypoint
 * when no UI engine exists, instead of the plugin default (the full app's
 * main()), so a push never starts the Matrix client in the background.
 */
class ParallaxUnifiedPushService : UnifiedPushService() {
    override fun getEngine(context: Context): FlutterEngine {
        val engine = FlutterEngine(context)
        val bundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                bundlePath,
                "package:parallax/features/platform/unified_push.dart",
                "unifiedPushBackgroundMain",
            ),
        )
        return engine
    }
}

/** Process-wide queue of share/VIEW payloads and the share copy cache. */
private object SharedIntentStore {
    private const val DIR = "shared_intents"
    const val MAX_FILES = 10
    const val MAX_BYTES = 20L * 1024 * 1024
    const val MAX_TEXT = 32 * 1024
    const val MAX_LINK_LENGTH = 4096
    private const val MAX_PENDING = 5
    private const val STALE_MS = 6L * 60 * 60 * 1000

    val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Main thread only.
    private val pending = ArrayDeque<Map<String, Any?>>()
    var listener: (() -> Unit)? = null

    private class TooLargeException : IOException()

    private sealed interface CopyResult {
        class Copied(val payload: Map<String, Any?>) : CopyResult
        object TooLarge : CopyResult
        object Refused : CopyResult
    }

    private fun root(context: Context) = File(context.cacheDir, DIR)

    fun enqueue(context: Context, payload: Map<String, Any?>) {
        main.post {
            pending.addLast(payload)
            while (pending.size > MAX_PENDING) {
                discardPayload(context, pending.removeFirst())
            }
            listener?.invoke()
        }
    }

    fun takePending(): List<Map<String, Any?>> {
        val items = pending.toList()
        pending.clear()
        return items
    }

    private fun discardPayload(context: Context, payload: Map<String, Any?>) {
        val files = payload["files"] as? List<*> ?: return
        val paths = files.mapNotNull { (it as? Map<*, *>)?.get("path") as? String }
        discard(context, paths)
    }

    /** Deletes copies, but only inside the share cache directory. */
    fun discard(context: Context, paths: List<String>) {
        executor.execute {
            val rootPath = try {
                root(context).canonicalPath + File.separator
            } catch (error: IOException) {
                return@execute
            }
            for (path in paths) {
                try {
                    val file = File(path).canonicalFile
                    if (!file.path.startsWith(rootPath)) continue
                    file.delete()
                    val parent = file.parentFile
                    if (parent != null &&
                        parent.canonicalPath.startsWith(rootPath) &&
                        parent.list()?.isEmpty() == true
                    ) {
                        parent.delete()
                    }
                } catch (error: IOException) {
                    // Pruned on a later start.
                }
            }
        }
    }

    /** Removes share copies abandoned by an earlier process. */
    fun pruneStale(context: Context) {
        executor.execute {
            val now = System.currentTimeMillis()
            root(context).listFiles()?.forEach { dir ->
                if (now - dir.lastModified() > STALE_MS) dir.deleteRecursively()
            }
        }
    }

    fun readShare(context: Context, intent: Intent): Map<String, Any?> {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(MAX_TEXT)
        val subject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.take(512)
        val uris = LinkedHashSet<Uri>()
        if (intent.action == Intent.ACTION_SEND) {
            streamExtra(intent)?.let { uris.add(it) }
        } else {
            streamListExtra(intent)?.let { uris.addAll(it) }
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let { uris.add(it) }
            }
        }
        val dir = File(root(context), UUID.randomUUID().toString())
        val files = ArrayList<Map<String, Any?>>()
        var skipped = 0
        var tooLarge = 0
        for (uri in uris) {
            if (files.size >= MAX_FILES) {
                skipped++
                continue
            }
            when (val result = copy(context, uri, dir, intent.type)) {
                is CopyResult.Copied -> files.add(result.payload)
                CopyResult.TooLarge -> tooLarge++
                CopyResult.Refused -> skipped++
            }
        }
        if (files.isEmpty()) dir.delete()
        return mapOf(
            "kind" to "share",
            "text" to text,
            "subject" to subject,
            "files" to files,
            "skipped" to skipped,
            "tooLarge" to tooLarge,
        )
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? = try {
        if (Build.VERSION.SDK_INT >= 34) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
    } catch (error: Exception) {
        null
    }

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri>? = try {
        if (Build.VERSION.SDK_INT >= 34) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }
    } catch (error: Exception) {
        null
    }

    /**
     * Refuses this app's own providers: a hostile share must never make
     * Parallax upload its own private files.
     */
    @Suppress("DEPRECATION")
    private fun isOwnAuthority(context: Context, authority: String): Boolean {
        val own = context.packageName
        if (authority == own || authority.startsWith("$own.")) return true
        return try {
            context.packageManager.resolveContentProvider(authority, 0)?.packageName == own
        } catch (error: Exception) {
            true
        }
    }

    private fun sanitise(name: String): String {
        val cleaned = name.substringAfterLast('/').substringAfterLast('\\')
            .filter { it >= ' ' && it != '\u007f' }
            .trim()
            .trimStart('.')
        if (cleaned.isEmpty()) return "shared-file"
        return if (cleaned.length > 120) cleaned.takeLast(120) else cleaned
    }

    private fun uniqueName(dir: File, name: String): String {
        if (!File(dir, name).exists()) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var index = 1
        while (File(dir, "$base-$index$extension").exists()) index++
        return "$base-$index$extension"
    }

    /** Only content:// streams from other apps; file:// is always refused. */
    private fun copy(context: Context, uri: Uri, dir: File, fallbackType: String?): CopyResult {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) return CopyResult.Refused
        val authority = uri.authority ?: return CopyResult.Refused
        if (isOwnAuthority(context, authority)) return CopyResult.Refused
        val resolver = context.contentResolver
        var displayName: String? = null
        var declaredSize = -1L
        try {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        declaredSize = cursor.getLong(sizeIndex)
                    }
                }
            }
        } catch (error: Exception) {
            // Metadata is optional; the copy below enforces the real size.
        }
        if (declaredSize > MAX_BYTES) return CopyResult.TooLarge
        val resolvedType = try {
            resolver.getType(uri)
        } catch (error: Exception) {
            null
        }
        val mimeType = resolvedType
            ?: fallbackType?.takeUnless { it.contains('*') }
            ?: "application/octet-stream"
        if (!dir.exists() && !dir.mkdirs()) return CopyResult.Refused
        val name = uniqueName(dir, sanitise(displayName ?: uri.lastPathSegment ?: "shared-file"))
        val target = File(dir, name)
        var total = 0L
        try {
            val input = resolver.openInputStream(uri) ?: return CopyResult.Refused
            input.use { source ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_BYTES) throw TooLargeException()
                        output.write(buffer, 0, read)
                    }
                }
            }
        } catch (error: TooLargeException) {
            target.delete()
            return CopyResult.TooLarge
        } catch (error: Exception) {
            target.delete()
            return CopyResult.Refused
        }
        if (total <= 0L) {
            target.delete()
            return CopyResult.Refused
        }
        return CopyResult.Copied(
            mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "mimeType" to mimeType,
                "size" to total,
            ),
        )
    }
}
