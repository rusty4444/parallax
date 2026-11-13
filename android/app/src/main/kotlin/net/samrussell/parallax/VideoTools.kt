package net.samrussell.parallax

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Video sending support for Dart (lib/features/media/video_prep.dart):
 * probe = size, duration and a JPEG poster frame (MediaMetadataRetriever);
 * compress = H.264/AAC MP4 re-encode with Media3 Transformer, scaled so the
 * short side is at most the requested size.
 */
@UnstableApi
object VideoTools {
    const val CHANNEL = "parallax/video"
    private const val DIR = "video_tools"
    private const val THUMBNAIL_SIDE = 800
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var cleaned = false

    private fun workDir(context: Context) = File(context.cacheDir, DIR)

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel {
        val app = context.applicationContext
        // Once per process (a recreated activity registers again): outputs
        // from an earlier process are never still in use.
        if (!cleaned) {
            cleaned = true
            io.execute { workDir(app).deleteRecursively() }
        }
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("INVALID_ARGUMENT", "Missing path", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "probe" -> io.execute {
                    val info = try {
                        probe(path)
                    } catch (error: Exception) {
                        null
                    }
                    main.post { result.success(info) }
                }
                "compress" -> {
                    val shortSide = call.argument<Int>("shortSide") ?: 720
                    val bitrate = call.argument<Int>("videoBitrate") ?: 2_500_000
                    compress(app, path, shortSide, bitrate, result)
                }
                "delete" -> io.execute {
                    deleteOwned(app, path)
                    main.post { result.success(null) }
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    private fun probe(path: String): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun number(key: Int) = retriever.extractMetadata(key)?.toLongOrNull()
            var width = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt()
            var height = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt()
            val rawRotation = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
            val rotation = ((rawRotation % 360) + 360) % 360
            if (rotation == 90 || rotation == 270) {
                val swap = width
                width = height
                height = swap
            }
            val duration = number(MediaMetadataRetriever.METADATA_KEY_DURATION)
            // A frame a little way in: the very first is often black.
            val atUs = ((duration ?: 0L) * 1000L / 10L).coerceAtMost(1_000_000L)
            val frame = try {
                retriever.getFrameAtTime(atUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } catch (error: Exception) {
                null
            }
            var thumbnail: ByteArray? = null
            var thumbWidth: Int? = null
            var thumbHeight: Int? = null
            if (frame != null) {
                if (width != null && height != null && width != height && frame.width != frame.height && (width > height) != (frame.width > frame.height)) {
                    val swap = width
                    width = height
                    height = swap
                }
                val scale = THUMBNAIL_SIDE.toFloat() / max(frame.width, frame.height)
                val scaled = if (scale < 1f) {
                    Bitmap.createScaledBitmap(
                        frame,
                        (frame.width * scale).roundToInt().coerceAtLeast(1),
                        (frame.height * scale).roundToInt().coerceAtLeast(1),
                        true,
                    )
                } else {
                    frame
                }
                val out = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
                thumbnail = out.toByteArray()
                thumbWidth = scaled.width
                thumbHeight = scaled.height
                if (scaled !== frame) scaled.recycle()
                frame.recycle()
            }
            return mapOf(
                "width" to width,
                "height" to height,
                "durationMs" to duration,
                "thumbnail" to thumbnail,
                "thumbnailWidth" to thumbWidth,
                "thumbnailHeight" to thumbHeight,
            )
        } finally {
            try {
                retriever.release()
            } catch (error: IOException) {
                // Nothing left to release.
            }
        }
    }

    private fun compress(
        context: Context,
        path: String,
        shortSide: Int,
        bitrate: Int,
        result: MethodChannel.Result,
    ) {
        val dir = workDir(context)
        if (!dir.exists() && !dir.mkdirs()) {
            result.error("IO", "Can't create the video work directory", null)
            return
        }
        val output = File(dir, "${UUID.randomUUID()}.mp4")
        // Transformer must be built and started on a thread with a Looper.
        main.post {
            try {
                val encoders = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(bitrate).build(),
                    )
                    .build()
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoders)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            result.success(output.absolutePath)
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            output.delete()
                            result.error("COMPRESS_FAILED", exportException.message, null)
                        }
                    })
                    .build()
                val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(path))))
                    .setEffects(
                        Effects(
                            listOf(),
                            listOf(Presentation.createForShortSide(shortSide)),
                        ),
                    )
                    .build()
                transformer.start(item, output.absolutePath)
            } catch (error: Exception) {
                output.delete()
                result.error("COMPRESS_FAILED", error.message, null)
            }
        }
    }

    /** Deletes only files inside the work directory. */
    private fun deleteOwned(context: Context, path: String) {
        try {
            val root = workDir(context).canonicalPath + File.separator
            val file = File(path).canonicalFile
            if (file.path.startsWith(root)) file.delete()
        } catch (error: IOException) {
            // Cleared on the next start.
        }
    }
}
