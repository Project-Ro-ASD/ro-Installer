import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/screens/installing_screen.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/install_log_export_service.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';
import '../services/helper_client_test.dart' as fixture;

class ThrowingClient extends HelperClient {
  @override
  Future<void> install(
    identity,
    void Function(double, String) onProgress,
  ) async {
    onProgress(1, 'install_stage_cleanup');
    throw StateError('private-exception-must-not-render');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InstallerTranslationCatalog catalog;
  setUpAll(() async {
    catalog = await InstallerTranslationCatalog.loadBundled();
  });
  for (final mode in [
    'backend-fail',
    'eof',
    'nonzero',
    'malformed',
    'exception',
    'success',
    'success-export-error',
    'success-export-throw',
    'fail-export-throw',
    'pending-export',
  ]) {
    testWidgets('progress 100 terminal contract $mode without pkexec', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = InstallerState(translations: catalog)
        ..selectedDisk = '/dev/vda'
        ..confirmedDevice = fixture.identity;
      final success = mode.startsWith('success') || mode == 'pending-export';
      final messages = <Map<String, dynamic>>[
        {
          'protocolVersion': 1,
          'type': 'progress',
          'stage': 9,
          'progress': 1.0,
          'messageKey': 'install_stage_cleanup',
        },
        if (mode != 'eof')
          if (mode == 'malformed')
            {'arbitrary': 'invalid'}
          else if (success || mode == 'nonzero')
            fixture.result('install-full-disk', {'installed': true})
          else
            {
              'protocolVersion': 1,
              'type': 'result',
              'operation': 'install-full-disk',
              'ok': false,
              'error': {
                'code': 'INSTALL_FAILED',
                'message': 'Installation failed',
              },
            },
      ];
      final process = fixture.FakeHelperProcess(
        fixture.messages(messages),
        status: mode == 'nonzero' ? 8 : 0,
      );
      final client = mode == 'exception'
          ? ThrowingClient()
          : HelperClient(start: (_, _) async => process);
      final exported = <bool>[];
      final pending = Completer<InstallLogExportResult>();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: InstallingScreen(
                helperClient: client,
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
                      exported.add(success);
                      expect(
                        jsonEncode(technicalLogs),
                        isNot(contains('private-exception')),
                      );
                      if (mode.endsWith('throw')) {
                        throw StateError('export fixture');
                      }
                      if (mode == 'pending-export') return pending.future;
                      return InstallLogExportResult(
                        success: mode != 'success-export-error',
                      );
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      for (var tick = 0; tick < 30 && exported.isEmpty; tick++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(exported, [success]);
      expect(
        find.text(
          state.t(success ? 'install_badge_success' : 'install_badge_failure'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          state.t(success ? 'install_badge_failure' : 'install_badge_success'),
        ),
        findsNothing,
      );
      if (mode == 'pending-export') {
        pending.complete(const InstallLogExportResult(success: false));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
