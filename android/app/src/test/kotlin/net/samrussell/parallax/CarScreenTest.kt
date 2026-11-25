package net.samrussell.parallax

import android.os.Looper
import androidx.car.app.OnDoneCallback
import androidx.car.app.messaging.model.ConversationItem
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import androidx.car.app.testing.ScreenController
import androidx.car.app.testing.TestAppManager
import androidx.car.app.testing.TestCarContext
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The car screen against a stand-in Dart host (AndroidAuto.testHost). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CarScreenTest {
    private val requests = mutableListOf<Pair<String, Map<String, Any?>>>()
    private var answers: (String, Map<String, Any?>) -> Result<Any?> = { _, _ ->
        Result.success(snapshot())
    }

    private fun snapshot(unreadOnly: Boolean = false): Map<String, Any?> = mapOf(
        "state" to "ready",
        "self" to mapOf("id" to "@me:example.org", "name" to "Me"),
        "conversations" to listOfNotNull(
            mapOf(
                "id" to "!dm:example.org",
                "title" to "Alice",
                "direct" to true,
                "unread" to 1,
                "messages" to listOf(
                    mapOf(
                        "text" to "Hi",
                        "ts" to 1_000L,
                        "me" to true,
                        "read" to true,
                        "senderName" to "Me",
                    ),
                    mapOf(
                        "sender" to "@alice:example.org",
                        "senderName" to "Alice",
                        "text" to "Lunch at 1?",
                        "ts" to 2_000L,
                        "me" to false,
                        "read" to false,
                    ),
                ),
            ),
            if (unreadOnly) {
                null
            } else {
                mapOf(
                    "id" to "!group:example.org",
                    "title" to "Book club",
                    "direct" to false,
                    "unread" to 0,
                    "messages" to listOf(
                        mapOf(
                            "sender" to "@bob:example.org",
                            "senderName" to "Bob",
                            "text" to "Chapter 3 tonight",
                            "ts" to 3_000L,
                            "read" to true,
                        ),
                    ),
                )
            },
            // Malformed: no messages, so it is not shown.
            mapOf("id" to "!empty:example.org", "title" to "Empty", "messages" to emptyList<Any>()),
        ),
    )

    @Before
    fun setUp() {
        AndroidAuto.testHost = { method, arguments, callback ->
            requests += method to arguments
            callback(answers(method, arguments))
        }
    }

    @After
    fun tearDown() {
        AndroidAuto.testHost = null
    }

    private fun start(): Pair<ConversationListScreen, ScreenController> {
        val context = TestCarContext.createCarContext(ApplicationProvider.getApplicationContext())
        val screen = ConversationListScreen(context)
        val controller = ScreenController(screen)
        controller.moveToState(Lifecycle.State.STARTED)
        idle()
        return screen to controller
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun list(template: Template): ListTemplate {
        assertTrue("Expected a list, got $template", template is ListTemplate)
        return template as ListTemplate
    }

    private fun conversations(template: Template): List<ConversationItem> =
        list(template).singleList!!.items.map { it as ConversationItem }

    private val done = object : OnDoneCallback {}

    @Test
    fun showsChatsAsConversations() {
        val (screen, _) = start()
        assertEquals("conversations", requests.first().first)
        assertEquals(false, requests.first().second["unreadOnly"])
        val template = list(screen.onGetTemplate())
        assertFalse(template.isLoading)
        assertEquals("Chats", template.header!!.title.toString())
        val items = conversations(template)
        assertEquals(listOf("!dm:example.org", "!group:example.org"), items.map { it.id })
        val dm = items[0]
        assertEquals("Alice", dm.title.toString())
        assertFalse(dm.isGroupConversation)
        assertEquals("@me:example.org", dm.self.key)
        assertEquals(listOf("Hi", "Lunch at 1?"), dm.messages.map { it.body.toString() })
        // Your own message has no sender; others carry theirs.
        assertNull(dm.messages[0].sender)
        assertEquals("@alice:example.org", dm.messages[1].sender!!.key)
        assertEquals("Alice", dm.messages[1].sender!!.name.toString())
        assertEquals(listOf(true, false), dm.messages.map { it.isRead })
        assertTrue(items[1].isGroupConversation)
    }

    @Test
    fun voiceRepliesAndMarkAsReadGoToTheHost() {
        answers = { method, _ ->
            when (method) {
                "reply" -> Result.success("sent")
                "markRead" -> Result.success(true)
                else -> Result.success(snapshot())
            }
        }
        val (screen, _) = start()
        val dm = conversations(screen.onGetTemplate()).first()
        dm.conversationCallbackDelegate.sendTextReply("  On my way  ", done)
        idle()
        dm.conversationCallbackDelegate.sendMarkAsRead(done)
        idle()
        val actions = requests.filter { it.first != "conversations" }
        assertEquals(
            listOf(
                "reply" to mapOf("roomId" to "!dm:example.org", "text" to "On my way"),
                "markRead" to mapOf("roomId" to "!dm:example.org"),
            ),
            actions,
        )
        // Each answer refreshes the list.
        assertEquals(3, requests.count { it.first == "conversations" })
    }

    @Test
    fun unreadFilterAsksAgain() {
        answers = { _, arguments -> Result.success(snapshot(arguments["unreadOnly"] == true)) }
        val (screen, _) = start()
        val toggle = list(screen.onGetTemplate()).header!!.endHeaderActions.single()
        assertEquals("Unread", toggle.title.toString())
        toggle.onClickDelegate!!.sendClick(done)
        idle()
        assertEquals(true, requests.last().second["unreadOnly"])
        val filtered = list(screen.onGetTemplate())
        assertEquals("Unread", filtered.header!!.title.toString())
        assertEquals("All", filtered.header!!.endHeaderActions.single().title.toString())
        assertEquals(listOf("!dm:example.org"), conversations(filtered).map { it.id })
    }

    @Test
    fun lockedSignedOutAndLoadingStates() {
        answers = { _, _ -> Result.success(mapOf("state" to "locked")) }
        var (screen, _) = start()
        var template = screen.onGetTemplate()
        assertTrue(template is MessageTemplate)
        assertTrue((template as MessageTemplate).message.toString().contains("locked"))

        answers = { _, _ -> Result.success(mapOf("state" to "signedOut")) }
        screen = start().first
        template = screen.onGetTemplate()
        assertTrue((template as MessageTemplate).message.toString().contains("Sign in"))

        // No host yet (Parallax still starting): a loading list, not an error.
        answers = { _, _ -> Result.failure(AndroidAuto.NotReady()) }
        screen = start().first
        assertTrue(list(screen.onGetTemplate()).isLoading)
    }

    @Test
    fun failedReplyIsReportedAndKeepsTheList() {
        val context = TestCarContext.createCarContext(ApplicationProvider.getApplicationContext())
        val screen = ConversationListScreen(context)
        ScreenController(screen).moveToState(Lifecycle.State.STARTED)
        idle()
        val dm = conversations(screen.onGetTemplate()).first()
        answers = { _, _ -> Result.failure(IllegalStateException("host error")) }
        dm.conversationCallbackDelegate.sendTextReply("hello", done)
        idle()
        assertEquals(1, requests.count { it.first == "reply" })
        val toasts = context.getCarService(TestAppManager::class.java).toastsShown
        assertEquals(listOf("Your reply wasn’t sent. Try again when you’re parked."), toasts.map { it.toString() })
        // The refresh after it failed too: the chats stay on screen.
        assertEquals(2, conversations(screen.onGetTemplate()).size)
    }

    @Test
    fun snapshotParsingIsDefensive() {
        assertNull(CarSnapshot.parse(null))
        assertNull(CarSnapshot.parse(mapOf("state" to "unknown")))
        // A ready snapshot needs your account.
        assertNull(CarSnapshot.parse(mapOf("state" to "ready", "conversations" to emptyList<Any>())))
        val parsed = CarSnapshot.parse(
            mapOf(
                "state" to "ready",
                "self" to mapOf("id" to "@me:example.org"),
                "conversations" to listOf(
                    mapOf(
                        "id" to "not-a-room",
                        "title" to "Bad",
                        "messages" to listOf(mapOf("text" to "x", "ts" to 1, "me" to true)),
                    ),
                    mapOf(
                        "id" to "!r:example.org",
                        "title" to "Room",
                        "messages" to listOf(
                            // No sender and not yours: dropped.
                            mapOf("text" to "anon", "ts" to 1),
                            mapOf("text" to "  ", "ts" to 2, "me" to true),
                            mapOf("text" to "ok", "ts" to 3, "me" to true),
                        ),
                    ),
                ),
            ),
        )!!
        assertEquals("Me", parsed.selfName)
        assertEquals(listOf("!r:example.org"), parsed.conversations.map { it.id })
        assertEquals(listOf("ok"), parsed.conversations.single().messages.map { it.text })
    }
}
