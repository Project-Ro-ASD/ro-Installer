import 'dart:convert';
import 'dart:io';

void main() {
  final manifest =
      (jsonDecode(File('assets/i18n/locales.json').readAsStringSync())
              as List<dynamic>)
          .cast<Map<String, dynamic>>();
  final fallback = _readTranslation('en');

  stdout.writeln('Locale audit');
  stdout.writeln('============');

  for (final locale in manifest) {
    final code = locale['code'] as String;
    final enabled = locale['enabled'] as bool? ?? true;
    final status = locale['translationStatus']?.toString() ?? '';
    final translations = _readTranslation(code);

    final placeholdersOk = _placeholdersMatch(fallback, translations);
    final identicalRatio = _identicalRatio(fallback, translations);

    stdout.writeln(
      '$code  enabled=$enabled  status=${status.isEmpty ? '-' : status}  identical=${(identicalRatio * 100).toStringAsFixed(1)}%  placeholders=${placeholdersOk ? 'ok' : 'mismatch'}',
    );
  }
}

Map<String, dynamic> _readTranslation(String code) {
  return jsonDecode(File('assets/i18n/$code.json').readAsStringSync())
      as Map<String, dynamic>;
}

bool _placeholdersMatch(
  Map<String, dynamic> fallback,
  Map<String, dynamic> translations,
) {
  for (final entry in fallback.entries) {
    final fallbackValue = entry.value;
    final translatedValue = translations[entry.key];
    if (fallbackValue is! String || translatedValue is! String) {
      continue;
    }
    final fallbackPlaceholders = _placeholderMatches(fallbackValue);
    final translatedPlaceholders = _placeholderMatches(translatedValue);
    if (!_sameList(fallbackPlaceholders, translatedPlaceholders)) {
      return false;
    }
  }
  return true;
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

List<String> _placeholderMatches(String value) {
  final matches = RegExp(
    r'\{([A-Za-z0-9_]+)\}',
  ).allMatches(value).map((match) => match.group(1)!).toList()..sort();
  return matches;
}

bool _sameList(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}
