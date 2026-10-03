import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/screens/disk_selection_screen.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';

void main() {
  group('InstallerState interactive wizard', () {
    const expectedSteps = ['Welcome', 'Location', 'Account', 'Disk', 'Install'];
    late InstallerState state;
    late FakeCommandRunner runner;

    setUp(() {
      runner = FakeCommandRunner();
      CommandRunner.setInstance(runner);
      state = InstallerState(translations: _catalog());
    });

    tearDown(() {
      state.dispose();
      CommandRunner.resetInstance();
    });

    test('fresh state exposes only the transitional wizard steps', () {
      expect(state.steps, expectedSteps);
      expect(state.currentStep, 0);
      expect(state.partitionMethod, 'full');
      expect(state.selectedKernelChannelsList, ['stable']);
      expect(state.username, isEmpty);
      expect(state.password, isEmpty);
    });

    test('legacy storage data does not expose removed pages', () {
      state.partitionMethod = 'manual';
      state.manualPartitions.add({'mountPoint': '/'});

      expect(state.partitionMethod, 'manual');
      expect(state.manualPartitions, isNotEmpty);
      expect(state.steps, expectedSteps);
    });

    testWidgets('construction does not start network commands or polling', (
      tester,
    ) async {
      expect(runner.commandLog, isEmpty);
      await tester.pump(const Duration(seconds: 11));
      expect(runner.commandLog, isEmpty);
    });

    test('kernel compatibility is fixed and cannot be mutated', () {
      final channels = state.selectedKernelChannelsList;

      expect(channels, ['stable']);
      expect(() => channels.add('experimental'), throwsUnsupportedError);
      expect(() => channels[0] = 'experimental', throwsUnsupportedError);
      expect(state.selectedKernelChannelsList, ['stable']);
    });

    testWidgets('disk UI exposes only the existing standard-path controls', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      runner.addResponseForCommand('lsblk', stdout: '{"blockdevices":[]}');
      state.selectedDisk = '/dev/test';
      state.selectedDiskDetails = {
        'name': '/dev/test',
        'model': 'Test disk',
        'size': 120 * 1024 * 1024 * 1024,
      };

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: DiskSelectionScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('disk_full'), findsOneWidget);
      expect(find.text('disk_alongside'), findsOneWidget);
      expect(find.text('install_type_standard'), findsOneWidget);
      expect(find.text('install_type_advanced'), findsNothing);
      expect(find.text('type_adv_desc'), findsNothing);
      expect(find.text('disk_manual'), findsNothing);
      expect(find.text('disk_free_space_method'), findsNothing);
      expect(runner.wasCommandCalled('nmcli'), isFalse);
    });

    test('navigation follows the shortened wizard and stops at Install', () {
      for (final step in expectedSteps) {
        expect(state.steps[state.currentStep], step);
        state.nextStep();
      }
      expect(state.currentStep, expectedSteps.length - 1);

      state.previousStep();
      expect(state.steps[state.currentStep], 'Disk');
      state.previousStep();
      expect(state.steps[state.currentStep], 'Account');
      state.previousStep();
      expect(state.steps[state.currentStep], 'Location');
      state.previousStep();
      state.previousStep();
      expect(state.currentStep, 0);
    });
  });

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

    test('interactive partition updates retain standard-path restrictions', () {
      state.updateFreeSpaceSelection({
        'startSector': 2048,
        'endSector': 4096,
        'sizeBytes': 1024,
      });
      state.updatePartitionMethod('free_space');

      expect(state.partitionMethod, 'full');
      expect(state.selectedFreeSpace, isEmpty);

      state.updatePartitionMethod('manual');
      expect(state.partitionMethod, 'full');

      state.updatePartitionMethod('alongside');
      expect(state.partitionMethod, 'alongside');
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
