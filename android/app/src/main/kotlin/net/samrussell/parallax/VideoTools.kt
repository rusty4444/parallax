package net.samrussell.parallax

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
                "sampleFrames" -> {
                    val maxEdge = (call.argument<Int>("maxEdge") ?: 360).coerceIn(64, 720)
                    val maxFrames = (call.argument<Int>("maxFrames") ?: 12).coerceIn(2, 24)
                    val maxDurationMs = (call.argument<Int>("maxDurationMs") ?: 3000).coerceIn(500, 10_000)
                    io.execute {
                        val sample = try {
                            sampleFrames(path, maxEdge, maxFrames, maxDurationMs)
                        } catch (error: Exception) {
                            null
                        }
                        main.post { result.success(sample) }
                    }
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

    private fun sampleFrames(
        path: String,
        maxEdge: Int,
        maxFrames: Int,
        maxDurationMs: Int,
    ): Map<String, Any?>? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun number(key: Int) = retriever.extractMetadata(key)?.toLongOrNull()
            val rawWidth = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt()
            val rawHeight = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt()
            val rawRotation = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
            val rotation = ((rawRotation % 360) + 360) % 360
            val durationMs = number(MediaMetadataRetriever.METADATA_KEY_DURATION) ?: 0L

            // Android 11+ (API 30) applies video rotation accurately inside
            // getScaledFrameAtTime; older releases only scale unrotated frames
            // reliably and otherwise scale the rotated Bitmap afterwards.
            val canScaleInRetriever = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 &&
                    (rotation == 0 || rotation == 180))
            val displayWidth = if (rotation == 90 || rotation == 270) rawHeight else rawWidth
            val displayHeight = if (rotation == 90 || rotation == 270) rawWidth else rawHeight
            val scaledTarget = if (canScaleInRetriever &&
                displayWidth != null && displayHeight != null &&
                displayWidth > 0 && displayHeight > 0
            ) {
                val scale = (maxEdge.toFloat() / max(displayWidth, displayHeight)).coerceAtMost(1f)
                Pair(
                    (displayWidth * scale).roundToInt().coerceAtLeast(1),
                    (displayHeight * scale).roundToInt().coerceAtLeast(1),
                )
            } else {
                null
            }

            val clipMs = durationMs.coerceAtMost(maxDurationMs.toLong())
            val count = when {
                clipMs <= 0L -> 1
                clipMs < 400L -> 2
                else -> (clipMs / 250L).toInt().coerceIn(4, maxFrames)
            }
            val stepMs = if (clipMs > 0L) clipMs.toDouble() / count else 200.0
            val delayMs = stepMs.roundToInt().coerceIn(80, 500)

            val frames = ArrayList<ByteArray>(count)
            val startedMs = SystemClock.elapsedRealtime()
            for (i in 0 until count) {
                if (frames.size >= 2 && SystemClock.elapsedRealtime() - startedMs > 3_500L) {
                    break
                }
                val atMs = if (durationMs > 0L) {
                    ((i + 0.25) * stepMs).toLong().coerceIn(0L, (durationMs - 1L).coerceAtLeast(0L))
                } else {
                    0L
                }
                val timeUs = atMs * 1000L
                val encoded = extractScaledJpeg(
                    retriever,
                    timeUs = timeUs,
                    option = MediaMetadataRetriever.OPTION_CLOSEST,
                    scaledTarget = scaledTarget,
                    maxEdge = maxEdge,
                ) ?: if (frames.isEmpty()) {
                    extractScaledJpeg(
                        retriever,
                        timeUs = timeUs,
                        option = MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        scaledTarget = scaledTarget,
                        maxEdge = maxEdge,
                    )
                } else {
                    null
                }
                if (encoded != null) {
                    frames.add(encoded)
                }
            }
            if (frames.isEmpty()) return null
            val distinct = if (frames.size > 1 && frames.all { it.contentEquals(frames.first()) }) {
                listOf(frames.first())
            } else {
                frames
            }
            return mapOf(
                "frames" to distinct,
                "delayMs" to delayMs,
            )
        } finally {
            try {
                retriever.release()
            } catch (error: IOException) {
                // Nothing left to release.
            }
        }
    }

    private fun extractScaledJpeg(
        retriever: MediaMetadataRetriever,
        timeUs: Long,
        option: Int,
        scaledTarget: Pair<Int, Int>?,
        maxEdge: Int,
    ): ByteArray? {
        val raw = try {
            if (scaledTarget != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(
                    timeUs,
                    option,
                    scaledTarget.first,
                    scaledTarget.second,
                )
            } else {
                retriever.getFrameAtTime(timeUs, option)
            }
        } catch (error: Exception) {
            null
        } ?: return null
        var scaled: Bitmap? = null
        try {
            val longSide = max(raw.width, raw.height)
            val target = if (longSide > maxEdge) {
                val ratio = maxEdge.toFloat() / longSide
                Bitmap.createScaledBitmap(
                    raw,
                    (raw.width * ratio).roundToInt().coerceAtLeast(1),
                    (raw.height * ratio).roundToInt().coerceAtLeast(1),
                    true,
                ).also { scaled = it }
            } else {
                raw
            }
            val out = ByteArrayOutputStream()
            target.compress(Bitmap.CompressFormat.JPEG, 85, out)
            return out.toByteArray()
        } finally {
            if (scaled != null && scaled !== raw) scaled.recycle()
            raw.recycle()
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
