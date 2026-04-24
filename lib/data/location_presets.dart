class LocationPreset {
  const LocationPreset({
    required this.region,
    required this.countryCode,
    required this.timezone,
    required this.keyboard,
    required this.languageCode,
  });

  final String region;
  final String countryCode;
  final String timezone;
  final String keyboard;
  final String languageCode;
}

LocationPreset? defaultLocationPresetForLanguage(
  String languageCode, {
  String localeName = '',
}) {
  final normalizedRegionCode = _regionCodeFromLocaleName(localeName);

  if (normalizedRegionCode.isNotEmpty) {
    for (final preset in kLocationPresets) {
      if (preset.languageCode == languageCode &&
          preset.countryCode == normalizedRegionCode) {
        return preset;
      }
    }
  }

  for (final preset in kLocationPresets) {
    if (preset.languageCode == languageCode) {
      return preset;
    }
  }

  return null;
}

String _regionCodeFromLocaleName(String localeName) {
  final sanitized = localeName
      .trim()
      .split('.')
      .first
      .split('@')
      .first
      .replaceAll('-', '_');
  final parts = sanitized.split('_');
  if (parts.length < 2) {
    return '';
  }
  return parts[1].toUpperCase();
}

const List<LocationPreset> kLocationPresets = <LocationPreset>[
  LocationPreset(
    region: 'United States',
    countryCode: 'US',
    timezone: 'America/New_York',
    keyboard: 'us',
    languageCode: 'en',
  ),
  LocationPreset(
    region: 'Canada',
    countryCode: 'CA',
    timezone: 'America/Toronto',
    keyboard: 'us',
    languageCode: 'en',
  ),
  LocationPreset(
    region: 'United Kingdom',
    countryCode: 'GB',
    timezone: 'Europe/London',
    keyboard: 'uk',
    languageCode: 'en',
  ),
  LocationPreset(
    region: 'Australia',
    countryCode: 'AU',
    timezone: 'Australia/Sydney',
    keyboard: 'uk',
    languageCode: 'en',
  ),
  LocationPreset(
    region: 'Ireland',
    countryCode: 'IE',
    timezone: 'Europe/Dublin',
    keyboard: 'uk',
    languageCode: 'en',
  ),
  LocationPreset(
    region: 'Türkiye',
    countryCode: 'TR',
    timezone: 'Europe/Istanbul',
    keyboard: 'trq',
    languageCode: 'tr',
  ),
  LocationPreset(
    region: 'Deutschland',
    countryCode: 'DE',
    timezone: 'Europe/Berlin',
    keyboard: 'de',
    languageCode: 'de',
  ),
  LocationPreset(
    region: 'Österreich',
    countryCode: 'AT',
    timezone: 'Europe/Vienna',
    keyboard: 'de',
    languageCode: 'de',
  ),
  LocationPreset(
    region: 'Schweiz',
    countryCode: 'CH',
    timezone: 'Europe/Zurich',
    keyboard: 'de',
    languageCode: 'de',
  ),
  LocationPreset(
    region: 'España',
    countryCode: 'ES',
    timezone: 'Europe/Madrid',
    keyboard: 'es',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'México',
    countryCode: 'MX',
    timezone: 'America/Mexico_City',
    keyboard: 'la-latin1',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'Argentina',
    countryCode: 'AR',
    timezone: 'America/Argentina/Buenos_Aires',
    keyboard: 'la-latin1',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'Colombia',
    countryCode: 'CO',
    timezone: 'America/Bogota',
    keyboard: 'la-latin1',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'Chile',
    countryCode: 'CL',
    timezone: 'America/Santiago',
    keyboard: 'la-latin1',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'Perú',
    countryCode: 'PE',
    timezone: 'America/Lima',
    keyboard: 'la-latin1',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'Uruguay',
    countryCode: 'UY',
    timezone: 'America/Montevideo',
    keyboard: 'la-latin1',
    languageCode: 'es',
  ),
  LocationPreset(
    region: 'France',
    countryCode: 'FR',
    timezone: 'Europe/Paris',
    keyboard: 'fr',
    languageCode: 'fr',
  ),
  LocationPreset(
    region: 'Belgique',
    countryCode: 'BE',
    timezone: 'Europe/Brussels',
    keyboard: 'fr',
    languageCode: 'fr',
  ),
  LocationPreset(
    region: 'Brasil',
    countryCode: 'BR',
    timezone: 'America/Sao_Paulo',
    keyboard: 'br-abnt2',
    languageCode: 'pt_BR',
  ),
  LocationPreset(
    region: 'Italia',
    countryCode: 'IT',
    timezone: 'Europe/Rome',
    keyboard: 'it',
    languageCode: 'it',
  ),
  LocationPreset(
    region: 'Россия',
    countryCode: 'RU',
    timezone: 'Europe/Moscow',
    keyboard: 'ru',
    languageCode: 'ru',
  ),
  LocationPreset(
    region: 'السعودية',
    countryCode: 'SA',
    timezone: 'Asia/Riyadh',
    keyboard: 'ara',
    languageCode: 'ar',
  ),
  LocationPreset(
    region: 'الإمارات',
    countryCode: 'AE',
    timezone: 'Asia/Dubai',
    keyboard: 'ara',
    languageCode: 'ar',
  ),
  LocationPreset(
    region: 'مصر',
    countryCode: 'EG',
    timezone: 'Africa/Cairo',
    keyboard: 'ara',
    languageCode: 'ar',
  ),
  LocationPreset(
    region: 'المغرب',
    countryCode: 'MA',
    timezone: 'Africa/Casablanca',
    keyboard: 'ara',
    languageCode: 'ar',
  ),
  LocationPreset(
    region: 'لبنان',
    countryCode: 'LB',
    timezone: 'Asia/Beirut',
    keyboard: 'ara',
    languageCode: 'ar',
  ),
  LocationPreset(
    region: 'ایران',
    countryCode: 'IR',
    timezone: 'Asia/Tehran',
    keyboard: 'fa',
    languageCode: 'fa',
  ),
  LocationPreset(
    region: '日本',
    countryCode: 'JP',
    timezone: 'Asia/Tokyo',
    keyboard: 'jp106',
    languageCode: 'ja',
  ),
  LocationPreset(
    region: '中国',
    countryCode: 'CN',
    timezone: 'Asia/Shanghai',
    keyboard: 'cn',
    languageCode: 'zh_CN',
  ),
];
