package net.samrussell.parallax

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Recent chats as Android sharing shortcuts, so they are suggested in the
 * system share sheet (Direct Share) and under the launcher icon.
 *
 * Dart picks the chats (lib/features/platform/share_shortcuts.dart); this
 * mirrors that list into ShortcutManager. Tapping a suggestion delivers the
 * share to MainActivity with the shortcut ID, which [roomIdOf] turns back into
 * the chat.
 */
object ShareShortcuts {
    private const val CHANNEL = "parallax/share_shortcuts"

    /** Must match the `<share-target>` category in res/xml/shortcuts.xml. */
    private const val CATEGORY = "net.samrussell.parallax.category.SHARE_TARGET"
    private const val ID_PREFIX = "chat:"

    /** Opens one chat (the shortcut's own intent, used from the launcher). */
    const val ACTION_OPEN_CHAT = "net.samrussell.parallax.action.OPEN_CHAT"
    const val EXTRA_ROOM_ID = "net.samrussell.parallax.extra.ROOM_ID"

    private const val MAX_SHORTCUTS = 8
    private const val MAX_ROOM_ID = 255
    private const val MAX_LABEL = 60
    private const val MAX_ICON_BYTES = 2 * 1024 * 1024
    private const val MAX_ICON_PIXELS = 16L * 1000 * 1000

    // One thread, so a clear sent after a publish always lands after it.
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private class Entry(
        val roomId: String,
        val label: String,
        val direct: Boolean,
        val initial: String,
        val background: Int,
        val foreground: Int,
        val icon: ByteArray?,
    )

    fun register(app: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "publish" -> {
                    val entries = parse(call.argument<List<Any?>>("shortcuts"))
                    executor.execute {
                        val published = try {
                            publish(app, entries)
                        } catch (error: Exception) {
                            // For example a locked user profile right after boot.
                            -1
                        }
                        main.post { result.success(published) }
                    }
                }
                "clear" -> executor.execute {
                    try {
                        clear(app)
                    } catch (error: Exception) {
                        // Nothing to remove, or the profile is locked.
                    }
                    main.post { result.success(null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The chat a share was aimed at, from `Intent.EXTRA_SHORTCUT_ID`. */
    fun roomIdOf(shortcutId: String?): String? =
        shortcutId?.takeIf { it.startsWith(ID_PREFIX) }?.removePrefix(ID_PREFIX)?.let(::validRoomId)

    fun validRoomId(value: String?): String? =
        value?.takeIf { it.length in 2..MAX_ROOM_ID && it.startsWith("!") && it.none(Char::isISOControl) }

    private fun parse(raw: List<Any?>?): List<Entry> {
        val entries = ArrayList<Entry>()
        val seen = HashSet<String>()
        for (item in raw ?: emptyList()) {
            val map = item as? Map<*, *> ?: continue
            val roomId = validRoomId(map["roomId"] as? String) ?: continue
            val label = (map["label"] as? String)?.trim()?.take(MAX_LABEL)
            if (label.isNullOrEmpty() || !seen.add(roomId)) continue
            entries.add(
                Entry(
                    roomId = roomId,
                    label = label,
                    direct = map["isDirect"] == true,
                    initial = (map["initial"] as? String)?.take(8)?.ifEmpty { null } ?: "?",
                    background = (map["background"] as? Number)?.toInt() ?: 0xFF2A1A16.toInt(),
                    foreground = (map["foreground"] as? Number)?.toInt() ?: 0xFFFFFFFF.toInt(),
                    icon = (map["icon"] as? ByteArray)?.takeIf { it.isNotEmpty() && it.size <= MAX_ICON_BYTES },
                ),
            )
        }
        return entries
    }

    private fun ours(app: Context, flags: Int): List<ShortcutInfoCompat> =
        ShortcutManagerCompat.getShortcuts(app, flags).filter { it.id.startsWith(ID_PREFIX) }

    /** Replaces the published chats with [entries] (most recent first). */
    private fun publish(app: Context, entries: List<Entry>): Int {
        val limit = minOf(MAX_SHORTCUTS, ShortcutManagerCompat.getMaxShortcutCountPerActivity(app))
        val wanted = entries.take(limit)
        val wantedIds = wanted.map { ID_PREFIX + it.roomId }.toSet()
        val stale = ours(
            app,
            ShortcutManagerCompat.FLAG_MATCH_DYNAMIC or ShortcutManagerCompat.FLAG_MATCH_CACHED,
        ).map { it.id }.filter { it !in wantedIds }
        if (stale.isNotEmpty()) ShortcutManagerCompat.removeLongLivedShortcuts(app, stale)

        val shortcuts = wanted.map { build(app, it) }
        // A chat pinned to the home screen was disabled by clear(); it is back.
        val disabled = ours(app, ShortcutManagerCompat.FLAG_MATCH_PINNED)
            .filter { !it.isEnabled }.map { it.id }.toSet()
        val returning = shortcuts.filter { it.id in disabled }
        if (returning.isNotEmpty()) ShortcutManagerCompat.enableShortcuts(app, returning)

        // Least recent first, each at rank 0: Android renumbers the ranks after
        // every push and puts the pushed shortcut ahead of an equal rank, so
        // the last push (the most recent chat) ends up first. Explicit ranks
        // 7, 6, 5… would be renumbered on the way and come out shuffled. Each
        // push also counts as a use, newest last. Unlike setDynamicShortcuts,
        // pushes are not rate limited while Parallax syncs in the background.
        var published = 0
        for (shortcut in shortcuts.asReversed()) {
            if (ShortcutManagerCompat.pushDynamicShortcut(app, shortcut)) published++
        }
        return published
    }

    /** Sign-out or screen lock: no chat names stay with the system. */
    private fun clear(app: Context) {
        val all = ours(
            app,
            ShortcutManagerCompat.FLAG_MATCH_DYNAMIC or ShortcutManagerCompat.FLAG_MATCH_CACHED,
        ).map { it.id }
        if (all.isNotEmpty()) ShortcutManagerCompat.removeLongLivedShortcuts(app, all)
        // The app cannot remove a shortcut the user pinned, only switch it off.
        val pinned = ours(app, ShortcutManagerCompat.FLAG_MATCH_PINNED).map { it.id }
        if (pinned.isNotEmpty()) {
            ShortcutManagerCompat.disableShortcuts(app, pinned, "Open Parallax to use this chat")
        }
    }

    private fun build(app: Context, entry: Entry): ShortcutInfoCompat {
        val intent = Intent(ACTION_OPEN_CHAT)
            .setClass(app, MainActivity::class.java)
            .putExtra(EXTRA_ROOM_ID, entry.roomId)
        val builder = ShortcutInfoCompat.Builder(app, ID_PREFIX + entry.roomId)
            .setShortLabel(entry.label)
            .setLongLabel(entry.label)
            .setIcon(icon(app, entry))
            .setIntent(intent)
            .setCategories(setOf(CATEGORY))
            .setIsConversation()
            .setLongLived(true)
            .setRank(0)
        if (entry.direct) {
            builder.setPerson(Person.Builder().setName(entry.label).setKey(entry.roomId).build())
        }
        return builder.build()
    }

    /**
     * An adaptive icon: the launcher or share sheet masks it to its own shape
     * and shows the middle two thirds, so the picture is drawn there and the
     * rest is background.
     */
    private fun icon(app: Context, entry: Entry): IconCompat {
        val visible = maxOf(
            ShortcutManagerCompat.getIconMaxWidth(app),
            ShortcutManagerCompat.getIconMaxHeight(app),
        ).coerceIn(72, 384)
        val size = visible * 3 / 2
        val inset = (size - visible) / 2f
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(entry.background or 0xFF000000.toInt())
        val picture = entry.icon?.let { decode(it, visible) }
        if (picture != null) {
            val edge = minOf(picture.width, picture.height)
            val left = (picture.width - edge) / 2
            val top = (picture.height - edge) / 2
            canvas.drawBitmap(
                picture,
                Rect(left, top, left + edge, top + edge),
                RectF(inset, inset, size - inset, size - inset),
                Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG),
            )
            picture.recycle()
        } else {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = entry.foreground or 0xFF000000.toInt()
                textSize = visible * 0.42f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
            }
            val baseline = size / 2f - (paint.descent() + paint.ascent()) / 2f
            canvas.drawText(entry.initial, size / 2f, baseline, paint)
        }
        return IconCompat.createWithAdaptiveBitmap(bitmap)
    }

    /** Decodes an avatar no larger than needed; null for anything unreadable. */
    private fun decode(bytes: ByteArray, target: Int): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0 || width.toLong() * height > MAX_ICON_PIXELS) {
            null
        } else {
            var sample = 1
            while (minOf(width, height) / (sample * 2) >= target) sample *= 2
            BitmapFactory.decodeByteArray(
                bytes,
                0,
                bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        }
    } catch (error: Exception) {
        null
    } catch (error: OutOfMemoryError) {
        null
    }
}
