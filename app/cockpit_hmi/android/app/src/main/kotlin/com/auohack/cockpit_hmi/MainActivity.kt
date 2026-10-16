package com.auohack.cockpit_hmi

import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.io.File
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
    private val recordPermissionRequest = 4702
    private var recorder: MediaRecorder? = null
    private var recordFile: File? = null
    private var recordReply: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sense_in_balance/repair_speech")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(offlineSpeechAvailable())
                    "prepareLanguage" -> prepareLanguage(call.argument<String>("language") ?: "zh-TW", result)
                    "recordStart" -> recordStart(result)
                    "recordStop" -> recordStop(result)
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

    private fun speechIntent(language: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
    }

    /** 語言標籤可能是 zh-TW 或 cmn-Hant-TW；同一個語言都算。 */
    private fun sameLanguage(tag: String, language: String): Boolean {
        val t = tag.lowercase()
        val l = language.lowercase()
        if (t == l) return true
        return l.endsWith("-tw") && t.endsWith("-tw") && (t.startsWith("zh") || t.startsWith("cmn"))
    }

    /**
     * Android 13+：查繁中離線語言包，沒裝就請系統下載（只下載語言包，不改用雲端辨識）。
     * 回傳 status：installed／downloading／unsupported／unavailable。
     */
    private fun prepareLanguage(language: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || !offlineSpeechAvailable()) {
            result.success(mapOf("status" to "unavailable"))
            return
        }
        val checker = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        } catch (_: Exception) {
            result.success(mapOf("status" to "unavailable")); return
        }
        var replied = false
        fun reply(value: Map<String, Any?>) {
            if (replied) return
            replied = true
            speechHandler.post { checker.destroy() }
            result.success(value)
        }
        val intent = speechIntent(language)
        checker.checkRecognitionSupport(intent, mainExecutor, object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
                val installed = support.installedOnDeviceLanguages
                val pending = support.pendingOnDeviceLanguages
                val supported = support.supportedOnDeviceLanguages
                val detail = mapOf("installed" to installed, "pending" to pending, "supported" to supported)
                when {
                    installed.any { sameLanguage(it, language) } -> reply(detail + ("status" to "installed"))
                    pending.any { sameLanguage(it, language) } -> reply(detail + ("status" to "downloading"))
                    supported.any { sameLanguage(it, language) } -> {
                        try {
                            checker.triggerModelDownload(intent)
                            reply(detail + ("status" to "downloading"))
                        } catch (_: Exception) {
                            reply(detail + ("status" to "unsupported"))
                        }
                    }
                    else -> reply(detail + ("status" to "unsupported"))
                }
            }
            override fun onError(error: Int) {
                reply(mapOf("status" to "unavailable", "error" to error))
            }
        })
    }

    /** 錄一段 16kHz 單聲道 AAC（約 2 KB/秒），給連網時的台語辨識用。 */
    private fun recordStart(result: MethodChannel.Result) {
        if (recorder != null) { result.error("busy", "錄音仍在進行。", null); return }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            recordReply = result
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), recordPermissionRequest)
            return
        }
        beginRecording(result)
    }

    private fun beginRecording(result: MethodChannel.Result) {
        try {
            val file = File(cacheDir, "utterance.m4a").also { it.delete() }
            val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
            r.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16000)
            r.setAudioEncodingBitRate(24000)
            r.setOutputFile(file.absolutePath)
            r.prepare()
            r.start()
            recorder = r
            recordFile = file
            result.success(true)
        } catch (e: Exception) {
            recorder?.release(); recorder = null
            result.error("record_failed", "無法開始錄音。", null)
        }
    }

    private fun recordStop(result: MethodChannel.Result) {
        val r = recorder
        val file = recordFile
        recorder = null
        recordFile = null
        if (r == null || file == null) { result.error("idle", "沒有進行中的錄音。", null); return }
        try {
            r.stop()
            r.release()
            result.success(file.readBytes())
        } catch (_: Exception) {
            r.release()
            result.error("too_short", "錄音太短，請再說一次。", null)
        }
    }

    private fun offlineSpeechAvailable(): Boolean =
        Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == recordPermissionRequest) {
            val reply = recordReply ?: return
            recordReply = null
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                beginRecording(reply)
            } else {
                reply.error("permission_denied", "未取得麥克風權限。", null)
            }
            return
        }
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
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "繁體中文離線語音尚未下載完成，已請系統下載，請先輸入文字。"
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
        recorder?.release()
        recorder = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 座艙螢幕不該自己熄滅（拍片時也不會中途黑屏）
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
