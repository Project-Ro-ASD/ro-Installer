import 'dart:convert';

import 'package:flutter/services.dart';

class InstallerLocale {
  const InstallerLocale({
    required this.code,
    required this.locale,
    required this.nativeName,
    required this.englishName,
    this.textDirection = 'ltr',
    this.enabled = true,
    this.translationStatus = '',
  });

  factory InstallerLocale.fromJson(Map<String, dynamic> json) {
    return InstallerLocale(
      code: json['code'].toString(),
      locale: json['locale'].toString(),
      nativeName: json['nativeName'].toString(),
      englishName: json['englishName'].toString(),
      textDirection: json['textDirection']?.toString() ?? 'ltr',
      enabled: json['enabled'] as bool? ?? true,
      translationStatus: json['translationStatus']?.toString() ?? '',
    );
  }

  final String code;
  final String locale;
  final String nativeName;
  final String englishName;
  final String textDirection;
  final bool enabled;
  final String translationStatus;

  bool get isRightToLeft => textDirection == 'rtl';
  bool get isDraft => translationStatus == 'draft';
}

class InstallerTranslationCatalog {
  InstallerTranslationCatalog(
    this._translations, {
    required this.locales,
    this.fallbackLocale = 'en',
  });

  static const String localeManifestPath = 'assets/i18n/locales.json';

  final Map<String, Map<String, String>> _translations;
  final List<InstallerLocale> locales;
  final String fallbackLocale;

  List<InstallerLocale> get selectableLocales {
    return locales.where((locale) => locale.enabled).toList(growable: false);
  }

  List<InstallerLocale> get inactiveLocales {
    return locales.where((locale) => !locale.enabled).toList(growable: false);
  }

  InstallerLocale? localeFor(String code) {
    for (final locale in locales) {
      if (locale.code == code) {
        return locale;
      }
    }
    return null;
  }

  static Future<InstallerTranslationCatalog> loadBundled() async {
    final locales = await _loadLocaleManifest();
    final translations = <String, Map<String, String>>{};

    for (final locale in locales) {
      final raw = await rootBundle.loadString(
        'assets/i18n/${locale.code}.json',
      );
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      translations[locale.code] = decoded.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    }

    return InstallerTranslationCatalog(translations, locales: locales);
  }

  static Future<List<InstallerLocale>> _loadLocaleManifest() async {
    final raw = await rootBundle.loadString(localeManifestPath);
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) => InstallerLocale.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  String translate(String locale, String key) {
    return _translations[locale]?[key] ??
        _translations[fallbackLocale]?[key] ??
        key;
  }

  List<String> missingKeys(String locale) {
    final fallbackKeys = _translations[fallbackLocale]?.keys.toSet() ?? {};
    final localeKeys = _translations[locale]?.keys.toSet() ?? {};
    return (fallbackKeys.difference(localeKeys).toList())..sort();
  }
}
