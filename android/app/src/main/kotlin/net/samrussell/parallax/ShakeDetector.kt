package net.samrussell.parallax

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

/**
 * Optional shake-to-report (lib/features/bug_report). Listens to the
 * accelerometer only while enabled and tells Dart when a shake is detected.
 */
object ShakeDetector : SensorEventListener {
    const val CHANNEL = "parallax/shake"
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var sensorManager: SensorManager? = null
    private var enabled = false
    private var lastShake = 0L
    private var lastMagnitude = 0f

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel {
        sensorManager = context.applicationContext
            .getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    enabled = call.argument<Boolean>("enabled") ?: false
                    updateListening()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return ch
    }

    private fun updateListening() {
        val manager = sensorManager ?: return
        val accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (enabled && accelerometer != null) {
            manager.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_UI)
        } else {
            manager.unregisterListener(this)
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return
        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]
        val magnitude = sqrt((x * x + y * y + z * z).toDouble()).toFloat()
        val delta = kotlin.math.abs(magnitude - lastMagnitude)
        lastMagnitude = magnitude
        val now = System.currentTimeMillis()
        if (delta > 18f && now - lastShake > 1500L) {
            lastShake = now
            main.post { channel?.invokeMethod("shake", null) }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
