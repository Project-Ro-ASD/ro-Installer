import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _fallbackLocale = 'en';
const _maxEnabledLocaleIdenticalRatio = 0.10;

void main() {
  group('i18n assets', () {
    test('locale manifest points to existing translation files', () {
      final manifestFile = File('assets/i18n/locales.json');
      expect(manifestFile.existsSync(), true);

      final manifest =
          (jsonDecode(manifestFile.readAsStringSync()) as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final codes = manifest.map((locale) => locale['code'] as String).toList();

      expect(codes, isNotEmpty);
      expect(codes.toSet().length, codes.length);

      for (final code in codes) {
        expect(File('assets/i18n/$code.json').existsSync(), true);
      }
    });

    test('all translation files keep the same key set', () {
      final fallback = _readTranslation(_fallbackLocale);
      final manifest =
          (jsonDecode(File('assets/i18n/locales.json').readAsStringSync())
                  as List<dynamic>)
              .cast<Map<String, dynamic>>();

      for (final locale in manifest) {
        final code = locale['code'] as String;
        final translations = _readTranslation(code);

        expect(
          translations.keys.toSet(),
          fallback.keys.toSet(),
          reason: '$code.json must match en.json translation keys',
        );
      }
    });

    test('all translation files preserve placeholder names', () {
      final fallback = _readTranslation(_fallbackLocale);
      final manifest =
          (jsonDecode(File('assets/i18n/locales.json').readAsStringSync())
                  as List<dynamic>)
              .cast<Map<String, dynamic>>();

      for (final locale in manifest) {
        final code = locale['code'] as String;
        final translations = _readTranslation(code);

        for (final entry in fallback.entries) {
          final fallbackValue = entry.value;
          final translatedValue = translations[entry.key];
          if (fallbackValue is! String || translatedValue is! String) {
            continue;
          }

          expect(
            _placeholders(fallbackValue),
            _placeholders(translatedValue),
            reason: '$code.json must preserve placeholders for ${entry.key}',
          );
        }
      }
    });

    test('enabled non-fallback locales are not English seed copies', () {
      final fallback = _readTranslation(_fallbackLocale);
      final manifest =
          (jsonDecode(File('assets/i18n/locales.json').readAsStringSync())
                  as List<dynamic>)
              .cast<Map<String, dynamic>>();

      for (final locale in manifest) {
        final code = locale['code'] as String;
        final enabled = locale['enabled'] as bool? ?? true;
        if (!enabled || code == _fallbackLocale) {
          continue;
        }

        final translations = _readTranslation(code);
        final identicalRatio = _identicalRatio(fallback, translations);

        expect(
          identicalRatio,
          lessThanOrEqualTo(_maxEnabledLocaleIdenticalRatio),
          reason:
              '$code.json still looks too close to en.json to be enabled (${(identicalRatio * 100).toStringAsFixed(1)}% identical)',
        );
      }
    });
  });
}

Map<String, dynamic> _readTranslation(String code) {
  return jsonDecode(File('assets/i18n/$code.json').readAsStringSync())
      as Map<String, dynamic>;
}

List<String> _placeholders(String value) {
  return RegExp(
    r'\{([A-Za-z0-9_]+)\}',
  ).allMatches(value).map((match) => match.group(1)!).toList()..sort();
}

double _identicalRatio(
  Map<String, dynamic> fallback,
  Map<String, dynamic> translations,
) {
  var total = 0;
  var identical = 0;

  for (final entry in fallback.entries) {
    final fallbackValue = entry.value;
    final translatedValue = translations[entry.key];
    if (fallbackValue is! String || translatedValue is! String) {
      continue;
    }

    total++;
    if (fallbackValue.trim() == translatedValue.trim()) {
      identical++;
    }
  }

  if (total == 0) {
    return 0;
  }

  return identical / total;
}
