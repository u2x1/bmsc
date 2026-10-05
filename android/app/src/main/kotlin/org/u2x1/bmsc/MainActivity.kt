package org.u2x1.bmsc

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 继承 audio_service 插件的 Activity（Manifest 原注册的即是它），
// 在此基础上挂悬浮窗识曲的 MethodChannel。
class MainActivity : AudioServiceActivity() {
  private var channel: MethodChannel? = null

  // 识别历史片段试听：App 定制的 just_audio_background 只支持单播放器实例
  // （lib/audio/just_audio_background_custom.dart），第二个 AudioPlayer 必抛
  // PlatformException——Android 侧用原生 MediaPlayer 兜底，Dart 侧轮询位置。
  private var clipPlayer: android.media.MediaPlayer? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bmsc/overlay")
    channel?.setMethodCallHandler { call, result ->
      when (call.method) {
        "playClip" -> {
          try {
            clipPlayer?.release()
            val mp = android.media.MediaPlayer()
            mp.setDataSource(call.argument<String>("path"))
            mp.prepare()
            mp.start()
            clipPlayer = mp
            result.success(mp.duration)
          } catch (e: Exception) {
            clipPlayer = null
            result.error("clip", e.message, null)
          }
        }
        "stopClip" -> {
          clipPlayer?.release()
          clipPlayer = null
          result.success(null)
        }
        "clipPosition" -> result.success(
          runCatching { clipPlayer?.currentPosition ?: 0 }.getOrDefault(0),
        )
        "isGranted" -> result.success(OverlayService.isGranted(this))
        "requestPermission" -> {
          OverlayService.requestPermission(this)
          result.success(null)
        }
        "show" -> {
          OverlayService.start(this)
          result.success(null)
        }
        "hide" -> {
          OverlayService.stop(this)
          result.success(null)
        }
        "setStatus" -> {
          OverlayService.update(
            call.argument<String>("status") ?: "",
            call.argument<String>("text") ?: "",
            call.argument<String>("keyword"),
          )
          result.success(null)
        }
        else -> result.notImplemented()
      }
    }
    OverlayService.channel = channel
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    intent.getStringExtra("recognize_keyword")?.let {
      channel?.invokeMethod("openSearch", it)
    }
  }

  override fun onDestroy() {
    OverlayService.channel = null
    clipPlayer?.release()
    clipPlayer = null
    super.onDestroy()
  }
}
