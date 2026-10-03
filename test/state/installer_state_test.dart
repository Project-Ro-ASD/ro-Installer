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
    const expectedSteps = ['Welcome', 'Disk', 'Install'];
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
      expect(find.text('disk_alongside'), findsNothing);
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
      expect(state.steps[state.currentStep], 'Welcome');
      state.previousStep();
      expect(state.currentStep, 0);
    });
  });

  group('InstallerState UI language', () {
    late InstallerState state;

    setUp(() {
      state = InstallerState(translations: _catalog());
    });

    tearDown(() {
      state.dispose();
    });

    test(
      'language only updates the UI and preserves disk/storage selection',
      () {
        state.selectedDisk = '/dev/vda';
        state.updateLanguage('ja');
        expect(state.selectedLanguage, 'ja');
        expect(state.selectedLocale.locale, 'ja_JP.UTF-8');
        expect(state.selectedDisk, '/dev/vda');
        expect(state.partitionMethod, 'full');
        expect(state.steps, ['Welcome', 'Disk', 'Install']);
        state.updateLanguage('unsupported');
        expect(state.selectedLanguage, 'ja');
      },
    );

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
      expect(state.partitionMethod, 'full');
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
