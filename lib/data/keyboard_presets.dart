class KeyboardPreset {
  const KeyboardPreset({required this.code, required this.label});

  final String code;
  final String label;
}

const List<KeyboardPreset> kKeyboardPresets = <KeyboardPreset>[
  KeyboardPreset(code: 'us', label: 'English (US)'),
  KeyboardPreset(code: 'uk', label: 'English (UK)'),
  KeyboardPreset(code: 'trq', label: 'Turkish Q'),
  KeyboardPreset(code: 'trf', label: 'Turkish F'),
  KeyboardPreset(code: 'de', label: 'German'),
  KeyboardPreset(code: 'es', label: 'Spanish'),
  KeyboardPreset(code: 'la-latin1', label: 'Latin American Spanish'),
  KeyboardPreset(code: 'fr', label: 'French'),
  KeyboardPreset(code: 'br-abnt2', label: 'Brazilian Portuguese (ABNT2)'),
  KeyboardPreset(code: 'it', label: 'Italian'),
  KeyboardPreset(code: 'ru', label: 'Russian'),
  KeyboardPreset(code: 'ara', label: 'Arabic'),
  KeyboardPreset(code: 'fa', label: 'Persian'),
  KeyboardPreset(code: 'jp106', label: 'Japanese (106/109)'),
  KeyboardPreset(code: 'cn', label: 'Chinese'),
];
