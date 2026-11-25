package net.samrussell.parallax

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.LruCache
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.SessionInfo
import androidx.car.app.constraints.ConstraintManager
import androidx.car.app.messaging.model.CarMessage
import androidx.car.app.messaging.model.ConversationCallback
import androidx.car.app.messaging.model.ConversationItem
import androidx.car.app.model.Action
import androidx.car.app.model.CarIcon
import androidx.car.app.model.CarText
import androidx.car.app.model.Header
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import androidx.car.app.validation.HostValidator
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.io.File

/**
 * Parallax on the car screen (Android Auto templated messaging): recent
 * chats as conversations the car can read aloud, reply to by voice and mark
 * as read. The chats come from the signed-in Matrix client in the shared
 * engine (see [AndroidAuto]); nothing is stored here.
 *
 * Declared only in builds made with car templates enabled (see
 * app/build.gradle.kts): Google Play accepts templated messaging apps on
 * internal and closed testing tracks only.
 */
class ParallaxCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(sessionInfo: SessionInfo): Session = ParallaxCarSession()
}

class ParallaxCarSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen {
        // Start the Matrix client if Parallax wasn't running.
        try {
            ParallaxEngine.obtain(carContext.applicationContext)
        } catch (error: Exception) {
            // The screen reports that chats are unavailable.
        }
        return ConversationListScreen(carContext)
    }
}

/** The conversation list: the only screen, as the car guidelines expect. */
class ConversationListScreen(carContext: CarContext) :
    Screen(carContext), DefaultLifecycleObserver {

    private companion object {
        /** How long a starting client may take before "sign in" is shown. */
        const val STARTUP_GRACE_MS = 25_000L
        const val RETRY_MS = 1_000L
        const val MAX_LIST = 20
        const val MAX_ICON_BYTES = 1L * 1024 * 1024
    }

    private enum class Status { LOADING, READY, SIGNED_OUT, LOCKED, FAILED }

    private val main = Handler(Looper.getMainLooper())
    private val openedAt = SystemClock.elapsedRealtime()
    private val icons = LruCache<String, Bitmap>(64)
    private var status = Status.LOADING
    private var snapshot: CarSnapshot? = null
    private var unreadOnly = false
    private var requesting = false
    private var reloadQueued = false
    private var started = false
    private val listener: () -> Unit = { reload() }
    private val retry = Runnable { reload() }

    init {
        lifecycle.addObserver(this)
    }

    override fun onStart(owner: LifecycleOwner) {
        started = true
        AndroidAuto.addListener(listener)
        AndroidAuto.setCarScreenActive(true)
        reload()
    }

    override fun onStop(owner: LifecycleOwner) {
        started = false
        main.removeCallbacks(retry)
        AndroidAuto.removeListener(listener)
        AndroidAuto.setCarScreenActive(false)
    }

    /** How many rows the car allows (asked once; it is a call to the host). */
    private val listLimit: Int by lazy {
        try {
            carContext.getCarService(ConstraintManager::class.java)
                .getContentLimit(ConstraintManager.CONTENT_LIMIT_TYPE_LIST)
                .coerceIn(1, MAX_LIST)
        } catch (error: Exception) {
            6
        }
    }

    private fun reload() {
        if (!started) return
        if (requesting) {
            reloadQueued = true
            return
        }
        requesting = true
        main.removeCallbacks(retry)
        AndroidAuto.request(
            "conversations",
            mapOf(
                "limit" to listLimit,
                "unreadOnly" to unreadOnly,
                "messages" to CarSnapshot.MAX_MESSAGES,
            ),
        ) { result ->
            requesting = false
            apply(result)
            if (reloadQueued) {
                reloadQueued = false
                reload()
            }
        }
    }

    private fun apply(result: Result<Any?>) {
        val previous = status
        val parsed = result.getOrNull()?.let { CarSnapshot.parse(it) }
        val failure = result.exceptionOrNull()
        val starting = SystemClock.elapsedRealtime() - openedAt < STARTUP_GRACE_MS
        status = when {
            parsed != null -> when (parsed.state) {
                CarSnapshot.State.READY -> Status.READY
                CarSnapshot.State.SIGNED_OUT -> Status.SIGNED_OUT
                CarSnapshot.State.LOCKED -> Status.LOCKED
                CarSnapshot.State.LOADING -> Status.LOADING
            }
            failure is AndroidAuto.NotReady -> if (starting) Status.LOADING else Status.SIGNED_OUT
            // A failed refresh keeps the chats already on screen.
            snapshot != null && previous == Status.READY -> Status.READY
            else -> Status.FAILED
        }
        if (parsed?.state == CarSnapshot.State.READY) snapshot = parsed
        if (status == Status.LOADING && started) main.postDelayed(retry, RETRY_MS)
        invalidate()
    }

    override fun onGetTemplate(): Template = when (status) {
        Status.LOADING -> ListTemplate.Builder()
            .setHeader(listHeader())
            .setLoading(true)
            .build()
        Status.SIGNED_OUT -> message("Sign in to Parallax on your phone to see your chats here.")
        Status.LOCKED -> message("Parallax is locked. Unlock it on your phone when you’re parked.")
        Status.FAILED -> message(
            "Parallax couldn’t load your chats.",
            Action.Builder()
                .setTitle("Try again")
                .setOnClickListener { reload() }
                .build(),
        )
        Status.READY -> conversations()
    }

    private fun listHeader(): Header = Header.Builder()
        .setTitle(if (unreadOnly) "Unread" else "Chats")
        .setStartHeaderAction(Action.APP_ICON)
        .addEndHeaderAction(
            Action.Builder()
                .setTitle(if (unreadOnly) "All" else "Unread")
                .setOnClickListener {
                    unreadOnly = !unreadOnly
                    reload()
                    invalidate()
                }
                .build(),
        )
        .build()

    private fun message(text: String, action: Action? = null): Template {
        val builder = MessageTemplate.Builder(text)
            .setHeader(
                Header.Builder()
                    .setTitle("Parallax")
                    .setStartHeaderAction(Action.APP_ICON)
                    .build(),
            )
        if (action != null) builder.addAction(action)
        return builder.build()
    }

    private fun conversations(): Template {
        val snap = snapshot ?: return message("Parallax couldn’t load your chats.")
        val self = Person.Builder()
            .setName(snap.selfName)
            .setKey(snap.selfId)
            .build()
        val items = ItemList.Builder()
            .setNoItemsMessage(if (unreadOnly) "No unread chats" else "No chats yet")
        val shown = snap.conversations
            .filter { !unreadOnly || it.unread > 0 || it.messages.any { message -> !message.read } }
            .take(listLimit)
        for (conversation in shown) {
            items.addItem(conversationItem(conversation, self))
        }
        return ListTemplate.Builder()
            .setHeader(listHeader())
            .setSingleList(items.build())
            .build()
    }

    private fun conversationItem(
        conversation: CarSnapshot.Conversation,
        self: Person,
    ): ConversationItem {
        val people = HashMap<String, Person>()
        val messages = conversation.messages.map { line ->
            val builder = CarMessage.Builder()
                .setBody(CarText.create(line.text))
                .setReceivedTimeEpochMillis(line.timestamp)
                .setRead(line.read)
            val senderId = line.senderId
            // A message without a sender is the user's own.
            if (senderId != null) {
                builder.setSender(
                    people.getOrPut(senderId) {
                        val person = Person.Builder()
                            .setName(line.senderName.ifEmpty { senderId })
                            .setKey(senderId)
                        bitmap(line.senderIconPath)?.let {
                            person.setIcon(IconCompat.createWithBitmap(it))
                        }
                        person.build()
                    },
                )
            }
            builder.build()
        }
        val roomId = conversation.id
        val item = ConversationItem.Builder(
            roomId,
            CarText.create(conversation.title),
            self,
            messages,
            object : ConversationCallback {
                override fun onMarkAsRead() = markRead(roomId)

                override fun onTextReply(replyText: String) = reply(roomId, replyText)
            },
        ).setGroupConversation(!conversation.direct)
        bitmap(conversation.iconPath)?.let {
            item.setIcon(CarIcon.Builder(IconCompat.createWithBitmap(it)).build())
        }
        return item.build()
    }

    private fun markRead(roomId: String) {
        AndroidAuto.request("markRead", mapOf("roomId" to roomId)) { result ->
            if (result.getOrNull() != true) {
                toast("Couldn’t mark that chat as read.")
            }
            reload()
        }
    }

    private fun reply(roomId: String, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        AndroidAuto.request("reply", mapOf("roomId" to roomId, "text" to trimmed)) { result ->
            // Answers lib/features/android_auto CarReplyResult names.
            when (result.getOrNull()) {
                "sent" -> Unit
                "stillSending" -> toast("Your reply is still sending. Check Parallax when you’re parked.")
                else -> toast("Your reply wasn’t sent. Try again when you’re parked.")
            }
            reload()
        }
    }

    private fun toast(text: String) {
        if (!started) return
        try {
            CarToast.makeText(carContext, text, CarToast.LENGTH_LONG).show()
        } catch (error: Exception) {
            // The car may refuse toasts; the list still refreshes.
        }
    }

    /** Avatars the Dart host cached for notifications; only from this app's cache. */
    private fun bitmap(path: String?): Bitmap? {
        if (path == null) return null
        icons.get(path)?.let { return it }
        return try {
            val file = File(path).canonicalFile
            val cache = carContext.cacheDir.canonicalPath + File.separator
            if (!file.path.startsWith(cache) || !file.isFile || file.length() > MAX_ICON_BYTES) {
                return null
            }
            val bitmap = BitmapFactory.decodeFile(file.path) ?: return null
            icons.put(path, bitmap)
            bitmap
        } catch (error: Exception) {
            null
        }
    }
}
