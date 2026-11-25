package net.samrussell.parallax

import android.app.Application
import android.os.Build
import java.io.File

/**
 * Starts Android Auto tracking in the app's main process. Android also
 * creates this class in the isolated PDF process (PdfRenderService), which
 * has no permissions and must not touch other apps' providers, so everything
 * here is skipped outside the main process.
 */
class ParallaxApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (!isMainProcess()) return
        AndroidAuto.start(this)
    }

    private fun isMainProcess(): Boolean {
        val name = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            getProcessName()
        } else {
            try {
                File("/proc/self/cmdline").readText().trim { it <= ' ' || it == '\u0000' }
            } catch (error: Exception) {
                null
            }
        }
        return name == packageName
    }
}
