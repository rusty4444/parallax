package net.samrussell.parallax

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import java.io.IOException
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.sqrt

/** Messages between [PdfTools] (the app) and [PdfRenderService]. */
internal object PdfProtocol {
    const val OPEN = 1
    const val RENDER = 2
    const val CLOSE = 3

    const val KEY_FILE = "file"
    const val KEY_ID = "id"
    const val KEY_PAGES = "pages"
    const val KEY_SIZES = "sizes"
    const val KEY_PAGE = "page"
    const val KEY_WIDTH = "width"
    const val KEY_HEIGHT = "height"
    const val KEY_BITMAP = "bitmap"
    const val KEY_ERROR = "error"

    const val ERROR_PASSWORD = "PASSWORD"
    const val ERROR_UNREADABLE = "UNREADABLE"
    const val ERROR_MEMORY = "MEMORY"

    /** Longest side of a rendered page, in pixels. */
    const val MAX_EDGE = 4096

    /** Most pixels in one rendered page (32 MB of RGBA). */
    const val MAX_PIXELS = 8_000_000L

    /**
     * Pages whose size is read when a document opens (each has to be
     * loaded to ask). Later pages are assumed to match the last of these.
     */
    const val MAX_MEASURED = 200
    const val MAX_DOCUMENTS = 4
}

/**
 * Renders PDF pages with the system's PdfRenderer in an isolated process.
 *
 * A PDF in a chat comes from someone else, and PdfRenderer runs a large
 * native library on it. Declared `android:isolatedProcess="true"`, this
 * service has no permissions and cannot open the app's files, read its
 * keys or use the network: it is handed a file descriptor and returns
 * bitmaps. A PDF that crashes or takes over the renderer ends there, and
 * the app only sees a failed request. Android's own PdfRenderer
 * documentation recommends this for untrusted files.
 *
 * One thread handles every message, in order: PdfRenderer is not thread
 * safe and allows one open page at a time.
 */
class PdfRenderService : Service() {
    private class Document(val renderer: PdfRenderer)

    private val documents = HashMap<Int, Document>()
    private var nextId = 1
    private lateinit var thread: HandlerThread
    private lateinit var messenger: Messenger

    override fun onCreate() {
        super.onCreate()
        thread = HandlerThread("pdf-render").apply { start() }
        messenger = Messenger(
            Handler(thread.looper) { message ->
                handle(message)
                true
            },
        )
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        // Runs after anything already queued, then stops the thread.
        Handler(thread.looper).post {
            for (document in documents.values) {
                try {
                    document.renderer.close()
                } catch (_: Throwable) {
                }
            }
            documents.clear()
            thread.quitSafely()
        }
        super.onDestroy()
    }

    private fun handle(message: Message) {
        val replyTo = message.replyTo ?: return
        val request = message.data
        val reply = Bundle()
        var rendered: Bitmap? = null
        try {
            when (message.what) {
                PdfProtocol.OPEN -> open(request, reply)
                PdfProtocol.RENDER -> rendered = render(request, reply)
                PdfProtocol.CLOSE -> close(request.getInt(PdfProtocol.KEY_ID))
                else -> throw IllegalArgumentException()
            }
        } catch (_: SecurityException) {
            // PdfRenderer's answer to a password-protected file.
            reply.putString(PdfProtocol.KEY_ERROR, PdfProtocol.ERROR_PASSWORD)
        } catch (_: OutOfMemoryError) {
            reply.putString(PdfProtocol.KEY_ERROR, PdfProtocol.ERROR_MEMORY)
        } catch (_: Throwable) {
            reply.putString(PdfProtocol.KEY_ERROR, PdfProtocol.ERROR_UNREADABLE)
        }
        val answer = Message.obtain(null, message.what, message.arg1, 0)
        answer.data = reply
        try {
            replyTo.send(answer)
        } catch (_: RemoteException) {
            // The app went away; nothing to tell.
        }
        // send() has copied the pixels into the transaction.
        rendered?.recycle()
    }

    private fun open(request: Bundle, reply: Bundle) {
        request.classLoader = ParcelFileDescriptor::class.java.classLoader
        @Suppress("DEPRECATION")
        val descriptor = request.getParcelable<ParcelFileDescriptor>(PdfProtocol.KEY_FILE)
            ?: throw IOException("No file")
        if (documents.size >= PdfProtocol.MAX_DOCUMENTS) {
            descriptor.close()
            throw IllegalStateException("Too many documents")
        }
        val renderer = try {
            // Takes ownership of the descriptor once it has been created.
            PdfRenderer(descriptor)
        } catch (error: Throwable) {
            try {
                descriptor.close()
            } catch (_: Throwable) {
            }
            throw error
        }
        val id = nextId++
        documents[id] = Document(renderer)
        val pages = renderer.pageCount
        val measured = min(pages, PdfProtocol.MAX_MEASURED)
        val sizes = FloatArray(measured * 2)
        for (index in 0 until measured) {
            val page = renderer.openPage(index)
            try {
                sizes[index * 2] = page.width.toFloat()
                sizes[index * 2 + 1] = page.height.toFloat()
            } finally {
                page.close()
            }
        }
        reply.putInt(PdfProtocol.KEY_ID, id)
        reply.putInt(PdfProtocol.KEY_PAGES, pages)
        reply.putFloatArray(PdfProtocol.KEY_SIZES, sizes)
    }

    /**
     * Draws a page [PdfProtocol.KEY_WIDTH] pixels wide on white. With a
     * height, only that much of the top of the page is drawn (the timeline
     * thumbnail). Oversized requests are scaled down to the pixel limit.
     */
    private fun render(request: Bundle, reply: Bundle): Bitmap {
        val document = documents[request.getInt(PdfProtocol.KEY_ID)]
            ?: throw IllegalStateException("Unknown document")
        val page = document.renderer.openPage(request.getInt(PdfProtocol.KEY_PAGE))
        try {
            val pageWidth = page.width.coerceAtLeast(1)
            val pageHeight = page.height.coerceAtLeast(1)
            var width = request.getInt(PdfProtocol.KEY_WIDTH).coerceIn(16, PdfProtocol.MAX_EDGE)
            var scale = width.toFloat() / pageWidth
            var height = ceil(pageHeight * scale).toInt().coerceAtLeast(1)
            val strip = request.getInt(PdfProtocol.KEY_HEIGHT, 0)
            if (strip > 0) height = min(height, strip)
            if (height > PdfProtocol.MAX_EDGE || width.toLong() * height > PdfProtocol.MAX_PIXELS) {
                val shrink = min(
                    PdfProtocol.MAX_EDGE.toDouble() / height,
                    sqrt(PdfProtocol.MAX_PIXELS.toDouble() / (width.toLong() * height)),
                ).coerceAtMost(1.0)
                width = (width * shrink).toInt().coerceAtLeast(1)
                height = (height * shrink).toInt().coerceAtLeast(1)
                scale = (scale * shrink).toFloat()
            }
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                // Pages are drawn on transparency; paper is white.
                bitmap.eraseColor(Color.WHITE)
                page.render(
                    bitmap,
                    null,
                    Matrix().apply { setScale(scale, scale) },
                    PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                )
            } catch (error: Throwable) {
                bitmap.recycle()
                throw error
            }
            reply.putParcelable(PdfProtocol.KEY_BITMAP, bitmap)
            return bitmap
        } finally {
            page.close()
        }
    }

    private fun close(id: Int) {
        documents.remove(id)?.renderer?.close()
    }
}
