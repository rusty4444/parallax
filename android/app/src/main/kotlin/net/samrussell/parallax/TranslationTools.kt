package net.samrussell.parallax

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Strictly on-device translation for Dart (lib/features/translation). Uses
 * Google ML Kit Translate + Language Identification. Language models download
 * once per language; no translated text ever leaves the device.
 */
object TranslationTools {
    const val CHANNEL = "parallax/translation"
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel {
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "identify" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("INVALID_ARGUMENT", "Missing text", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        try {
                            val client = LanguageIdentification.getClient()
                            val code = Tasks.await(client.identifyLanguage(text))
                            client.close()
                            main.post { result.success(if (code == "und") null else code) }
                        } catch (error: Exception) {
                            main.post { result.error("IDENTIFY_FAILED", error.message, null) }
                        }
                    }
                }
                "translate" -> {
                    val text = call.argument<String>("text")
                    val target = call.argument<String>("target")
                    var source = call.argument<String>("source")
                    if (text == null || target == null) {
                        result.error("INVALID_ARGUMENT", "Missing text/target", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        var translator: com.google.mlkit.nl.translate.Translator? = null
                        try {
                            if (source == null || source == "auto") {
                                val idClient = LanguageIdentification.getClient()
                                source = Tasks.await(idClient.identifyLanguage(text))
                                idClient.close()
                                if (source == "und") {
                                    main.post { result.error("UNDETECTED", "Could not detect the language", null) }
                                    return@execute
                                }
                            }
                            if (source == target) {
                                main.post { result.success(text) }
                                return@execute
                            }
                            val options = TranslatorOptions.Builder()
                                .setSourceLanguage(source!!)
                                .setTargetLanguage(target)
                                .build()
                            translator = Translation.getClient(options)
                            // Downloads the model on first use (idempotent).
                            Tasks.await(translator.downloadModelIfNeeded())
                            val translated = Tasks.await(translator.translate(text))
                            main.post { result.success(translated) }
                        } catch (error: Exception) {
                            main.post { result.error("TRANSLATE_FAILED", error.message, null) }
                        } finally {
                            translator?.close()
                        }
                    }
                }
                "languages" -> {
                    val codes = TranslateLanguage.getAllLanguages().toList().sorted()
                    result.success(codes)
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }
}
