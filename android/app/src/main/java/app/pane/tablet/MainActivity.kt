package app.pane.tablet

import android.content.pm.ActivityInfo
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.InputDevice
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import kotlin.math.roundToInt
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

class MainActivity : AppCompatActivity() {
    private lateinit var connectPanel: View
    private lateinit var surfaceView: SurfaceView
    private lateinit var touchLayer: View
    private lateinit var cursor: CursorOverlay
    private lateinit var hud: TextView
    private lateinit var status: TextView

    private var session: StreamSession? = null
    private var touch: TouchRelay? = null
    private var probe: GestureProbe? = null
    private var streaming = false
    private val usbHandler = Handler(Looper.getMainLooper())
    private var preferUsb = true
    private var revealed = false
    private var streamFps = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        connectPanel = findViewById(R.id.connectPanel)
        surfaceView = findViewById(R.id.surface)
        touchLayer = findViewById(R.id.touchLayer)
        cursor = findViewById(R.id.cursor)
        hud = findViewById(R.id.hud)
        status = findViewById(R.id.status)

        findViewById<Button>(R.id.usb).setOnClickListener {
            preferUsb = true
            attemptUsb()
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                session?.attachSurface(holder.surface)
                matchRefreshRate()
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                session?.attachSurface(holder.surface)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                session?.attachSurface(null)
            }
        })

        touch = TouchRelay(
            view = touchLayer,
            sendPointer = { phase, tool, id, x, y, pressure ->
                session?.sendPointer(phase, tool, id, x, y, pressure)
            },
            sendScroll = { dx, dy, phase -> session?.sendScroll(dx, dy, phase) },
            sendPinch = { phase, magnification, x, y -> session?.sendPinch(phase, magnification, x, y) }
        )
        touch?.onLocalCursor = { x, y -> cursor.showAt(x, y) }
        touchLayer.setOnTouchListener { _, event -> touch?.onTouch(event) ?: false }
        touchLayer.setOnGenericMotionListener { _, event -> touch?.onHover(event) ?: false }
        probe = GestureProbe(touchLayer).also { it.register(this) }

        onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (streaming) {
                    preferUsb = false
                    disconnect("Disconnected. Tap Connect with USB cable to use the cable again.")
                } else {
                    finish()
                }
            }
        })

        usbHandler.postDelayed({ attemptUsb() }, 400)
    }

    override fun onDestroy() {
        probe?.unregister(this)
        preferUsb = false
        usbHandler.removeCallbacksAndMessages(null)
        session?.close()
        session = null
        super.onDestroy()
    }

    private fun attemptUsb() {
        if (!preferUsb || streaming || isFinishing) return
        status.text = "Connecting over the USB cable…"
        connect()
    }

    private fun connect() {
        if (streaming) return
        streaming = true
        revealed = false
        surfaceView.visibility = View.VISIBLE
        status.text = "Connecting over the USB cable…"

        val panel = panelDescription()
        val created = StreamSession(
            port = 47777,
            deviceName = deviceLabel(),
            screenWidth = panel.width,
            screenHeight = panel.height,
            refreshHz = panel.refresh,
            capabilities = panel.capabilities,
            densityDpi = panel.density,
            onState = { message ->
                ui {
                    if (!revealed && message.startsWith("Connected")) revealSession()
                    if (revealed) hud.text = message else if (!preferUsb) status.text = message
                }
            },
            onVideoSize = { width, height, fps ->
                ui {
                    streamFps = fps
                    matchRefreshRate()
                    touch?.videoWidth = width
                    touch?.videoHeight = height
                    cursor.videoWidth = width
                    cursor.videoHeight = height
                    requestedOrientation = if (height > width) {
                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                    } else {
                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    }
                }
            },
            onFirstFrame = { ui { hud.visibility = View.GONE } },
            onClosed = { _ ->
                ui {
                    val retry = preferUsb
                    if (streaming) {
                        disconnect(
                            if (retry) "Waiting for the USB cable…" else "Disconnected.",
                            keepUsb = retry
                        )
                    }
                    if (retry) usbHandler.postDelayed({ attemptUsb() }, 1000)
                }
            },
            connectTimeoutMs = 1200,
            onRemoteCursor = { x, y, visible ->
                ui {
                    if (touch?.drivingCursor == true) return@ui
                    if (visible) cursor.showAt(x, y) else cursor.hide()
                }
            },
            onCursorImage = { image -> ui { cursor.setImage(image) } }
        )
        session = created
        if (surfaceView.holder.surface?.isValid == true) {
            created.attachSurface(surfaceView.holder.surface)
        }
        created.start()
    }

    private fun revealSession() {
        revealed = true
        connectPanel.visibility = View.GONE
        surfaceView.visibility = View.VISIBLE
        cursor.visibility = View.VISIBLE
        touchLayer.visibility = View.VISIBLE
        hud.visibility = View.VISIBLE
        hud.text = "Connected over USB. Waiting for the picture…"
        enterFullscreen()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun disconnect(message: String, keepUsb: Boolean = false) {
        if (!keepUsb) preferUsb = false
        streaming = false
        revealed = false
        session?.close()
        session = null
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        surfaceView.visibility = View.GONE
        cursor.visibility = View.GONE
        cursor.hide()
        touchLayer.visibility = View.GONE
        hud.visibility = View.GONE
        connectPanel.visibility = View.VISIBLE
        status.text = message
        exitFullscreen()
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    /**
     * Samsung's adaptive refresh can leave a video surface at 60 Hz or lower. Ask for the panel's
     * fastest mode at this resolution and tell the compositor how often frames will come.
     */
    private fun matchRefreshRate() {
        val fps = streamFps
        if (fps <= 0) return
        val display = surfaceView.display ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate }
        if (best != null && window.attributes.preferredDisplayModeId != best.modeId) {
            window.attributes = window.attributes.also { it.preferredDisplayModeId = best.modeId }
        }
        val surface = surfaceView.holder.surface
        if (Build.VERSION.SDK_INT >= 30 && surface.isValid) {
            try {
                surface.setFrameRate(fps.toFloat(), android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            } catch (_: Exception) {
            }
        }
    }

    private fun enterFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    private fun exitFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, true)
        WindowInsetsControllerCompat(window, window.decorView).show(WindowInsetsCompat.Type.systemBars())
    }

    private data class Panel(val width: Int, val height: Int, val refresh: Int, val capabilities: Int, val density: Int)

    /**
     * The panel as it is held right now, its fastest refresh, and whether a stylus is present.
     * Samsung lists modes in the panel's install orientation, which is portrait for this tablet
     * even while the picture is landscape, so the size comes from the rotated real metrics.
     */
    private fun panelDescription(): Panel {
        val display = this.display
            ?: (getSystemService(DISPLAY_SERVICE) as DisplayManager).getDisplay(Display.DEFAULT_DISPLAY)
        val real = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        display.getRealMetrics(real)
        val width = real.widthPixels
        val height = real.heightPixels
        val refresh = display.supportedModes
            .filter {
                (it.physicalWidth == width && it.physicalHeight == height) ||
                    (it.physicalWidth == height && it.physicalHeight == width)
            }
            .maxOfOrNull { it.refreshRate }
            ?: display.mode.refreshRate
        var capabilities = 0x1
        if (hasStylus()) capabilities = capabilities or 0x2 or 0x4
        return Panel(
            width = width,
            height = height,
            refresh = refresh.roundToInt().coerceIn(1, 240),
            capabilities = capabilities,
            density = real.xdpi.roundToInt().coerceIn(0, 1000)
        )
    }

    private fun hasStylus(): Boolean {
        if (packageManager.hasSystemFeature("android.hardware.touchscreen.stylus")) return true
        return InputDevice.getDeviceIds().any { id ->
            InputDevice.getDevice(id)?.supportsSource(InputDevice.SOURCE_STYLUS) == true
        }
    }

    private fun deviceLabel(): String {
        val model = Build.MODEL ?: ""
        return when {
            model.startsWith("SM-X71") -> "Galaxy Tab S9"
            model.startsWith("SM-X81") -> "Galaxy Tab S9+"
            model.startsWith("SM-X91") || model.startsWith("SM-X916") -> "Galaxy Tab S9 Ultra"
            model.isBlank() -> "Android tablet"
            else -> model
        }
    }

    private fun ui(block: () -> Unit) {
        runOnUiThread(block)
    }
}
