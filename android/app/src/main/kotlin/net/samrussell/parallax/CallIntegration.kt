package net.samrussell.parallax

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Native call integration for Dart (lib/features/call/call_integration.dart):
 * picture-in-picture, in-call audio routing, a full-screen incoming-call
 * notification and a self-managed Telecom connection so the system treats
 * Parallax calls as calls (Bluetooth buttons, audio focus, call state).
 */
object CallIntegration {
    const val CHANNEL = "parallax/call_integration"
    private const val CALL_CHANNEL_ID = "parallax_calls_v1"
    private const val INCOMING_ID = 7401
    private const val ACCOUNT_ID = "parallax_call_account"

    private var activity: FlutterFragmentActivity? = null
    private var telecomRegistered = false

    fun register(activity: FlutterFragmentActivity, messenger: BinaryMessenger): MethodChannel {
        this.activity = activity
        val app = activity.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    val ok = enterPip(activity)
                    result.success(ok)
                }
                "setAutoPip" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(setAutoPip(activity, enabled))
                }
                "audioOutputs" -> result.success(audioOutputs(app))
                "setAudioOutput" -> {
                    val id = call.argument<Int>("id")
                    result.success(setAudioOutput(app, id))
                }
                "showIncomingCall" -> {
                    val name = call.argument<String>("name") ?: "Incoming call"
                    val audioOnly = call.argument<Boolean>("audioOnly") ?: false
                    showIncomingCall(app, name, audioOnly)
                    registerTelecom(app)
                    result.success(null)
                }
                "dismissIncomingCall" -> {
                    dismissIncomingCall(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    fun unregister() {
        activity = null
    }

    private fun enterPip(activity: FlutterFragmentActivity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val params = android.app.PictureInPictureParams.Builder()
                .setAspectRatio(android.util.Rational(16, 9))
                .build()
            activity.enterPictureInPictureMode(params)
            true
        } catch (error: Exception) {
            false
        }
    }

    private fun setAutoPip(activity: FlutterFragmentActivity, enabled: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            val params = android.app.PictureInPictureParams.Builder()
                .setAspectRatio(android.util.Rational(16, 9))
                .setAutoEnterEnabled(enabled)
                .build()
            activity.setPictureInPictureParams(params)
            true
        } catch (error: Exception) {
            false
        }
    }

    private fun audioOutputs(context: Context): List<Map<String, Any>> {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return emptyList()
        val devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.map { device ->
            mapOf(
                "id" to device.id,
                "name" to (device.productName?.toString() ?: typeName(device.type)),
                "type" to typeName(device.type),
            )
        }
    }

    private fun typeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Headphones"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB headset"
        else -> "Audio device"
    }

    private fun setAudioOutput(context: Context, id: Int?): Boolean {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return false
        if (id == null) return false
        val device = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.id == id } ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            manager.setCommunicationDevice(device)
        } else {
            @Suppress("DEPRECATION")
            when (device.type) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> {
                    manager.isSpeakerphoneOn = true
                    true
                }
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> {
                    manager.startBluetoothSco()
                    manager.isBluetoothScoOn = true
                    true
                }
                else -> {
                    manager.isSpeakerphoneOn = false
                    true
                }
            }
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CALL_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CALL_CHANNEL_ID,
                    "Calls",
                    NotificationManager.IMPORTANCE_HIGH,
                )
                channel.description = "Incoming and ongoing Parallax calls"
                channel.setSound(null, null)
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun showIncomingCall(context: Context, name: String, audioOnly: Boolean) {
        ensureChannel(context)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val fullScreen = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val answer = PendingIntent.getActivity(
            context, 1, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val declineIntent = Intent(context, CallDeclineReceiver::class.java)
        val decline = PendingIntent.getBroadcast(
            context, 2, declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val caller = Person.Builder().setName(name).build()
        val builder = NotificationCompat.Builder(context, CALL_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_parallax)
            .setContentTitle(name)
            .setContentText(if (audioOnly) "Incoming voice call" else "Incoming video call")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreen, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(caller, decline, answer),
            )
        } else {
            builder.addAction(0, "Decline", decline)
            builder.addAction(0, "Answer", answer)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.notify(INCOMING_ID, builder.build())
    }

    private fun dismissIncomingCall(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(INCOMING_ID)
    }

    private fun registerTelecom(context: Context) {
        if (telecomRegistered || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return
            val handle = PhoneAccountHandle(
                ComponentName(context, ParallaxConnectionService::class.java),
                ACCOUNT_ID,
            )
            val account = PhoneAccount.builder(handle, "Parallax")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()
            telecom.registerPhoneAccount(account)
            telecomRegistered = true
        } catch (error: Exception) {
            // Telecom registration is best effort.
        }
    }
}

/** Cancels the incoming-call notification when the user declines from it. */
class CallDeclineReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(7401)
    }
}

/** Self-managed Telecom connection so the system treats Parallax calls as calls. */
class ParallaxConnectionService : android.telecom.ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: android.telecom.ConnectionRequest?,
    ): android.telecom.Connection {
        val connection = object : android.telecom.Connection() {
            override fun onAnswer() {
                setActive()
            }
            override fun onReject() {
                setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))
                destroy()
            }
            override fun onDisconnect() {
                setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))
                destroy()
            }
        }
        connection.setConnectionCapabilities(android.telecom.Connection.CAPABILITY_SELF_MANAGED)
        connection.setInitializing()
        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: android.telecom.ConnectionRequest?,
    ): android.telecom.Connection {
        val connection = object : android.telecom.Connection() {
            override fun onDisconnect() {
                setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))
                destroy()
            }
        }
        connection.setConnectionCapabilities(android.telecom.Connection.CAPABILITY_SELF_MANAGED)
        connection.setActive()
        return connection
    }
}
