import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/free_space_installation_plan.dart';
import 'package:ro_installer/screens/disk_selection_screen.dart';
import 'package:ro_installer/screens/installing_screen.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/disk_service.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_log_export_service.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';
import '../services/helper_client_test.dart' as f;

Map<String, dynamic> snapshotJson() =>
    jsonDecode(
          File('test/fixtures/gpt_probe_snapshot_v1.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

class Probe extends HelperClient {
  Probe() : super(protocolVersion: 2);
  Future<GptDiskSnapshot>? pending;
  GptDiskSnapshot value = GptDiskSnapshot.fromJson(snapshotJson());
  final calls = <String>[];
  @override
  Future<GptDiskSnapshot> probeFreeSpace(String disk) async {
    calls.add(disk);
    return pending ?? value;
  }
}

void main() {
  late InstallerTranslationCatalog catalog;
  setUpAll(() async {
    catalog = await InstallerTranslationCatalog.loadBundled();
  });
  Future<InstallerState> show(WidgetTester tester, Probe probe) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final runner = FakeCommandRunner();
    CommandRunner.setInstance(runner);
    addTearDown(CommandRunner.resetInstance);
    runner.addResponseForCommand(
      'lsblk',
      stdout: jsonEncode({
        'blockdevices': [
          {
            'name': 'vda',
            'type': 'disk',
            'model': 'Fixture',
            'size': 256 * 1024 * 1024 * 1024,
            'rm': false,
            'mountpoints': [null],
          },
        ],
      }),
    );
    final state = InstallerState(translations: catalog)
      ..selectedLanguage = 'en'
      ..nextStep();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: DiskSelectionScreen(
              diskService: DiskService(commandRunner: runner),
              helperClient: probe,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(state.t('disk_free_space_method').replaceAll('\n', ' ')),
    );
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('free-space scan, cancel and approval retain a typed proposal', (
    tester,
  ) async {
    final probe = Probe();
    final state = await show(tester, probe);
    expect(state.partitionMethod, 'free_space');
    expect(state.selectedFreeSpacePlan, isNull);
    await tester.tap(find.text(state.t('disk_free_space_probe')));
    await tester.pumpAndSettle();
    expect(probe.calls, ['/dev/vda']);
    expect(state.selectedFreeSpacePlan, isNotNull);
    expect(find.byKey(const ValueKey('free-space-extent')), findsOneWidget);
    await tester.tap(find.text(state.t('next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('512 MiB FAT32'), findsOneWidget);
    expect(state.confirmedFreeSpacePlan, isNull);
    await tester.tap(find.text(state.t('cancel')));
    await tester.pumpAndSettle();
    expect(state.currentStep, 1);
    await tester.tap(find.text(state.t('next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(state.t('disk_free_space_confirm_action')));
    await tester.pumpAndSettle();
    expect(state.currentStep, 2);
    expect(state.confirmedFreeSpacePlan, same(state.selectedFreeSpacePlan));
    expect(state.confirmedDevice!.json, probe.value.device.json);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets('stale scan cannot replace a selection changed away and back', (
    tester,
  ) async {
    final ready = Completer<GptDiskSnapshot>();
    final probe = Probe()..pending = ready.future;
    final state = await show(tester, probe);
    await tester.tap(find.text(state.t('disk_free_space_probe')));
    await tester.pump();
    state.updateDiskParams('/dev/vdb', 'btrfs', 'free_space');
    state.updateDiskParams('/dev/vda', 'btrfs', 'free_space');
    ready.complete(probe.value);
    await tester.pumpAndSettle();
    expect(state.selectedFreeSpacePlan, isNull);
    expect(state.confirmedFreeSpacePlan, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets('changed mode invalidates an open free-space confirmation', (
    tester,
  ) async {
    final state = await show(tester, Probe());
    await tester.tap(find.text(state.t('disk_free_space_probe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(state.t('next')));
    await tester.pumpAndSettle();
    state.updatePartitionMethod('full');
    state.updatePartitionMethod('free_space');
    await tester.tap(find.text(state.t('disk_free_space_confirm_action')));
    await tester.pumpAndSettle();
    expect(state.currentStep, 1);
    expect(state.confirmedFreeSpacePlan, isNull);
    expect(state.confirmedDevice, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets(
    'install screen sends a compact free-space request and requires terminal success',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = GptDiskSnapshot.fromJson(snapshotJson());
      final plan = FreeSpaceInstallationPlan.build(
        snapshot,
        snapshot.freeExtents.first,
      );
      final state = InstallerState(translations: catalog)
        ..selectedLanguage = 'en';
      state.updateDiskParams('/dev/vda', 'btrfs', 'free_space');
      state.selectFreeSpacePlan(plan);
      state.confirmFreeSpacePlan(plan, state.diskSelectionRevision);
      final process = f.FakeHelperProcess(
        f.messages([
          {
            'protocolVersion': 2,
            'type': 'result',
            'operation': 'install-free-space',
            'ok': true,
            'installed': true,
          },
        ]),
      );
      var exported = false;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: InstallingScreen(
                helperClient: HelperClient(
                  protocolVersion: 2,
                  start: (_, _) async => process,
                ),
                exportSession:
                    ({
                      required startedAt,
                      required finishedAt,
                      required success,
                      required finalStatus,
                      required statusHistory,
                      required technicalLogs,
                      required installContext,
                    }) async {
                      exported = true;
                      expect(success, true);
                      return const InstallLogExportResult(success: true);
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(exported, true);
      expect(find.text(state.t('install_badge_success')), findsOneWidget);
      final request = jsonDecode(process.sent);
      expect(request['operation'], 'install-free-space');
      expect(request['confirmedPlan'], plan.intentJson);
      expect(request['confirmDestructive'], true);
      expect(request.containsKey('sourceSnapshot'), false);
      expect(request.containsKey('allocationGuids'), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
