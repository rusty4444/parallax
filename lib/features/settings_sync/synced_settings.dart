import 'package:flutter/foundation.dart';

import '../../appearance_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/locale_controller.dart';
import '../bug_report/bug_report_hooks.dart';
import '../call/call_settings_store.dart';
import '../call/call_widget_url.dart';
import '../composer/chat_effects_preferences.dart';
import '../media/media_preferences.dart';
import '../message_fonts/message_fonts.dart';
import '../message_requests/message_requests.dart';
import '../notifications/notification_store.dart';
import '../reactions/quick_reaction_settings.dart';
import '../scheduled/undo_send.dart';
import '../stories/stories.dart';
import 'settings_sync.dart';

/// Every setting that follows the account. Theme and app font sync through
/// `AppearanceSync`; bubble colours, backgrounds, folders, saved messages
/// and notification rules are account data already.
///
/// Kept on each device on purpose: text size (screens differ), app and chat
/// locks, how notifications are delivered, the background connection, the
/// local search index, window layout and accounts.
List<SyncedSetting> appSyncedSettings(AppearancePreferences preferences) {
  SyncedSetting flag(
    String id,
    bool fallback,
    bool Function() read,
    Future<void> Function(bool value) write,
  ) => SyncedSetting(
    id,
    defaultValue: fallback,
    read: () async => read(),
    apply: (value) async {
      if (value is! bool) return false;
      await write(value);
      return true;
    },
  );

  SyncedSetting choice<T extends Enum>(
    String id,
    T fallback,
    List<T> values,
    T Function() read,
    Future<void> Function(T value) write,
  ) => SyncedSetting(
    id,
    defaultValue: fallback.name,
    read: () async => read().name,
    apply: (value) async {
      final picked = values.where((v) => v.name == value).firstOrNull;
      if (picked == null) return false;
      await write(picked);
      return true;
    },
  );

  final p = preferences;
  return [
    // Appearance → Reading and Home screen.
    flag('compact', false, () => p.compact, p.setCompact),
    choice(
      'homeRowStyle',
      HomeRowStyle.cards,
      HomeRowStyle.values,
      () => p.homeRowStyle,
      p.setHomeRowStyle,
    ),
    choice(
      'homePreview',
      HomePreview.long,
      HomePreview.values,
      () => p.homePreview,
      p.setHomePreview,
    ),
    flag('networkLogos', false, () => p.networkLogos, p.setNetworkLogos),
    flag('expandedHome', false, () => p.expandedHome, p.setExpandedHome),
    flag('showChatThemes', true, () => p.showChatThemes, p.setShowChatThemes),
    flag('haptics', true, () => p.haptics, p.setHaptics),
    // Chats.
    SyncedSetting(
      'quickReaction',
      defaultValue: AppearancePreferences.defaultQuickReaction,
      read: () async => p.quickReaction,
      apply: (value) async {
        if (value is! String || !AppearancePreferences.isQuickReaction(value)) {
          return false;
        }
        await p.setQuickReaction(value);
        return true;
      },
    ),
    SyncedSetting(
      'messageFont',
      defaultValue: null,
      read: () async => p.messageFont,
      apply: (value) async {
        if (value != null &&
            (value is! String || messageFontById(value) == null)) {
          return false;
        }
        await p.setMessageFont(value as String?);
        return true;
      },
    ),
    SyncedSetting(
      'quickReactionMode',
      defaultValue: QuickReactionMode.mostUsed.name,
      read: () async => (await QuickReactionSettings.instance.mode()).name,
      apply: (value) async {
        final mode = QuickReactionMode.values
            .where((m) => m.name == value)
            .firstOrNull;
        if (mode == null) return false;
        await QuickReactionSettings.instance.setMode(mode);
        return true;
      },
    ),
    SyncedSetting(
      'quickReactionList',
      defaultValue: const <String>[],
      read: () => QuickReactionSettings.instance.manual(),
      apply: (value) async {
        if (value is! List || value.any((e) => e is! String || e.isEmpty)) {
          return false;
        }
        await QuickReactionSettings.instance.setManual(value.cast<String>());
        return true;
      },
    ),
    SyncedSetting(
      'undoSendSeconds',
      defaultValue: UndoSendPreferences.defaultSeconds,
      read: () async {
        await UndoSendPreferences.shared.ensureLoaded();
        return UndoSendPreferences.shared.seconds;
      },
      apply: (value) async {
        if (value is! int || !UndoSendPreferences.choices.contains(value)) {
          return false;
        }
        await UndoSendPreferences.shared.setSeconds(value);
        return true;
      },
    ),
    SyncedSetting(
      'chatEffects',
      defaultValue: true,
      read: () async {
        await ChatEffectsPreferences.shared.ensureLoaded();
        return ChatEffectsPreferences.shared.showChatEffects;
      },
      apply: (value) async {
        if (value is! bool) return false;
        await ChatEffectsPreferences.shared.setShowChatEffects(value);
        return true;
      },
    ),
    SyncedSetting(
      'messageRequests',
      defaultValue: true,
      read: () async {
        final requests = MessageRequestsController.shared;
        if (!requests.loaded) await requests.load();
        return requests.separate;
      },
      apply: (value) async {
        if (value is! bool) return false;
        await MessageRequestsController.shared.setSeparate(value);
        return true;
      },
    ),
    SyncedSetting(
      'stories',
      defaultValue: false,
      read: () async {
        final stories = StoriesController.shared;
        if (!stories.loaded) await stories.load();
        return stories.enabled;
      },
      apply: (value) async {
        if (value is! bool) return false;
        await StoriesController.shared.setEnabled(value);
        return true;
      },
    ),
    // Media.
    SyncedSetting(
      'mediaPreviews',
      defaultValue: MediaPreviewMode.always.name,
      read: () async => p.mediaPreviewMode.name,
      apply: (value) async {
        final mode = MediaPreviewMode.values
            .where((m) => m.name == value)
            .firstOrNull;
        if (mode == null) return false;
        await p.setMediaPreviewMode(mode);
        return true;
      },
    ),
    SyncedSetting(
      'optimiseImages',
      defaultValue: true,
      read: () async {
        await MediaPreferences.shared.ensureLoaded();
        return MediaPreferences.shared.optimiseImages;
      },
      apply: (value) async {
        if (value is! bool) return false;
        await MediaPreferences.shared.setOptimiseImages(value);
        return true;
      },
    ),
    flag('linkPreviews', true, () => p.linkPreviews, p.setLinkPreviews),
    flag(
      'linkPreviewsInEncryptedChats',
      false,
      () => p.linkPreviewsInEncryptedRooms,
      p.setLinkPreviewsInEncryptedRooms,
    ),
    // Privacy.
    flag(
      'sendReadReceipts',
      true,
      () => p.sendReadReceipts,
      p.setSendReadReceipts,
    ),
    flag(
      'sendTyping',
      true,
      () => p.sendTypingNotifications,
      p.setSendTypingNotifications,
    ),
    flag(
      'hideInviteAvatars',
      false,
      () => p.hideInviteAvatars,
      p.setHideInviteAvatars,
    ),
    // Notifications: what a notification shows.
    SyncedSetting(
      'notificationContent',
      defaultValue: true,
      read: () async =>
          (await (await NotificationStore.open()).readPreferences())
              .showContent,
      apply: (value) async {
        if (value is! bool) return false;
        final store = await NotificationStore.open();
        final current = await store.readPreferences();
        await store.writePreferences(current.copyWith(showContent: value));
        return true;
      },
    ),
    SyncedSetting(
      'notificationMedia',
      defaultValue: true,
      read: () async =>
          (await (await NotificationStore.open()).readPreferences())
              .showMediaPreviews,
      apply: (value) async {
        if (value is! bool) return false;
        final store = await NotificationStore.open();
        final current = await store.readPreferences();
        await store.writePreferences(
          current.copyWith(showMediaPreviews: value),
        );
        return true;
      },
    ),
    // Language (null follows the system).
    SyncedSetting(
      'language',
      defaultValue: null,
      read: () async {
        final locale = LocaleController.instance;
        if (!locale.loaded) await locale.load();
        return locale.languageCode;
      },
      apply: (value) async {
        if (value != null &&
            (value is! String ||
                !ParallaxLocalizations.languageNames.containsKey(value))) {
          return false;
        }
        await LocaleController.instance.setLanguage(value as String?);
        return true;
      },
    ),
    // Advanced.
    SyncedSetting(
      'callScreenSharing',
      defaultValue: false,
      read: () async {
        await CallSettingsStore.instance.load();
        return CallSettingsStore.instance.screenSharingEnabled;
      },
      apply: (value) async {
        if (value is! bool) return false;
        await CallSettingsStore.instance.setScreenSharingEnabled(value);
        return true;
      },
    ),
    SyncedSetting(
      'elementCallUrl',
      defaultValue: null,
      read: () async => (await CallSettingsStore.instance.load())?.toString(),
      apply: (value) async {
        if (value != null &&
            (value is! String || parseElementCallBaseUrl(value) == null)) {
          return false;
        }
        await CallSettingsStore.instance.setCustomBaseUrl(value as String?);
        return true;
      },
    ),
    SyncedSetting(
      'shakeToReport',
      defaultValue: false,
      read: BugReportPreferences.shakeEnabled,
      apply: (value) async {
        if (value is! bool) return false;
        await BugReportPreferences.setShakeEnabled(value);
        return true;
      },
    ),
  ];
}

/// Everything that tells [SettingsSync] a setting may have changed.
Listenable appSettingsEdits(AppearancePreferences preferences) =>
    Listenable.merge([
      preferences,
      UndoSendPreferences.shared,
      ChatEffectsPreferences.shared,
      MessageRequestsController.shared,
      StoriesController.shared,
      MediaPreferences.shared,
      LocaleController.instance,
      CallSettingsStore.instance,
      SettingsEdits.instance,
    ]);
