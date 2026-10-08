import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/screens/disk_selection_screen.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/disk_service.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/helper_protocol.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';

class ProbeClient extends HelperClient {
  final identity = DeviceIdentity(
    path: '/dev/vda',
    majorMinor: '252:0',
    size: 68719476736,
    diskSequence: 11,
  );
  final paths = <String>[];
  @override
  Future<DeviceIdentity> probe(String disk) async {
    paths.add(disk);
    return identity;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InstallerTranslationCatalog catalog;
  setUpAll(() async {
    catalog = await InstallerTranslationCatalog.loadBundled();
  });
  testWidgets(
    'confirmation uses fresh helper identity and never probes listing',
    (tester) async {
      final runner = FakeCommandRunner();
      runner.addResponseForCommand(
        'lsblk',
        stdout: jsonEncode({
          'blockdevices': [
            {
              'name': 'vda',
              'model': null,
              'type': 'disk',
              'size': 34359738368,
              'rm': false,
              'mountpoints': [null],
            },
          ],
        }),
      );
      CommandRunner.setInstance(runner);
      addTearDown(CommandRunner.resetInstance);
      final client = ProbeClient();
      final state = InstallerState(translations: catalog)..nextStep();
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: DiskSelectionScreen(
                diskService: DiskService(commandRunner: runner),
                helperClient: client,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(state.selectedDisk, '/dev/vda');
      expect(client.paths, isEmpty);
      await tester.tap(find.text(state.t('next')));
      await tester.pumpAndSettle();
      expect(client.paths, ['/dev/vda']);
      expect(find.textContaining('/dev/vda (64.0 GiB)'), findsOneWidget);
      expect(state.confirmedDevice, isNull);
      await tester.tap(find.text(state.t('cancel')));
      await tester.pumpAndSettle();
      expect(state.currentStep, 1);
      expect(state.confirmedDevice, isNull);
      await tester.tap(find.text(state.t('next')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(state.t('disk_danger_confirm_action')));
      await tester.pumpAndSettle();
      expect(client.paths, ['/dev/vda', '/dev/vda']);
      expect(state.confirmedDevice, same(client.identity));
      expect(state.currentStep, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
  for (final failure in [false, true]) {
    testWidgets(
      'discovery error=$failure is distinct from successful empty inventory',
      (tester) async {
        final runner = FakeCommandRunner();
        runner.addResponseForCommand(
          'lsblk',
          exitCode: failure ? 1 : 0,
          stdout: '{"blockdevices":[]}',
          stderr: 'secret',
        );
        CommandRunner.setInstance(runner);
        addTearDown(CommandRunner.resetInstance);
        final state = InstallerState(translations: catalog);
        state.selectedDisk = '/dev/stale';
        state.selectedDiskDetails = {'name': '/dev/stale'};
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: MaterialApp(
              theme: AppTheme.darkTheme,
              home: Scaffold(
                body: DiskSelectionScreen(
                  diskService: DiskService(commandRunner: runner),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('disk-discovery-error')),
          failure ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(state.t('disk_empty_title')),
          failure ? findsNothing : findsOneWidget,
        );
        expect(find.textContaining('secret'), findsNothing);
        expect(state.selectedDisk, isEmpty);
        expect(state.confirmedDevice, isNull);
        state.beginInstallation();
        state.nextStep();
        state.nextStep();
        final step = state.currentStep;
        state.previousStep();
        state.goToStep(0);
        expect(state.currentStep, step);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
