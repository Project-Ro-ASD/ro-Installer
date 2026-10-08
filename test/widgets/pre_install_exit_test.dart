import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/state/installer_state.dart';
import 'package:ro_installer/theme/app_theme.dart';
import 'package:ro_installer/widgets/installer_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InstallerTranslationCatalog catalog;
  setUpAll(() async {
    catalog = await InstallerTranslationCatalog.loadBundled();
  });
  for (final size in [const Size(800, 600), const Size(1600, 1000)]) {
    testWidgets('localized exit closes only pre-install GUI at $size', (
      tester,
    ) async {
      final state = InstallerState(translations: catalog);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const InstallerLayout(child: SizedBox()),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Çıkış'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pre-install-exit')));
      await tester.pump();
      expect(
        calls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1),
      );
      state.updateLanguage('en');
      state.nextStep();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Exit'), findsOneWidget);
      await tester.tap(find.text('Exit'));
      await tester.pump();
      expect(
        calls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(2),
      );
      // Install step hides exit even before the delayed beginInstallation call.
      state.nextStep();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('pre-install-exit')), findsNothing);
      state.beginInstallation();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Exit'), findsNothing);
      expect(
        calls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
