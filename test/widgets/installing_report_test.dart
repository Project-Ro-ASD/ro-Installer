import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/screens/installing_screen.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/copy_progress.dart';
import 'package:ro_installer/models/approved_full_disk_plan.dart';
import 'package:ro_installer/services/install_log_export_service.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';
import 'package:ro_installer/widgets/nebula_ui.dart';
import '../services/helper_client_test.dart' as f;
import '../services/helper_v2_test.dart' as v2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InstallerTranslationCatalog catalog;
  setUpAll(() async {
    catalog = await InstallerTranslationCatalog.loadBundled();
  });
  testWidgets(
    'production v2 refuses identity-only confirmation before helper starts',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = InstallerState(translations: catalog)
        ..selectedDisk = '/dev/vda'
        ..confirmedDevice = f.identity;
      var starts = 0;
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
                  start: (_, _) async {
                    starts++;
                    return f.FakeHelperProcess(f.messages([v2.terminal()]));
                  },
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
                      expect(success, false);
                      return const InstallLogExportResult(success: false);
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(starts, 0);
      expect(exported, true);
      expect(find.text(state.t('install_badge_failure')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'live copy measurement expires, clears by stage and never marks success',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = InstallerState(translations: catalog)
        ..selectedDisk = '/dev/vda'
        ..confirmedDevice = f.identity
        ..selectedLanguage = 'en';
      state.confirmPlan(
        ApprovedFullDiskPlan(f.identity),
        state.diskSelectionRevision,
      );
      final stream = StreamController<List<int>>();
      final process = f.FakeHelperProcess(stream.stream);
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
                    }) async => const InstallLogExportResult(
                      success: false,
                      error: 'fixture',
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      void send(Map<String, dynamic> value) =>
          stream.add(utf8.encode('${jsonEncode(value)}\n'));
      send({
        'protocolVersion': 2,
        'type': 'progress',
        'stage': 5,
        'progress': 0.42,
        'messageKey': 'install_stage_file_copy',
      });
      const value = CopyProgress(
        phase: 'main',
        bytesProcessed: 4096,
        bytesPerSecond: 1024,
        etaSeconds: 12,
      );
      send(value.toJson(version: 2));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('4.0 KiB'), findsOneWidget);
      expect(find.textContaining('~0:12'), findsOneWidget);
      expect(find.text(state.t('install_badge_active')), findsOneWidget);
      expect(jsonDecode(process.sent)['includeCopyProgress'], true);
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('4.0 KiB'), findsNothing);
      send(value.toJson(version: 2));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('4.0 KiB'), findsOneWidget);
      send({
        'protocolVersion': 2,
        'type': 'progress',
        'stage': 6,
        'progress': 0.6,
        'messageKey': 'install_stage_target_finalization',
      });
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('4.0 KiB'), findsNothing);
      send(v2.terminal());
      await stream.close();
      for (
        var i = 0;
        i < 20 &&
            find.text(state.t('install_badge_success')).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.text(state.t('install_badge_success')),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((v) => v.data)
            .join(' | '),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final mode in [
    'complete',
    'failed',
    'unavailable',
    'truncated',
    'invalid',
    'missing',
    'install-failed',
    'transport-eof',
    'pending-export',
  ]) {
    testWidgets('GUI safe report and independent terminal $mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = InstallerState(translations: catalog)
        ..selectedDisk = '/dev/vda'
        ..selectedLanguage = mode == 'complete' ? 'en' : 'tr'
        ..confirmedDevice = f.identity;
      state.confirmPlan(
        ApprovedFullDiskPlan(f.identity),
        state.diskSelectionRevision,
      );
      final report = v2.fixture();
      if (const ['failed', 'unavailable', 'truncated'].contains(mode)) {
        report['logStatus'] = mode;
        report['logError'] = mode == 'truncated'
            ? 'LOG_LIMIT'
            : 'LOG_WRITE_FAILED';
      }
      final successful = !const [
        'install-failed',
        'transport-eof',
      ].contains(mode);
      if (mode == 'install-failed') {
        report['terminalStatus'] = 'failed';
        report['primaryError'] = 'STAGE_5_FAILED';
      }
      final process = f.FakeHelperProcess(
        f.messages([
          {
            'protocolVersion': 2,
            'type': 'progress',
            'stage': 9,
            'progress': 1.0,
            'messageKey': 'install_stage_cleanup',
          },
          if (mode != 'missing')
            v2.report(
              mode == 'invalid' ? {'stdout': 'SECRET_SENTINEL'} : report,
            ),
          if (mode != 'transport-eof') v2.terminal(ok: successful),
        ]),
        status: successful ? 0 : 8,
      );
      final pending = Completer<InstallLogExportResult>();
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
                  start: (_, args) async {
                    expect(args.last, '--protocol=2');
                    return process;
                  },
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
                      expect(success, successful);
                      expect(
                        technicalLogs.join('\n'),
                        isNot(contains('SECRET_SENTINEL')),
                      );
                      if (const [
                        'invalid',
                        'missing',
                        'transport-eof',
                      ].contains(mode)) {
                        expect(
                          installContext.containsKey('sessionReport'),
                          isFalse,
                        );
                        expect(
                          installContext['reportStatus'],
                          mode == 'invalid' ? 'invalid' : 'unavailable',
                        );
                      } else {
                        expect(
                          installContext['sessionReport']['schemaVersion'],
                          1,
                        );
                        expect(
                          installContext['sessionReport']['sessionId'],
                          '1' * 32,
                        );
                        if (const [
                          'failed',
                          'unavailable',
                          'truncated',
                        ].contains(mode)) {
                          expect(
                            technicalLogs,
                            contains(
                              state.t('install_backend_record_incomplete'),
                            ),
                          );
                        }
                      }
                      if (mode == 'pending-export') return pending.future;
                      return const InstallLogExportResult(
                        success: false,
                        error: 'EXPORT_FAILED',
                      );
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      for (var i = 0; i < 30 && !exported; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(seconds: 1));
      expect(exported, isTrue);
      expect(jsonDecode(process.sent)['uiLanguage'], state.selectedLanguage);
      expect(
        find.text(
          state.t(
            successful ? 'install_badge_success' : 'install_badge_failure',
          ),
        ),
        findsOneWidget,
      );
      if (mode == 'pending-export') {
        final button = find.byWidgetPredicate(
          (w) =>
              w is NebulaPrimaryButton &&
              w.label == state.t('install_ready_reboot_button'),
        );
        expect(tester.widget<NebulaPrimaryButton>(button).onPressed, isNull);
        pending.complete(
          const InstallLogExportResult(success: false, error: 'EXPORT_FAILED'),
        );
        await tester.pump();
        expect(tester.widget<NebulaPrimaryButton>(button).onPressed, isNotNull);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
