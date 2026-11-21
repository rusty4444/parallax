package net.samrussell.parallax

import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * On-device voice-message transcription for Dart
 * (lib/features/transcription). Uses Android's SpeechRecognizer (preferring the
 * on-device recognizer on Android 12+). The audio file is played once through
 * the media stream while the recognizer listens; nothing is uploaded. Devices
 * without a speech recognizer report UNSUPPORTED so the UI can say so.
 */
object SpeechTools {
    const val CHANNEL = "parallax/speech"
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel {
        val app = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> {
                    val available = SpeechRecognizer.isRecognitionAvailable(app)
                    result.success(available)
                }
                "transcribe" -> {
                    val path = call.argument<String>("path")
                    if (path == null || !File(path).exists()) {
                        result.error("INVALID_ARGUMENT", "Missing audio file", null)
                        return@setMethodCallHandler
                    }
                    if (!SpeechRecognizer.isRecognitionAvailable(app)) {
                        result.error("UNSUPPORTED", "No speech recognizer on this device", null)
                        return@setMethodCallHandler
                    }
                    main.post { transcribe(app, path, result) }
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    private fun transcribe(context: Context, path: String, result: MethodChannel.Result) {
        val recognizer = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } else {
                SpeechRecognizer.createSpeechRecognizer(context)
            }
        } catch (error: Exception) {
            result.error("UNSUPPORTED", error.message, null)
            return
        }
        val player = MediaPlayer()
        val collected = StringBuilder()
        var settled = false

        fun finish(text: String?, error: String?) {
            if (settled) return
            settled = true
            try { player.release() } catch (_: Exception) {}
            try { recognizer.destroy() } catch (_: Exception) {}
            if (error != null) {
                result.error("TRANSCRIBE_FAILED", error, null)
            } else {
                result.success(text ?: "")
            }
        }

        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                if (!matches.isNullOrEmpty()) {
                    collected.setLength(0)
                    collected.append(matches[0])
                }
            }
            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = if (!matches.isNullOrEmpty()) matches[0] else collected.toString()
                finish(text, null)
            }
            override fun onError(error: Int) {
                // No match / timeout still returns whatever was collected.
                if (collected.isNotEmpty()) {
                    finish(collected.toString(), null)
                } else {
                    finish(null, "Recognizer error $error")
                }
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        try {
            player.setDataSource(path)
            player.setOnPreparedListener {
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.EXTRA_FORMATTING_TYPE_NONE)
                    }
                }
                recognizer.startListening(intent)
                player.start()
            }
            player.setOnCompletionListener {
                // Give the recognizer a moment to flush final results.
                main.postDelayed({
                    if (!settled) {
                        if (collected.isNotEmpty()) finish(collected.toString(), null)
                        else finish("", null)
                    }
                }, 1500)
            }
            player.setOnErrorListener { _, what, extra ->
                finish(null, "Playback error $what/$extra")
                true
            }
            player.prepareAsync()
            // Safety timeout so a stuck recognizer never hangs the call.
            main.postDelayed({ finish(collected.toString().ifEmpty { null }, if (collected.isEmpty()) "Timed out" else null) }, 60000)
        } catch (error: Exception) {
            finish(null, error.message)
        }
    }
}
