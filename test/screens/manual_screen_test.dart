import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/manual_installation_plan.dart';
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
  Future<ManualInstallationPlan>? validation;
  bool rejectValidation = false;
  @override
  Future<ManualInstallationPlan> validateManualPlan(
    ManualInstallationPlan plan,
  ) async {
    calls.add('validate');
    if (rejectValidation) throw const HelperException('DEVICE_CHANGED');
    return validation ?? plan;
  }

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
  Future<InstallerState> show(
    WidgetTester tester,
    Probe probe, {
    Size viewport = const Size(1600, 1100),
  }) async {
    tester.view.physicalSize = viewport;
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
    await tester.ensureVisible(
      find.text(state.t('manual_method').replaceAll('\n', ' ')),
    );
    await tester.tap(find.text(state.t('manual_method').replaceAll('\n', ' ')));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> scan(WidgetTester tester, InstallerState state) async {
    await tester.ensureVisible(find.text(state.t('disk_free_space_probe')));
    await tester.tap(find.text(state.t('disk_free_space_probe')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'manual proposal validates before confirmation and sends only typed intent',
    (tester) async {
      final probe = Probe();
      final state = await show(tester, probe);
      expect(state.partitionMethod, 'manual');
      expect(state.selectedManualPlan, isNull);
      await scan(tester, state);
      final plan = state.selectedManualPlan!;
      expect(plan.root.formatOnInstall, true);
      expect(
        plan.esp.formatOnInstall,
        true,
      ); // This fixture has no existing ESP.
      expect(state.confirmedManualPlan, isNull);
      await tester.tap(find.text(state.t('next')));
      await tester.pumpAndSettle();
      expect(probe.calls.last, 'validate');
      expect(find.textContaining(state.t('manual_root_warning')), findsWidgets);
      await tester.tap(find.text(state.t('cancel')));
      await tester.pumpAndSettle();
      expect(state.currentStep, 1);
      expect(state.confirmedManualPlan, isNull);
      await tester.tap(find.text(state.t('next')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(state.t('manual_install')));
      await tester.tap(find.text(state.t('manual_install')));
      await tester.pumpAndSettle();
      expect(state.currentStep, 2);
      expect(identical(state.confirmedManualPlan, plan), true);
    },
  );
  testWidgets('invalid or overlapping new ranges revoke the proposal', (
    tester,
  ) async {
    final state = await show(tester, Probe());
    await scan(tester, state);
    final input = find.byKey(const ValueKey('manual-root-size'));
    await tester.ensureVisible(input);
    await tester.enterText(input, '1');
    await tester.pumpAndSettle();
    expect(state.selectedManualPlan, isNull);
    expect(state.confirmedManualPlan, isNull);
    expect(find.text(state.t('manual_invalid')), findsOneWidget);
    await tester.enterText(input, '40960');
    await tester.pumpAndSettle();
    expect(state.selectedManualPlan, isNotNull);
  });
  testWidgets('pending inventory cannot survive a mode revision', (
    tester,
  ) async {
    final probe = Probe(), pending = Completer<GptDiskSnapshot>();
    probe.pending = pending.future;
    final state = await show(tester, probe);
    await tester.ensureVisible(find.text(state.t('disk_free_space_probe')));
    await tester.tap(find.text(state.t('disk_free_space_probe')));
    await tester.pump();
    state.updatePartitionMethod('full');
    state.updatePartitionMethod('manual');
    pending.complete(probe.value);
    await tester.pumpAndSettle();
    expect(state.selectedManualPlan, isNull);
    expect(find.byKey(const ValueKey('manual-root')), findsNothing);
  });
  testWidgets('helper refusal never opens an approval dialog', (tester) async {
    final probe = Probe()..rejectValidation = true;
    final state = await show(tester, probe);
    await scan(tester, state);
    await tester.tap(find.text(state.t('next')));
    await tester.pumpAndSettle();
    expect(find.text(state.t('manual_confirm')), findsNothing);
    expect(state.currentStep, 1);
    expect(state.confirmedManualPlan, isNull);
  });
  testWidgets('away and back invalidates a pending manual validation', (
    tester,
  ) async {
    final probe = Probe(), pending = Completer<ManualInstallationPlan>();
    final state = await show(tester, probe);
    await scan(tester, state);
    final old = state.selectedManualPlan!;
    probe.validation = pending.future;
    await tester.tap(find.text(state.t('next')));
    await tester.pump();
    state.updatePartitionMethod('full');
    state.updatePartitionMethod('manual');
    pending.complete(old);
    await tester.pumpAndSettle();
    expect(find.text(state.t('manual_confirm')), findsNothing);
    expect(state.confirmedManualPlan, isNull);
  });
  GptDiskSnapshot existingSnapshot() => GptDiskSnapshot.fromJson(
    (jsonDecode(
          File('test/fixtures/manual_ownership_v1.json').readAsStringSync(),
        )
        as List)[0]['snapshot'],
  );
  testWidgets(
    'existing EFI defaults to preservation and formatting is explicit',
    (tester) async {
      final probe = Probe()..value = existingSnapshot();
      final state = await show(tester, probe);
      await scan(tester, state);
      expect(state.selectedManualPlan!.esp.formatOnInstall, false);
      expect(state.selectedManualPlan!.root.formatOnInstall, true);
      final revision = state.diskSelectionRevision;
      final checkbox = find.byType(CheckboxListTile);
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(state.selectedManualPlan!.esp.formatOnInstall, true);
      expect(state.diskSelectionRevision, greaterThan(revision));
      expect(state.confirmedManualPlan, isNull);
    },
  );
  testWidgets('a changed selection cannot accept an already open dialog', (
    tester,
  ) async {
    final state = await show(tester, Probe());
    await scan(tester, state);
    await tester.tap(find.text(state.t('next')));
    await tester.pumpAndSettle();
    state.updatePartitionMethod('full');
    state.updatePartitionMethod('manual');
    await tester.ensureVisible(find.text(state.t('manual_install')));
    await tester.tap(find.text(state.t('manual_install')));
    await tester.pumpAndSettle();
    expect(state.currentStep, 1);
    expect(state.confirmedManualPlan, isNull);
  });
  for (final locale in [
    'ar',
    'de',
    'en',
    'es',
    'fa',
    'fr',
    'it',
    'ja',
    'pt_BR',
    'ru',
    'tr',
    'zh_CN',
  ]) {
    testWidgets('manual editor and confirmation fit $locale at 1600x1000', (
      tester,
    ) async {
      final state = await show(tester, Probe());
      tester.view.physicalSize = const Size(1600, 1000);
      state.updateLanguage(locale);
      await tester.pumpAndSettle();
      await scan(tester, state);
      await tester.tap(find.text(state.t('next')));
      await tester.pumpAndSettle();
      expect(find.text(state.t('manual_confirm')), findsOneWidget);
      await tester.ensureVisible(find.text(state.t('cancel')));
      await tester.tap(find.text(state.t('cancel')));
      await tester.pumpAndSettle();
    });
  }
  for (final installed in [true, false]) {
    testWidgets(
      'install screen requires manual terminal installed=$installed',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = InstallerState(translations: catalog)
          ..selectedLanguage = 'en'
          ..selectedDisk = '/dev/vda'
          ..partitionMethod = 'manual';
        final plan = ManualInstallationPlan.build(
          snapshot: existingSnapshot(),
          esp: const ManualPartitionChoice.existing(
            number: 1,
            formatOnInstall: false,
          ),
          root: const ManualPartitionChoice.existing(
            number: 2,
            formatOnInstall: true,
          ),
        );
        state.selectManualPlan(plan);
        state.confirmManualPlan(plan, state.diskSelectionRevision);
        final process = f.FakeHelperProcess(
          f.messages([
            {
              'protocolVersion': 2,
              'type': 'result',
              'operation': 'install-manual',
              'ok': true,
              'installed': installed,
            },
          ]),
        );
        bool? exported;
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
                        exported = success;
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
        expect(exported, installed);
        final request = jsonDecode(process.sent);
        expect(request['operation'], 'install-manual');
        expect(request['confirmedPlan'], plan.intentJson);
        expect(request.containsKey('manualPartitions'), false);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }
  testWidgets('compact manual controls remain usable at 1000x800', (
    tester,
  ) async {
    final state = await show(tester, Probe(), viewport: const Size(1000, 800));
    await scan(tester, state);
    expect(state.selectedManualPlan, isNotNull);
    await tester.tap(find.text(state.t('next')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(state.t('manual_install')));
    await tester.tap(find.text(state.t('manual_install')));
    await tester.pumpAndSettle();
    expect(state.confirmedManualPlan, isNotNull);
  });
  test(
    'manual approval is immutable across language changes and blocked while installing',
    () {
      final state = InstallerState(translations: catalog)
        ..selectedDisk = '/dev/vda'
        ..partitionMethod = 'manual';
      final plan = ManualInstallationPlan.build(
        snapshot: existingSnapshot(),
        esp: const ManualPartitionChoice.existing(
          number: 1,
          formatOnInstall: false,
        ),
        root: const ManualPartitionChoice.existing(
          number: 2,
          formatOnInstall: true,
        ),
      );
      expect(state.selectManualPlan(plan), true);
      final revision = state.diskSelectionRevision;
      state.updateLanguage('tr');
      expect(state.confirmManualPlan(plan, revision), true);
      state.beginInstallation();
      expect(state.selectManualPlan(plan), false);
      state.updatePartitionMethod('full');
      expect(state.confirmedManualPlan, same(plan));
      expect(state.partitionMethod, 'manual');
    },
  );
}
