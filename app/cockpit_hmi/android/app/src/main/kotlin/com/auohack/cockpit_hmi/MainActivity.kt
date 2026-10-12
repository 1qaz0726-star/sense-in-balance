package com.auohack.cockpit_hmi

import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var recognizer: SpeechRecognizer? = null
    private var speechReply: MethodChannel.Result? = null
    private val speechHandler = Handler(Looper.getMainLooper())
    private var speechTimeout: Runnable? = null
    private var speechLanguage = "zh-TW"
    private val speechPermissionRequest = 4701

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sense_in_balance/repair_speech")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(offlineSpeechAvailable())
                    "cancel" -> {
                        finishSpeechError("cancelled", "已取消語音輸入。")
                        result.success(null)
                    }
                    "recognize" -> {
                        if (speechReply != null) {
                            result.error("busy", "語音輸入仍在進行。", null)
                        } else if (!offlineSpeechAvailable()) {
                            result.error("unavailable", "此裝置尚未準備離線語音，請先輸入文字。", null)
                        } else {
                            speechReply = result
                            speechLanguage = call.argument<String>("language") ?: "zh-TW"
                            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), speechPermissionRequest)
                            } else {
                                beginOfflineSpeech()
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun offlineSpeechAvailable(): Boolean =
        Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != speechPermissionRequest || speechReply == null) return
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            beginOfflineSpeech()
        } else {
            finishSpeechError("permission_denied", "未取得麥克風權限，請先輸入文字。")
        }
    }

    private fun beginOfflineSpeech() {
        if (speechReply == null) return
        if (Build.VERSION.SDK_INT < 31 || !offlineSpeechAvailable()) {
            finishSpeechError("unavailable", "此裝置尚未準備離線語音，請先輸入文字。")
            return
        }
        try {
            // Strict on-device factory. Never silently fall back to the generic
            // recognizer, whose provider may send audio to a remote service.
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            recognizer!!.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onError(error: Int) {
                    val message = when (error) {
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "未取得麥克風權限。"
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "沒有聽清楚，請重試或輸入文字。"
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "此裝置尚未準備繁體中文離線語音，請先輸入文字。"
                        else -> "離線語音未完成，請重試或輸入文字。"
                    }
                    finishSpeechError("recognition_$error", message)
                }
                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()
                    val reply = speechReply ?: return
                    speechReply = null
                    clearSpeech()
                    if (text.isNullOrEmpty()) {
                        reply.error("no_match", "沒有聽清楚，請輸入文字。", null)
                    } else {
                        reply.success(mapOf("text" to text, "on_device" to true, "language" to speechLanguage))
                    }
                }
            })
            speechTimeout = Runnable { finishSpeechError("timeout", "語音輸入逾時，請重試或輸入文字。") }
            speechHandler.postDelayed(speechTimeout!!, 20000)
            recognizer!!.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLanguage)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            })
        } catch (_: Exception) {
            finishSpeechError("unavailable", "離線語音尚未就緒，請先輸入文字。")
        }
    }

    private fun finishSpeechError(code: String, message: String) {
        val reply = speechReply
        speechReply = null
        clearSpeech()
        reply?.error(code, message, null)
    }

    private fun clearSpeech() {
        speechTimeout?.let { speechHandler.removeCallbacks(it) }
        speechTimeout = null
        val previous = recognizer
        recognizer = null
        previous?.cancel()
        previous?.destroy()
    }

    override fun onDestroy() {
        finishSpeechError("cancelled", "語音輸入已結束。")
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 座艙螢幕不該自己熄滅（拍片時也不會中途黑屏）
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
