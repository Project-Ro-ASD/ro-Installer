typedef InstallTranslator =
    String Function(String key, [Map<String, String> placeholders]);

class InstallLocalizer {
  const InstallLocalizer({this.translate});

  final InstallTranslator? translate;

  String t(
    String key,
    String fallback, [
    Map<String, String> placeholders = const {},
  ]) {
    final translated = translate?.call(key, placeholders);
    final value = translated == null || translated == key
        ? _interpolate(fallback, placeholders)
        : translated;
    return value;
  }

  static String _interpolate(String value, Map<String, String> placeholders) {
    var result = value;
    for (final entry in placeholders.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }
}
