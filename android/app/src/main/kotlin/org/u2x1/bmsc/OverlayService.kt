package org.u2x1.bmsc

import android.animation.ValueAnimator
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

/// 悬浮窗识曲气泡：前台服务（type=microphone，后台录音的系统要求）+
/// 可拖拽气泡（品牌蓝圆形 + 音符，录音时脉冲呼吸）+ 圆角深色状态面板。
/// Dart 侧经 bmsc/overlay MethodChannel 驱动。
class OverlayService : Service() {

  companion object {
    var channel: MethodChannel? = null
    private var instance: OverlayService? = null

    fun isGranted(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)

    fun requestPermission(activity: android.app.Activity) {
      activity.startActivity(
        Intent(
          Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
          Uri.parse("package:${activity.packageName}"),
        ),
      )
    }

    fun start(ctx: Context) {
      if (!isGranted(ctx)) return
      ContextCompat.startForegroundService(ctx, Intent(ctx, OverlayService::class.java))
    }

    fun stop(ctx: Context) {
      ctx.stopService(Intent(ctx, OverlayService::class.java))
    }

    fun update(status: String, text: String, keyword: String?) {
      instance?.updatePanel(status, text, keyword)
    }
  }

  private lateinit var wm: WindowManager
  private var bubble: ImageView? = null
  private var panel: LinearLayout? = null
  private var resultKeyword: String? = null
  private var pulse: ValueAnimator? = null

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    instance = this
    startFg()
    wm = getSystemService(WINDOW_SERVICE) as WindowManager
    addBubble()
  }

  override fun onDestroy() {
    instance = null
    pulse?.cancel()
    bubble?.let { runCatching { wm.removeView(it) } }
    panel?.let { runCatching { wm.removeView(it) } }
    super.onDestroy()
  }

  private fun startFg() {
    val channelId = "overlay_recog"
    val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(
        NotificationChannel(channelId, "悬浮窗识曲", NotificationManager.IMPORTANCE_LOW),
      )
    }
    val n = NotificationCompat.Builder(this, channelId)
      .setSmallIcon(android.R.drawable.ic_btn_speak_now)
      .setContentTitle("BMSC 悬浮窗识曲运行中")
      .setOngoing(true)
      .build()
    if (Build.VERSION.SDK_INT >= 29) {
      startForeground(42, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
    } else {
      startForeground(42, n)
    }
  }

  private fun overlayType(): Int =
    if (Build.VERSION.SDK_INT >= 26) {
      WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
      @Suppress("DEPRECATION")
      WindowManager.LayoutParams.TYPE_PHONE
    }

  private fun lp(): WindowManager.LayoutParams {
    val p = WindowManager.LayoutParams(
      WindowManager.LayoutParams.WRAP_CONTENT,
      WindowManager.LayoutParams.WRAP_CONTENT,
      overlayType(),
      WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
      PixelFormat.TRANSLUCENT,
    )
    p.gravity = Gravity.TOP or Gravity.START
    return p
  }

  private fun addBubble() {
    val iv = ImageView(this)
    iv.setImageResource(R.drawable.ic_overlay_music)
    iv.setBackgroundResource(R.drawable.overlay_bubble_bg)
    val d = (48 * resources.displayMetrics.density).toInt()
    val pad = (12 * resources.displayMetrics.density).toInt()
    iv.layoutParams = LinearLayout.LayoutParams(d, d)
    iv.setPadding(pad, pad, pad, pad)
    iv.elevation = 8 * resources.displayMetrics.density
    val p = lp()
    p.x = 24
    p.y = 320
    var downX = 0f
    var downY = 0f
    var moved = false
    iv.setOnTouchListener { v, e ->
      when (e.action) {
        MotionEvent.ACTION_DOWN -> {
          downX = e.rawX
          downY = e.rawY
          moved = false
          true
        }
        MotionEvent.ACTION_MOVE -> {
          val dx = e.rawX - downX
          val dy = e.rawY - downY
          if (abs(dx) > 12 || abs(dy) > 12) moved = true
          if (moved) {
            p.x = (p.x + dx).toInt()
            p.y = (p.y + dy).toInt()
            wm.updateViewLayout(v, p)
            downX = e.rawX
            downY = e.rawY
          }
          true
        }
        MotionEvent.ACTION_UP -> {
          if (!moved) onTap()
          true
        }
        else -> false
      }
    }
    wm.addView(iv, p)
    bubble = iv
  }

  /// 录音/识别中气泡脉冲呼吸
  private fun setPulsing(on: Boolean) {
    val b = bubble ?: return
    if (on && pulse == null) {
      pulse = ValueAnimator.ofFloat(1f, 1.12f).apply {
        duration = 700
        repeatMode = ValueAnimator.REVERSE
        repeatCount = ValueAnimator.INFINITE
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener {
          val s = it.animatedValue as Float
          b.scaleX = s
          b.scaleY = s
        }
        start()
      }
    } else if (!on) {
      pulse?.cancel()
      pulse = null
      b.scaleX = 1f
      b.scaleY = 1f
    }
  }

  private fun onTap() {
    if (panel == null) showPanel("正在聆听…", "")
    channel?.invokeMethod("overlayTap", null)
  }

  private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

  private fun showPanel(status: String, text: String, keyword: String? = null) {
    val ll = LinearLayout(this)
    ll.orientation = LinearLayout.VERTICAL
    ll.setPadding(dp(16), dp(12), dp(16), dp(10))
    ll.setBackgroundResource(R.drawable.overlay_panel_bg)
    ll.elevation = 10 * resources.displayMetrics.density

    val titleRow = LinearLayout(this)
    titleRow.orientation = LinearLayout.HORIZONTAL
    val st = TextView(this)
    st.setTextColor(0xFFFFFFFF.toInt())
    st.textSize = 15f
    st.setTypeface(st.typeface, android.graphics.Typeface.BOLD)
    st.tag = "status"
    st.maxLines = 2
    st.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    val close = TextView(this)
    close.text = "✕"
    close.setTextColor(0xFF8AB4F8.toInt())
    close.textSize = 16f
    close.setPadding(dp(10), 0, 0, 0)
    close.setOnClickListener { stopSelf() }
    titleRow.addView(st)
    titleRow.addView(close)

    val tx = TextView(this)
    tx.setTextColor(0xFFB3FFFFFF.toInt())
    tx.textSize = 13f
    tx.tag = "text"
    tx.setPadding(0, dp(2), 0, 0)
    tx.setOnClickListener {
      val kw = resultKeyword
      if (!kw.isNullOrEmpty()) {
        val i = packageManager.getLaunchIntentForPackage(packageName)
        i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        i?.putExtra("recognize_keyword", kw)
        runCatching { startActivity(i) }
      }
    }

    val hint = TextView(this)
    hint.text = "→ 点此在 App 内搜索"
    hint.setTextColor(0xFF8AB4F8.toInt())
    hint.textSize = 12f
    hint.tag = "hint"
    hint.setPadding(0, dp(4), 0, 0)
    hint.setOnClickListener { tx.performClick() }

    ll.addView(titleRow)
    ll.addView(tx)
    ll.addView(hint)

    val p = lp()
    p.x = 24
    p.y = 460
    p.width = dp(220)
    wm.addView(ll, p)
    panel = ll
    updatePanel(status, text, keyword)
  }

  fun updatePanel(status: String, text: String, keyword: String?) {
    resultKeyword = keyword
    setPulsing(status.startsWith("正在聆听") || status.startsWith("识别中"))
    val ll = panel ?: return showPanel(status, text, keyword)
    ll.findViewWithTag<TextView>("status")?.text = status
    ll.findViewWithTag<TextView>("text")?.text = text
    ll.findViewWithTag<TextView>("hint")?.visibility =
      if (keyword.isNullOrEmpty()) View.GONE else View.VISIBLE
  }
}
