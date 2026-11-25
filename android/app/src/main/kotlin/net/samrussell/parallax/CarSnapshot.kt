package net.samrussell.parallax

/**
 * The conversations the Dart host sends for the car screen
 * (lib/features/android_auto/car_conversations.dart). Parsed defensively:
 * anything malformed is dropped rather than shown.
 */
data class CarSnapshot(
    val state: State,
    val selfId: String = "",
    val selfName: String = "Me",
    val conversations: List<Conversation> = emptyList(),
) {
    enum class State { READY, SIGNED_OUT, LOCKED, LOADING }

    data class Conversation(
        val id: String,
        val title: String,
        val direct: Boolean,
        val iconPath: String?,
        val unread: Int,
        val messages: List<Message>,
    )

    data class Message(
        val senderId: String?,
        val senderName: String,
        val senderIconPath: String?,
        val text: String,
        val timestamp: Long,
        val read: Boolean,
    )

    companion object {
        const val MAX_CONVERSATIONS = 30
        const val MAX_MESSAGES = 10
        private const val MAX_TEXT = 1000
        private const val MAX_NAME = 120

        fun parse(raw: Any?): CarSnapshot? {
            val map = raw as? Map<*, *> ?: return null
            val state = when (map["state"]) {
                "ready" -> State.READY
                "signedOut" -> State.SIGNED_OUT
                "locked" -> State.LOCKED
                "loading" -> State.LOADING
                else -> return null
            }
            if (state != State.READY) return CarSnapshot(state)
            val self = map["self"] as? Map<*, *>
            val selfId = (self?.get("id") as? String)?.takeIf { it.isNotBlank() } ?: return null
            val selfName = name(self["name"]) ?: "Me"
            val conversations = (map["conversations"] as? List<*>).orEmpty()
                .asSequence()
                .mapNotNull { conversation(it) }
                .distinctBy { it.id }
                .take(MAX_CONVERSATIONS)
                .toList()
            return CarSnapshot(state, selfId, selfName, conversations)
        }

        private fun conversation(raw: Any?): Conversation? {
            val map = raw as? Map<*, *> ?: return null
            val id = (map["id"] as? String)?.takeIf { it.startsWith("!") && it.length <= 255 }
                ?: return null
            val title = name(map["title"]) ?: return null
            val messages = (map["messages"] as? List<*>).orEmpty()
                .mapNotNull { message(it) }
                .sortedBy { it.timestamp }
                .takeLast(MAX_MESSAGES)
            // The car requires at least one message per conversation.
            if (messages.isEmpty()) return null
            return Conversation(
                id = id,
                title = title,
                direct = map["direct"] == true,
                iconPath = map["icon"] as? String,
                unread = (map["unread"] as? Number)?.toInt()?.coerceAtLeast(0) ?: 0,
                messages = messages,
            )
        }

        private fun message(raw: Any?): Message? {
            val map = raw as? Map<*, *> ?: return null
            val text = (map["text"] as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val timestamp = (map["ts"] as? Number)?.toLong() ?: return null
            val fromMe = map["me"] == true
            val senderId = (map["sender"] as? String)?.takeIf { it.startsWith("@") }
            if (!fromMe && senderId == null) return null
            return Message(
                senderId = if (fromMe) null else senderId,
                senderName = name(map["senderName"]) ?: senderId ?: "",
                senderIconPath = map["senderIcon"] as? String,
                text = text.take(MAX_TEXT),
                timestamp = timestamp,
                read = fromMe || map["read"] == true,
            )
        }

        private fun name(raw: Any?): String? =
            (raw as? String)?.trim()?.takeIf { it.isNotEmpty() }?.take(MAX_NAME)
    }
}
