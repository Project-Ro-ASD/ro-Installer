import 'package:test/test.dart';
import 'package:ro_installer/services/target_system_settings.dart';

void main() {
  group('TargetSystemSettings', () {
    test('brazilya klavyesi x11 icin br yerlesimine donusturulur', () {
      final settings = resolveTargetKeyboardSettings('br-abnt2');

      expect(settings.consoleKeymap, 'br-abnt2');
      expect(settings.x11Layout, 'br');
      expect(settings.hasVariant, false);
    });

    test('japonca klavye x11 icin jp yerlesimine donusturulur', () {
      final settings = resolveTargetKeyboardSettings('jp106');

      expect(settings.consoleKeymap, 'jp106');
      expect(settings.x11Layout, 'jp');
      expect(settings.hasVariant, false);
    });

    test('latin amerika klavyesi x11 icin latam yerlesimine donusturulur', () {
      final settings = resolveTargetKeyboardSettings('la-latin1');

      expect(settings.consoleKeymap, 'la-latin1');
      expect(settings.x11Layout, 'latam');
      expect(settings.hasVariant, false);
    });

    test('farsca klavye x11 icin ir yerlesimine donusturulur', () {
      final settings = resolveTargetKeyboardSettings('fa');

      expect(settings.consoleKeymap, 'fa');
      expect(settings.x11Layout, 'ir');
    });

    test('brezilya locale paketi ulke kodunu korur', () {
      final settings = resolveTargetLocaleSettings(
        selectedLanguage: 'pt_BR',
        selectedLocale: '',
      );

      expect(settings.locale, 'pt_BR.UTF-8');
      expect(settings.requiredPackages, [
        'glibc-langpack-pt',
        'langpacks-pt_BR',
      ]);
    });
  });
}
