package net.samrussell.parallax

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileDescriptor
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * PDF previews for Dart (lib/features/file_preview/pdf_tools.dart).
 *
 * The rendering happens in [PdfRenderService], an isolated process; this
 * object is the app's side of it. `open` puts the decrypted bytes behind a
 * file descriptor (memory on Android 11+, otherwise a private temporary
 * file that is deleted before anyone reads it) and passes that to the
 * service. `render` returns RGBA pixels. `close` releases a document.
 *
 * The service is bound on first use and released half a minute after the
 * last document closes. If its process dies (a PDF crashed the system
 * library), every waiting request fails and the next one starts a new
 * process. All state here belongs to the main thread.
 */
object PdfTools {
    const val CHANNEL = "parallax/pdf"
    private const val DIR = "pdf_preview"
    private const val LINGER_MS = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var app: Context? = null
    private var cleaned = false

    private var service: Messenger? = null
    private var bound = false
    private val waiting = ArrayList<Runnable>()
    private val pending = HashMap<Int, (Bundle?) -> Unit>()
    private var nextRequest = 1
    private val documents = HashSet<Int>()

    private val replies = Messenger(
        Handler(Looper.getMainLooper()) { message ->
            pending.remove(message.arg1)?.invoke(message.data)
            true
        },
    )

    private val release = Runnable { if (documents.isEmpty() && pending.isEmpty()) unbind() }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            service = Messenger(binder)
            val queued = ArrayList(waiting)
            waiting.clear()
            queued.forEach { it.run() }
        }

        // The renderer's process died. Its documents went with it.
        override fun onServiceDisconnected(name: ComponentName) = reset()

        override fun onBindingDied(name: ComponentName) = reset()

        override fun onNullBinding(name: ComponentName) = reset()
    }

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel {
        val application = context.applicationContext
        app = application
        // Once per process: a temporary file is deleted as soon as it is
        // open, so anything here was left by a process that died in between.
        if (!cleaned) {
            cleaned = true
            io.execute { File(application.cacheDir, DIR).deleteRecursively() }
        }
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.isEmpty()) {
                        result.error(PdfProtocol.ERROR_UNREADABLE, null, null)
                    } else {
                        open(application, bytes, call.argument<Boolean>("file") == true, result)
                    }
                }
                "render" -> render(
                    call.argument<Int>("id") ?: 0,
                    call.argument<Int>("page") ?: 0,
                    call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0,
                    result,
                )
                "close" -> {
                    close(call.argument<Int>("id") ?: 0)
                    result.success(null)
                }
                // After a request that never came back: drop the renderer.
                "reset" -> {
                    reset()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    /** A seekable, read-only descriptor holding [bytes]. */
    private fun descriptorFor(context: Context, bytes: ByteArray, forceFile: Boolean): ParcelFileDescriptor {
        if (!forceFile && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Anonymous memory: the decrypted file never reaches storage.
            var memory: FileDescriptor? = null
            try {
                memory = Os.memfd_create("parallax-pdf", 0)
                var written = 0
                while (written < bytes.size) {
                    written += Os.write(memory, bytes, written, bytes.size - written)
                }
                return ParcelFileDescriptor.dup(memory)
            } catch (_: Throwable) {
                // Fall through to a file.
            } finally {
                if (memory != null) {
                    try {
                        Os.close(memory)
                    } catch (_: Throwable) {
                    }
                }
            }
        }
        val directory = File(context.cacheDir, DIR).apply { mkdirs() }
        val file = File.createTempFile("pdf", null, directory)
        try {
            file.writeBytes(bytes)
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        } finally {
            // Unlinked while open: the data lives until the descriptor is
            // closed and no path leads to it, even if the app is killed.
            file.delete()
        }
    }

    private fun open(context: Context, bytes: ByteArray, forceFile: Boolean, result: MethodChannel.Result) {
        io.execute {
            val descriptor = try {
                descriptorFor(context, bytes, forceFile)
            } catch (_: Throwable) {
                null
            }
            main.post {
                if (descriptor == null) {
                    result.error(PdfProtocol.ERROR_UNREADABLE, null, null)
                    return@post
                }
                val request = Bundle().apply { putParcelable(PdfProtocol.KEY_FILE, descriptor) }
                send(PdfProtocol.OPEN, request) { reply ->
                    // The service has its own copy by now (or never will).
                    try {
                        descriptor.close()
                    } catch (_: Throwable) {
                    }
                    val error = failure(reply)
                    if (reply == null || error != null) {
                        result.error(error ?: PdfProtocol.ERROR_UNREADABLE, null, null)
                    } else {
                        val id = reply.getInt(PdfProtocol.KEY_ID)
                        documents.add(id)
                        result.success(
                            mapOf(
                                "id" to id,
                                "pages" to reply.getInt(PdfProtocol.KEY_PAGES),
                                "sizes" to (reply.getFloatArray(PdfProtocol.KEY_SIZES) ?: FloatArray(0))
                                    .map { it.toDouble() },
                            ),
                        )
                    }
                    scheduleRelease()
                }
            }
        }
    }

    private fun render(id: Int, page: Int, width: Int, height: Int, result: MethodChannel.Result) {
        if (!documents.contains(id)) {
            result.error(PdfProtocol.ERROR_UNREADABLE, null, null)
            return
        }
        val request = Bundle().apply {
            putInt(PdfProtocol.KEY_ID, id)
            putInt(PdfProtocol.KEY_PAGE, page)
            putInt(PdfProtocol.KEY_WIDTH, width)
            putInt(PdfProtocol.KEY_HEIGHT, height)
        }
        send(PdfProtocol.RENDER, request) { reply ->
            val error = failure(reply)
            @Suppress("DEPRECATION")
            val bitmap = reply?.getParcelable<Bitmap>(PdfProtocol.KEY_BITMAP)
            if (error != null || bitmap == null) {
                bitmap?.recycle()
                result.error(error ?: PdfProtocol.ERROR_UNREADABLE, null, null)
                return@send
            }
            // Copying a page's pixels takes a few milliseconds: off the UI thread.
            io.execute {
                val answer = try {
                    val pixels = ByteBuffer.allocate(bitmap.byteCount)
                    bitmap.copyPixelsToBuffer(pixels)
                    mapOf("width" to bitmap.width, "height" to bitmap.height, "pixels" to pixels.array())
                } catch (_: Throwable) {
                    null
                } finally {
                    bitmap.recycle()
                }
                main.post {
                    if (answer == null) {
                        result.error(PdfProtocol.ERROR_MEMORY, null, null)
                    } else {
                        result.success(answer)
                    }
                }
            }
        }
    }

    private fun close(id: Int) {
        if (!documents.remove(id)) return
        if (service != null) {
            send(PdfProtocol.CLOSE, Bundle().apply { putInt(PdfProtocol.KEY_ID, id) }) {}
        }
        scheduleRelease()
    }

    private fun failure(reply: Bundle?): String? =
        if (reply == null) PdfProtocol.ERROR_UNREADABLE else reply.getString(PdfProtocol.KEY_ERROR)

    /** Sends one request; [done] gets the reply, or null if the service died. */
    private fun send(what: Int, data: Bundle, done: (Bundle?) -> Unit) {
        main.removeCallbacks(release)
        val id = nextRequest++
        pending[id] = done
        val deliver = Runnable {
            val target = service
            if (target == null) {
                pending.remove(id)?.invoke(null)
                return@Runnable
            }
            val message = Message.obtain(null, what, id, 0)
            message.data = data
            message.replyTo = replies
            try {
                target.send(message)
            } catch (_: Throwable) {
                pending.remove(id)?.invoke(null)
            }
        }
        if (service != null) {
            deliver.run()
            return
        }
        waiting.add(deliver)
        if (bound) return
        val context = app
        // Set first: a refused bind still has to be released (see unbind).
        bound = true
        val started = context != null && try {
            context.bindService(
                Intent(context, PdfRenderService::class.java),
                connection,
                Context.BIND_AUTO_CREATE,
            )
        } catch (_: Throwable) {
            false
        }
        if (!started) reset()
    }

    private fun scheduleRelease() {
        main.removeCallbacks(release)
        main.postDelayed(release, LINGER_MS)
    }

    private fun unbind() {
        main.removeCallbacks(release)
        if (bound) {
            bound = false
            try {
                app?.unbindService(connection)
            } catch (_: Throwable) {
            }
        }
        service = null
    }

    /** Drops the renderer: waiting requests fail and documents are forgotten. */
    private fun reset() {
        unbind()
        documents.clear()
        waiting.clear()
        val failed = ArrayList(pending.values)
        pending.clear()
        failed.forEach { it(null) }
    }
}
