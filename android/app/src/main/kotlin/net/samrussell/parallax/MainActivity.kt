package net.samrussell.parallax

import android.content.pm.PackageManager
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity is required by local_auth (biometric app lock).
class MainActivity : FlutterFragmentActivity() {
    private val permissionRequests = mutableMapOf<Int, Pair<MethodChannel.Result, List<String>>>()
    private var nextPermissionRequest = 4100

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parallax/secure_window")
            .setMethodCallHandler { call, result ->
                if (call.method != "setSecure") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val enabled = call.argument<Boolean>("enabled")
                if (enabled == null) {
                    result.error("INVALID_ARGUMENT", "Missing enabled flag", null)
                    return@setMethodCallHandler
                }
                runOnUiThread {
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
            }
        // Minimal runtime-permission bridge (camera/microphone for calls).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parallax/permissions")
            .setMethodCallHandler { call, result ->
                val permissions = call.argument<List<String>>("permissions")
                if (permissions == null || permissions.isEmpty()) {
                    result.error("INVALID_ARGUMENT", "Missing permissions", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "check" -> result.success(grantedMap(permissions))
                    "request" -> {
                        val missing = permissions.filter { !isGranted(it) }
                        if (missing.isEmpty()) {
                            result.success(grantedMap(permissions))
                        } else {
                            val code = nextPermissionRequest++
                            if (nextPermissionRequest > 4999) nextPermissionRequest = 4100
                            permissionRequests[code] = result to permissions
                            ActivityCompat.requestPermissions(this, missing.toTypedArray(), code)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isGranted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun grantedMap(permissions: List<String>) = permissions.associateWith { isGranted(it) }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val pending = permissionRequests.remove(requestCode) ?: return
        pending.first.success(grantedMap(pending.second))
    }
}
