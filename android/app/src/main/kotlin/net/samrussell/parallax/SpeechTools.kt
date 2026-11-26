package net.samrussell.parallax

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * On-device transcription of voice and audio messages for Dart
 * (lib/features/transcription). The file is decoded to 16 kHz mono PCM here
 * and streamed straight into Android's speech recogniser (Android 13+
 * EXTRA_AUDIO_SOURCE), preferring the on-device recogniser: nothing plays
 * aloud, the microphone is not used and nothing is uploaded. A segmented
 * session keeps going across pauses until the audio ends.
 *
 * Android still requires the caller to hold RECORD_AUDIO for any
 * SpeechRecognizer use; Dart asks for it first (NO_PERMISSION otherwise).
 */
object SpeechTools {
    const val CHANNEL = "parallax/speech"
    private const val RATE = 16000
    private const val MAX_SECONDS = 15 * 60
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel {
        val app = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(available(app))
                "transcribe" -> {
                    val path = call.argument<String>("path")
                    val language = call.argument<String>("language")
                    if (path == null || !File(path).exists()) {
                        result.error("INVALID_ARGUMENT", "Missing audio file", null)
                        return@setMethodCallHandler
                    }
                    if (!available(app)) {
                        result.error("UNSUPPORTED", "No speech recogniser on this device", null)
                        return@setMethodCallHandler
                    }
                    transcribe(app, path, language, result)
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    private fun available(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            (SpeechRecognizer.isOnDeviceRecognitionAvailable(context) ||
                SpeechRecognizer.isRecognitionAvailable(context))

    private fun transcribe(
        context: Context,
        path: String,
        language: String?,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.error("UNSUPPORTED", "Transcription needs Android 13 or later", null)
            return
        }
        // Decode off the main thread, then recognise on it.
        io.execute {
            val pcm = try {
                decodeToMono16k(path)
            } catch (error: Exception) {
                main.post { result.error("DECODE_FAILED", error.message ?: "Couldn't read the audio", null) }
                return@execute
            }
            main.post { recognise(context, pcm, language, result) }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun recognise(
        context: Context,
        pcm: ByteArray,
        language: String?,
        result: MethodChannel.Result,
    ) {
        val onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        val recognizer = try {
            if (onDevice) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } else {
                SpeechRecognizer.createSpeechRecognizer(context)
            }
        } catch (error: Exception) {
            result.error("UNSUPPORTED", error.message, null)
            return
        }
        val pipe = try {
            ParcelFileDescriptor.createPipe()
        } catch (error: IOException) {
            recognizer.destroy()
            result.error("TRANSCRIBE_FAILED", error.message, null)
            return
        }
        val reader = pipe[0]
        val writer = pipe[1]
        val segments = mutableListOf<String>()
        var partial = ""
        var settled = false

        fun finish(code: String?, message: String?) {
            if (settled) return
            settled = true
            try { recognizer.destroy() } catch (_: Exception) {}
            try { reader.close() } catch (_: Exception) {}
            val text = segments.joinToString(" ").trim().ifEmpty { partial.trim() }
            when {
                code == null || text.isNotEmpty() -> result.success(text)
                else -> result.error(code, message, null)
            }
        }

        fun best(bundle: Bundle?): String =
            bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()?.trim().orEmpty()

        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {
                val text = best(partialResults)
                if (text.isNotEmpty()) partial = text
            }
            override fun onSegmentResults(segmentResults: Bundle) {
                val text = best(segmentResults)
                if (text.isNotEmpty()) segments.add(text)
                partial = ""
            }
            override fun onEndOfSegmentedSession() = finish(null, null)
            override fun onResults(results: Bundle?) {
                val text = best(results)
                if (text.isNotEmpty()) segments.add(text)
                finish(null, null)
            }
            override fun onError(error: Int) {
                val (code, message) = when (error) {
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                        "NO_PERMISSION" to "Microphone permission is needed for speech recognition"
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                        "NO_SPEECH" to "No speech was recognised"
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ->
                        "LANGUAGE" to "This language isn't supported for transcription"
                    SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
                        "LANGUAGE" to "The speech model for this language isn't downloaded yet"
                    else -> "TRANSCRIBE_FAILED" to "Recogniser error $error"
                }
                if (error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE && onDevice) {
                    // Ask the system to fetch the model for next time.
                    try { recognizer.triggerModelDownload(intent(null, language)) } catch (_: Exception) {}
                }
                finish(code, message)
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        // Feed the PCM through the pipe, then close it: the end of the audio
        // ends the segmented session.
        io.execute {
            try {
                ParcelFileDescriptor.AutoCloseOutputStream(writer).use { it.write(pcm) }
            } catch (_: IOException) {
                // The recogniser stopped reading (error or destroyed).
            }
        }
        try {
            recognizer.startListening(intent(reader, language))
        } catch (error: Exception) {
            finish("TRANSCRIBE_FAILED", error.message)
            return
        }
        // Never hang the Dart call: allow for real-time recognition plus slack.
        val seconds = pcm.size / (RATE * 2)
        main.postDelayed({ finish("TIMEOUT", "Transcription took too long") }, (seconds * 2 + 30) * 1000L)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun intent(source: ParcelFileDescriptor?, language: String?) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            if (!language.isNullOrBlank()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            if (source != null) {
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, source)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            }
        }

    /** Decodes [path] (any format MediaCodec reads) to 16 kHz mono 16-bit PCM. */
    private fun decodeToMono16k(path: String): ByteArray {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IOException("No audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            val out = ByteArrayOutputStream()
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                // Linear resampler: source position of the next output frame.
                var nextOut = 0.0
                var sourceFrame = 0L
                var previous = 0f
                val limit = MAX_SECONDS.toLong() * RATE * 2
                while (!outputDone) {
                    if (!inputDone) {
                        val index = codec.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = codec.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = codec.dequeueOutputBuffer(info, 10_000)
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val changed = codec.outputFormat
                        rate = changed.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = changed.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    } else if (index >= 0) {
                        val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val samples = buffer.asShortBuffer()
                        val step = rate.toDouble() / RATE
                        while (samples.remaining() >= channels) {
                            var sum = 0f
                            for (c in 0 until channels) sum += samples.get()
                            val mono = sum / channels
                            while (nextOut <= sourceFrame) {
                                val t = (nextOut - (sourceFrame - 1)).toFloat().coerceIn(0f, 1f)
                                val value = (previous + (mono - previous) * t).toInt().coerceIn(-32768, 32767)
                                out.write(value and 0xFF)
                                out.write((value shr 8) and 0xFF)
                                nextOut += step
                            }
                            previous = mono
                            sourceFrame++
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                        if (out.size() >= limit) outputDone = true
                    }
                }
            } finally {
                try { codec.stop() } catch (_: Exception) {}
                codec.release()
            }
            if (out.size() == 0) throw IOException("No audio decoded")
            return out.toByteArray()
        } finally {
            extractor.release()
        }
    }
}
