import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/screens/installing_screen.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/models/approved_full_disk_plan.dart';
import 'package:ro_installer/services/install_log_export_service.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';
import 'package:ro_installer/widgets/installer_layout.dart';
import 'package:ro_installer/widgets/nebula_ui.dart';
import '../services/helper_client_test.dart' as f;
import '../services/helper_v2_test.dart' as v2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InstallerTranslationCatalog catalog;
  setUpAll(() async {
    catalog = await InstallerTranslationCatalog.loadBundled();
  });
  final locales =
      (jsonDecode(File('assets/i18n/locales.json').readAsStringSync()) as List)
          .where((v) => v['enabled'] == true)
          .map((v) => v['code'] as String);
  for (final language in locales) {
    for (final size in [const Size(1600, 1000), const Size(1000, 800)]) {
      for (final success in [true, false]) {
        testWidgets('$language $size terminal success=$success', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final state = InstallerState(translations: catalog)
            ..selectedDisk = '/dev/vda'
            ..selectedLanguage = language;
          state.nextStep();
          state.nextStep();
          state.confirmPlan(
            ApprovedFullDiskPlan(f.identity),
            state.diskSelectionRevision,
          );
          final process = f.FakeHelperProcess(
            f.messages([v2.terminal(ok: success)]),
            status: success ? 0 : 8,
          );
          bool? exported;
          await tester.pumpWidget(
            ChangeNotifierProvider.value(
              value: state,
              child: MaterialApp(
                theme: AppTheme.darkTheme,
                builder: (context, child) => Directionality(
                  textDirection: catalog.localeFor(language)!.isRightToLeft
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: child!,
                ),
                home: InstallerLayout(
                  child: InstallingScreen(
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
          await tester.pump(const Duration(seconds: 1));
          for (var i = 0; i < 20 && exported == null; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pump(const Duration(seconds: 3));
          expect(exported, success);
          expect(
            find.text(
              state.t(
                success ? 'install_badge_success' : 'install_badge_failure',
              ),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          // Completion actions remain reachable in the real constrained shell.
          final action = find.byWidgetPredicate(
            (w) => success
                ? w is NebulaPrimaryButton &&
                      w.label == state.t('install_ready_reboot_button')
                : w is NebulaSecondaryButton &&
                      w.label == state.t('install_inspect_logs'),
          );
          final outcomeAction = action.first;
          await tester.ensureVisible(outcomeAction);
          await tester.pump(const Duration(seconds: 1));
          expect(outcomeAction.hitTestable(), findsOneWidget);
          if (success) {
            expect(
              tester.widget<NebulaPrimaryButton>(outcomeAction).onPressed,
              isNotNull,
            );
          } else {
            await tester.tap(outcomeAction);
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            expect(find.byType(Dialog), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          state.dispose();
        });
      }
    }
  }
}
