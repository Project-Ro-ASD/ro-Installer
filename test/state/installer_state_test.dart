import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/state/installer_state.dart';

void main() {
  group('InstallerState location presets', () {
    late InstallerState state;

    setUp(() {
      state = InstallerState(translations: _catalog());
    });

    tearDown(() {
      state.dispose();
    });

    test('ulke preset secimi timezone ve klavye degerlerini gunceller', () {
      state.applyLocationPreset('日本');

      expect(state.selectedRegion, '日本');
      expect(state.selectedTimezone, 'Asia/Tokyo');
      expect(state.selectedKeyboard, 'jp106');
      expect(state.selectedRegionPreset?.languageCode, 'ja');
      expect(state.selectedKeyboardLabel, 'Japanese (106/109)');
    });

    test('ulke preset secimi kullanicinin dil secimini ezmez', () {
      state.updateLanguage('en');

      state.applyLocationPreset('Brasil');

      expect(state.selectedLanguage, 'en');
      expect(state.selectedTimezone, 'America/Sao_Paulo');
      expect(state.selectedKeyboard, 'br-abnt2');
      expect(state.selectedKeyboardLabel, 'Brazilian Portuguese (ABNT2)');
    });

    test('preset listesi yirmi bes ulkenin uzerine cikarildi', () {
      expect(state.locationPresets.length, greaterThanOrEqualTo(25));
      expect(state.availableRegions, contains('México'));
      expect(state.availableRegions, contains('United Kingdom'));
      expect(state.availableRegions, contains('مصر'));
    });

    test('latin amerika klavyesi icin insan okunur etiket dondurur', () {
      state.applyLocationPreset('Argentina');

      expect(state.selectedKeyboard, 'la-latin1');
      expect(state.selectedKeyboardLabel, 'Latin American Spanish');
    });

    test('welcome dil secimi varsayilan konum presetini otomatik esler', () {
      state.updateLanguage('ja');

      expect(state.selectedRegion, '日本');
      expect(state.selectedTimezone, 'Asia/Tokyo');
      expect(state.selectedKeyboard, 'jp106');

      state.updateLanguage('en');

      expect(state.selectedRegion, 'United States');
      expect(state.selectedTimezone, 'America/New_York');
      expect(state.selectedKeyboard, 'us');
    });

    test('dil guncellemesi sync kapaliyken mevcut konumu korur', () {
      state.applyLocationPreset('México');

      state.updateLanguage('es', syncLocationPreset: false);

      expect(state.selectedLanguage, 'es');
      expect(state.selectedRegion, 'México');
      expect(state.selectedTimezone, 'America/Mexico_City');
      expect(state.selectedKeyboard, 'la-latin1');
    });

    test('sistem locale bolgesi varsa ayni dil icin uygun preset secilir', () {
      final britishState = InstallerState(
        translations: _catalog(),
        platformLocaleName: 'en_GB.UTF-8',
      );
      addTearDown(britishState.dispose);

      britishState.updateLanguage('en');

      expect(britishState.selectedRegion, 'United Kingdom');
      expect(britishState.selectedTimezone, 'Europe/London');
      expect(britishState.selectedKeyboard, 'uk');

      final mexicoState = InstallerState(
        translations: _catalog(),
        platformLocaleName: 'es_MX.UTF-8',
      );
      addTearDown(mexicoState.dispose);

      mexicoState.updateLanguage('es');

      expect(mexicoState.selectedRegion, 'México');
      expect(mexicoState.selectedTimezone, 'America/Mexico_City');
      expect(mexicoState.selectedKeyboard, 'la-latin1');
    });
  });
}

InstallerTranslationCatalog _catalog() {
  return InstallerTranslationCatalog(
    <String, Map<String, String>>{
      'en': <String, String>{'next': 'Next'},
      'tr': <String, String>{'next': 'Ileri'},
      'es': <String, String>{'next': 'Siguiente'},
      'ja': <String, String>{'next': 'Next'},
      'pt_BR': <String, String>{'next': 'Next'},
    },
    locales: const <InstallerLocale>[
      InstallerLocale(
        code: 'en',
        locale: 'en_US.UTF-8',
        nativeName: 'English',
        englishName: 'English',
      ),
      InstallerLocale(
        code: 'tr',
        locale: 'tr_TR.UTF-8',
        nativeName: 'Türkçe',
        englishName: 'Turkish',
      ),
      InstallerLocale(
        code: 'es',
        locale: 'es_ES.UTF-8',
        nativeName: 'Español',
        englishName: 'Spanish',
      ),
      InstallerLocale(
        code: 'ja',
        locale: 'ja_JP.UTF-8',
        nativeName: '日本語',
        englishName: 'Japanese',
      ),
      InstallerLocale(
        code: 'pt_BR',
        locale: 'pt_BR.UTF-8',
        nativeName: 'Português do Brasil',
        englishName: 'Brazilian Portuguese',
      ),
    ],
  );
}
