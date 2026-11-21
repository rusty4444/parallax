import 'package:flutter/material.dart';

/// Parallax UI localisation. Covers the core navigation and settings labels;
/// Material/Cupertino widgets localise through the global delegates.
class ParallaxLocalizations {
  ParallaxLocalizations(this.locale);

  final Locale locale;

  static ParallaxLocalizations of(BuildContext context) =>
      Localizations.of<ParallaxLocalizations>(context, ParallaxLocalizations) ??
      ParallaxLocalizations(const Locale('en'));

  static const supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('de'),
    Locale('pt'),
    Locale('it'),
    Locale('nl'),
    Locale('ja'),
    Locale('zh'),
    Locale('ru'),
  ];

  static const LocalizationsDelegate<ParallaxLocalizations> delegate =
      _ParallaxLocalizationsDelegate();

  static const _en = <String, String>{
    'account': 'Account',
    'notifications': 'Notifications',
    'appearance': 'Appearance',
    'chats': 'Chats',
    'media': 'Media',
    'privacy': 'Privacy',
    'security': 'Security',
    'advanced': 'Advanced',
    'about': 'About & help',
    'signOut': 'Sign out',
    'language': 'Language',
    'systemDefault': 'System default',
    'search': 'Search',
    'newChat': 'New chat',
    'settings': 'Settings',
    'rooms': 'Rooms',
  };

  static const _translations = <String, Map<String, String>>{
    'en': _en,
    'es': {
      'account': 'Cuenta',
      'notifications': 'Notificaciones',
      'appearance': 'Apariencia',
      'chats': 'Chats',
      'media': 'Multimedia',
      'privacy': 'Privacidad',
      'security': 'Seguridad',
      'advanced': 'Avanzado',
      'about': 'Acerca de y ayuda',
      'signOut': 'Cerrar sesión',
      'language': 'Idioma',
      'systemDefault': 'Predeterminado del sistema',
      'search': 'Buscar',
      'newChat': 'Nuevo chat',
      'settings': 'Ajustes',
      'rooms': 'Salas',
    },
    'fr': {
      'account': 'Compte',
      'notifications': 'Notifications',
      'appearance': 'Apparence',
      'chats': 'Discussions',
      'media': 'Médias',
      'privacy': 'Confidentialité',
      'security': 'Sécurité',
      'advanced': 'Avancé',
      'about': 'À propos et aide',
      'signOut': 'Se déconnecter',
      'language': 'Langue',
      'systemDefault': 'Par défaut du système',
      'search': 'Rechercher',
      'newChat': 'Nouvelle discussion',
      'settings': 'Paramètres',
      'rooms': 'Salons',
    },
    'de': {
      'account': 'Konto',
      'notifications': 'Benachrichtigungen',
      'appearance': 'Erscheinungsbild',
      'chats': 'Chats',
      'media': 'Medien',
      'privacy': 'Privatsphäre',
      'security': 'Sicherheit',
      'advanced': 'Erweitert',
      'about': 'Über & Hilfe',
      'signOut': 'Abmelden',
      'language': 'Sprache',
      'systemDefault': 'Systemstandard',
      'search': 'Suchen',
      'newChat': 'Neuer Chat',
      'settings': 'Einstellungen',
      'rooms': 'Räume',
    },
    'pt': {
      'account': 'Conta',
      'notifications': 'Notificações',
      'appearance': 'Aparência',
      'chats': 'Conversas',
      'media': 'Mídia',
      'privacy': 'Privacidade',
      'security': 'Segurança',
      'advanced': 'Avançado',
      'about': 'Sobre e ajuda',
      'signOut': 'Sair',
      'language': 'Idioma',
      'systemDefault': 'Padrão do sistema',
      'search': 'Pesquisar',
      'newChat': 'Nova conversa',
      'settings': 'Configurações',
      'rooms': 'Salas',
    },
    'it': {
      'account': 'Account',
      'notifications': 'Notifiche',
      'appearance': 'Aspetto',
      'chats': 'Chat',
      'media': 'Media',
      'privacy': 'Privacy',
      'security': 'Sicurezza',
      'advanced': 'Avanzate',
      'about': 'Informazioni e aiuto',
      'signOut': 'Esci',
      'language': 'Lingua',
      'systemDefault': 'Predefinito di sistema',
      'search': 'Cerca',
      'newChat': 'Nuova chat',
      'settings': 'Impostazioni',
      'rooms': 'Stanze',
    },
    'nl': {
      'account': 'Account',
      'notifications': 'Meldingen',
      'appearance': 'Weergave',
      'chats': 'Chats',
      'media': 'Media',
      'privacy': 'Privacy',
      'security': 'Beveiliging',
      'advanced': 'Geavanceerd',
      'about': 'Over & hulp',
      'signOut': 'Uitloggen',
      'language': 'Taal',
      'systemDefault': 'Systeemstandaard',
      'search': 'Zoeken',
      'newChat': 'Nieuwe chat',
      'settings': 'Instellingen',
      'rooms': 'Kamers',
    },
    'ja': {
      'account': 'アカウント',
      'notifications': '通知',
      'appearance': '外観',
      'chats': 'チャット',
      'media': 'メディア',
      'privacy': 'プライバシー',
      'security': 'セキュリティ',
      'advanced': '詳細',
      'about': '情報とヘルプ',
      'signOut': 'サインアウト',
      'language': '言語',
      'systemDefault': 'システムのデフォルト',
      'search': '検索',
      'newChat': '新しいチャット',
      'settings': '設定',
      'rooms': 'ルーム',
    },
    'zh': {
      'account': '账户',
      'notifications': '通知',
      'appearance': '外观',
      'chats': '聊天',
      'media': '媒体',
      'privacy': '隐私',
      'security': '安全',
      'advanced': '高级',
      'about': '关于与帮助',
      'signOut': '退出登录',
      'language': '语言',
      'systemDefault': '系统默认',
      'search': '搜索',
      'newChat': '新聊天',
      'settings': '设置',
      'rooms': '房间',
    },
    'ru': {
      'account': 'Аккаунт',
      'notifications': 'Уведомления',
      'appearance': 'Внешний вид',
      'chats': 'Чаты',
      'media': 'Медиа',
      'privacy': 'Приватность',
      'security': 'Безопасность',
      'advanced': 'Дополнительно',
      'about': 'О приложении и помощь',
      'signOut': 'Выйти',
      'language': 'Язык',
      'systemDefault': 'Системный по умолчанию',
      'search': 'Поиск',
      'newChat': 'Новый чат',
      'settings': 'Настройки',
      'rooms': 'Комнаты',
    },
  };

  /// Native name of each supported language (for the picker).
  static const languageNames = <String, String>{
    'en': 'English',
    'es': 'Español',
    'fr': 'Français',
    'de': 'Deutsch',
    'pt': 'Português',
    'it': 'Italiano',
    'nl': 'Nederlands',
    'ja': '日本語',
    'zh': '简体中文',
    'ru': 'Русский',
  };

  String t(String key) =>
      _translations[locale.languageCode]?[key] ?? _en[key] ?? key;

  String get account => t('account');
  String get notifications => t('notifications');
  String get appearance => t('appearance');
  String get chats => t('chats');
  String get media => t('media');
  String get privacy => t('privacy');
  String get security => t('security');
  String get advanced => t('advanced');
  String get about => t('about');
  String get signOut => t('signOut');
  String get language => t('language');
  String get systemDefault => t('systemDefault');
  String get settings => t('settings');
  String get search => t('search');
  String get newChat => t('newChat');
  String get rooms => t('rooms');
}

class _ParallaxLocalizationsDelegate
    extends LocalizationsDelegate<ParallaxLocalizations> {
  const _ParallaxLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      ParallaxLocalizations.languageNames.containsKey(locale.languageCode);

  @override
  Future<ParallaxLocalizations> load(Locale locale) async =>
      ParallaxLocalizations(locale);

  @override
  bool shouldReload(_ParallaxLocalizationsDelegate old) => false;
}
