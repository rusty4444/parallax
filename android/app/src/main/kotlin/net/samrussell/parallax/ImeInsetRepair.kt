package net.samrussell.parallax

import android.app.Activity
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterView
import java.lang.ref.WeakReference

/**
 * Keeps the keyboard's height from outliving the keyboard (issue #18).
 *
 * Flutter engine bug flutter/flutter#191156 (open, present in our Flutter
 * 3.44): the engine's ImeSyncDeferringInsetsCallback caches the window insets
 * between an IME animation's onPrepare and the next inset delivery, and
 * re-applies that cache in onEnd. Leave the app while the keyboard is still
 * animating and the cache holds a keyboard-visible snapshot; on return the
 * hide is cancelled at once (onPrepare, onEnd, no delivery between), so onEnd
 * puts the stale keyboard height back. Android reports no further change, so
 * the chat stays short by the keyboard and a black band sits where it was
 * until the keyboard is opened again.
 *
 * The repair watches IME animations from the FlutterView's parent and, once
 * one ends, asks the platform to dispatch its current insets again. The
 * parent's onEnd runs before the engine's (a parent dispatches to itself,
 * then its subtree), so the request is posted to run after the engine has
 * written whatever it writes; by then the engine has cleared its animating
 * flag and lets the fresh insets through. When the engine was right the same
 * metrics arrive again and nothing rebuilds. The activity also re-requests
 * insets whenever its window regains focus (returning from another app).
 *
 * Delete this once a Flutter release with the engine fix is in use.
 */
internal object ImeInsetRepair {
    private var installed: WeakReference<View>? = null

    /** Finds the activity's FlutterView and installs the repair once. */
    fun install(activity: Activity) {
        // The engine installs its deferring callback only from API 30 (R).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val flutterView = findFlutterView(activity.window?.decorView) ?: return
        if (installed?.get() === flutterView) return
        val parent = flutterView.parent as? View ?: return
        parent.setWindowInsetsAnimationCallback(RepairCallback(flutterView))
        installed = WeakReference(flutterView)
    }

    /** Re-dispatches the platform's current insets to the FlutterView. */
    fun resync(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val flutterView = findFlutterView(activity.window?.decorView) ?: return
        flutterView.post { flutterView.requestApplyInsets() }
    }

    private fun findFlutterView(view: View?): View? {
        if (view == null) return null
        if (view is FlutterView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFlutterView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private class RepairCallback(private val flutterView: View) :
        WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
        override fun onProgress(
            insets: WindowInsets,
            runningAnimations: MutableList<WindowInsetsAnimation>,
        ): WindowInsets = insets

        override fun onEnd(animation: WindowInsetsAnimation) {
            if (animation.typeMask and WindowInsets.Type.ime() == 0) return
            // A fresh dispatch down the normal path, not the root insets
            // handed over directly: below API 35 the DecorView consumes the
            // navigation bar before the FlutterView sees any inset, and only
            // the normal path applies that correction.
            flutterView.post { flutterView.requestApplyInsets() }
        }
    }
}
