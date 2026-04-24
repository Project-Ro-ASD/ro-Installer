class TargetLocaleSettings {
  const TargetLocaleSettings({
    required this.languageCode,
    required this.locale,
    required this.glibcLangpackTag,
    required this.langpacksTag,
  });

  final String languageCode;
  final String locale;
  final String glibcLangpackTag;
  final String langpacksTag;

  List<String> get requiredPackages => <String>[
    'glibc-langpack-$glibcLangpackTag',
    'langpacks-$langpacksTag',
  ];
}

class TargetKeyboardSettings {
  const TargetKeyboardSettings({
    required this.consoleKeymap,
    required this.x11Layout,
    this.x11Variant = '',
  });

  final String consoleKeymap;
  final String x11Layout;
  final String x11Variant;

  bool get hasVariant => x11Variant.isNotEmpty;
}

TargetLocaleSettings resolveTargetLocaleSettings({
  required String selectedLanguage,
  required String selectedLocale,
}) {
  final normalizedLanguage = _normalizeLanguageCode(selectedLanguage);
  final locale = selectedLocale.trim().isNotEmpty
      ? _normalizeLocale(selectedLocale)
      : _defaultLocaleFor(normalizedLanguage);

  final localeName = locale.split('.').first;
  final languageBase = localeName.split('_').first.toLowerCase();
  final langpacksTag = normalizedLanguage.isNotEmpty
      ? normalizedLanguage
      : localeName;

  return TargetLocaleSettings(
    languageCode: normalizedLanguage.isNotEmpty
        ? normalizedLanguage
        : languageBase,
    locale: locale,
    glibcLangpackTag: languageBase,
    langpacksTag: langpacksTag,
  );
}

TargetKeyboardSettings resolveTargetKeyboardSettings(String selectedKeyboard) {
  final keymap = selectedKeyboard.trim().toLowerCase();

  return switch (keymap) {
    'trf' => const TargetKeyboardSettings(
      consoleKeymap: 'trf',
      x11Layout: 'tr',
      x11Variant: 'f',
    ),
    'trq' => const TargetKeyboardSettings(
      consoleKeymap: 'trq',
      x11Layout: 'tr',
    ),
    'uk' => const TargetKeyboardSettings(consoleKeymap: 'uk', x11Layout: 'gb'),
    'de' => const TargetKeyboardSettings(consoleKeymap: 'de', x11Layout: 'de'),
    'es' => const TargetKeyboardSettings(consoleKeymap: 'es', x11Layout: 'es'),
    'fr' => const TargetKeyboardSettings(consoleKeymap: 'fr', x11Layout: 'fr'),
    'la-latin1' => const TargetKeyboardSettings(
      consoleKeymap: 'la-latin1',
      x11Layout: 'latam',
    ),
    'br-abnt2' => const TargetKeyboardSettings(
      consoleKeymap: 'br-abnt2',
      x11Layout: 'br',
    ),
    'it' => const TargetKeyboardSettings(consoleKeymap: 'it', x11Layout: 'it'),
    'ru' => const TargetKeyboardSettings(consoleKeymap: 'ru', x11Layout: 'ru'),
    'ara' => const TargetKeyboardSettings(
      consoleKeymap: 'ara',
      x11Layout: 'ara',
    ),
    // Persian console keymap uses "fa", while X11 layout is exposed as "ir".
    'fa' => const TargetKeyboardSettings(consoleKeymap: 'fa', x11Layout: 'ir'),
    'ir' => const TargetKeyboardSettings(consoleKeymap: 'fa', x11Layout: 'ir'),
    'jp106' => const TargetKeyboardSettings(
      consoleKeymap: 'jp106',
      x11Layout: 'jp',
    ),
    'cn' => const TargetKeyboardSettings(consoleKeymap: 'cn', x11Layout: 'cn'),
    'us' => const TargetKeyboardSettings(consoleKeymap: 'us', x11Layout: 'us'),
    _ when keymap.isNotEmpty => TargetKeyboardSettings(
      consoleKeymap: keymap,
      x11Layout: keymap,
    ),
    _ => const TargetKeyboardSettings(consoleKeymap: 'us', x11Layout: 'us'),
  };
}

String renderX11KeyboardConfig(TargetKeyboardSettings settings) {
  final lines = <String>[
    'Section "InputClass"',
    '    Identifier "system-keyboard"',
    '    MatchIsKeyboard "on"',
    '    Option "XkbLayout" "${settings.x11Layout}"',
  ];

  if (settings.hasVariant) {
    lines.add('    Option "XkbVariant" "${settings.x11Variant}"');
  }

  lines.add('EndSection');
  return lines.join('\n');
}

String _normalizeLanguageCode(String value) {
  final trimmed = value.trim().replaceAll('-', '_');
  if (trimmed.isEmpty) {
    return '';
  }

  final parts = trimmed.split('_');
  if (parts.length == 1) {
    return parts.first.toLowerCase();
  }

  return '${parts.first.toLowerCase()}_${parts[1].toUpperCase()}';
}

String _normalizeLocale(String value) {
  final trimmed = value.trim().replaceAll('-', '_');
  if (trimmed.isEmpty) {
    return 'en_US.UTF-8';
  }

  final parts = trimmed.split('.');
  final localeName = parts.first;
  final encoding = parts.length > 1 ? parts[1].toUpperCase() : 'UTF-8';
  final localeParts = localeName.split('_');

  if (localeParts.length == 1) {
    return '${localeParts.first.toLowerCase()}.$encoding';
  }

  return '${localeParts.first.toLowerCase()}_${localeParts[1].toUpperCase()}.$encoding';
}

String _defaultLocaleFor(String languageCode) {
  return switch (languageCode) {
    'tr' => 'tr_TR.UTF-8',
    'es' => 'es_ES.UTF-8',
    'de' => 'de_DE.UTF-8',
    'fr' => 'fr_FR.UTF-8',
    'pt_BR' => 'pt_BR.UTF-8',
    'it' => 'it_IT.UTF-8',
    'ru' => 'ru_RU.UTF-8',
    'ar' => 'ar_SA.UTF-8',
    'fa' => 'fa_IR.UTF-8',
    'zh_CN' => 'zh_CN.UTF-8',
    'ja' => 'ja_JP.UTF-8',
    _ => 'en_US.UTF-8',
  };
}
