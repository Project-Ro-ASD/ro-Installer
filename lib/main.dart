import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'l10n/installer_translation_catalog.dart';
import 'models/install_profile.dart';
import 'services/command_runner.dart';
import 'services/install_log_export_service.dart';
import 'services/install_service.dart';
import 'theme/app_theme.dart';
import 'state/installer_state.dart';
import 'widgets/installer_layout.dart';
import 'screens/welcome_screen.dart';
import 'screens/theme_screen.dart';
import 'screens/location_screen.dart';
import 'screens/network_screen.dart';
import 'screens/account_screen.dart';
import 'screens/type_screen.dart';
import 'screens/disk_selection_screen.dart';
import 'screens/manual_partition_screen.dart';
import 'screens/kernel_screen.dart';
import 'screens/installing_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final commandRunner = CommandRunner.instance;
  final translationCatalog = await InstallerTranslationCatalog.loadBundled();
  final autoProfilePath =
      Platform.environment['RO_INSTALLER_AUTO_PROFILE']?.trim() ?? '';
  final isAutoInstallMode = autoProfilePath.isNotEmpty;
  // ═══════════════════════════════════════════════════
  // ROOT YETKİ KONTROLÜ
  // Disk yazma, mount, mkfs, sgdisk gibi tüm komutlar
  // root yetkisi gerektirir. Root değilse pkexec ile
  // kendini yeniden başlatır.
  // ═══════════════════════════════════════════════════

  // Mevcut kullanıcı root mu kontrol et
  final idResult = await commandRunner.run('id', ['-u']);
  final uid =
      int.tryParse(Platform.environment['UID'] ?? idResult.stdout.trim()) ?? -1;

  if (uid != 0) {
    if (isAutoInstallMode) {
      debugPrint(
        '[ro-Installer] Otomatik profil modu root yetkisiyle doğrudan çalıştırılmalıdır.',
      );
      debugPrint(
        '[ro-Installer] Önerilen kullanım: sudo env RO_INSTALLER_AUTO_PROFILE=... /path/to/ro_installer',
      );
      exit(1);
    }

    // Root değiliz — pkexec ile yeniden başlat
    debugPrint(
      '[ro-Installer] Root yetkisi gerekiyor (UID: $uid). pkexec ile yükseltiliyor...',
    );

    // Kendi çalıştırılabilir dosyamızın yolunu bul
    final execPath = Platform.resolvedExecutable;

    final result = await commandRunner.run('pkexec', [
      execPath,
      ...Platform.executableArguments,
    ]);
    if (!result.started) {
      debugPrint('[ro-Installer] pkexec başlatılamadı: ${result.stderr}');
      debugPrint(
        '[ro-Installer] Lütfen uygulamayı "sudo ro-installer" ile başlatın.',
      );
      exit(1);
    }

    // pkexec bittiğinde (kullanıcı iptal etti veya uygulama kapandı)
    exit(result.exitCode);
  }

  debugPrint(
    '[ro-Installer] Root yetkisi doğrulandı (UID: $uid). Başlatılıyor...',
  );

  if (isAutoInstallMode) {
    final exitCode = await _runAutoInstall(
      autoProfilePath,
      commandRunner,
      translationCatalog,
    );
    exit(exitCode);
  }

  runApp(
    ChangeNotifierProvider(
      create: (_) => InstallerState(
        translations: translationCatalog,
        platformLocaleName: Platform.localeName,
      ),
      child: const RoInstallerApp(),
    ),
  );
}

class RoInstallerApp extends StatelessWidget {
  const RoInstallerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<InstallerState>(
      builder: (context, state, child) {
        return MaterialApp(
          title: 'Ro-Installer',
          locale: _flutterLocaleFromInstaller(state.selectedLocale),
          supportedLocales: state.availableLocales
              .map(_flutterLocaleFromInstaller)
              .toList(growable: false),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: state.themeMode == 'dark'
              ? ThemeMode.dark
              : ThemeMode.light,
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            return Directionality(
              textDirection: state.selectedLocale.isRightToLeft
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const MainScreenWrapper(),
        );
      },
    );
  }
}

Locale _flutterLocaleFromInstaller(InstallerLocale locale) {
  final localeName = locale.locale.split('.').first.replaceAll('-', '_');
  final parts = localeName.split('_');
  if (parts.length >= 2 && parts.first.isNotEmpty && parts[1].isNotEmpty) {
    return Locale(parts.first, parts[1]);
  }
  return Locale(locale.code);
}

class MainScreenWrapper extends StatelessWidget {
  const MainScreenWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);

    // Dinamik olarak adımlara göre ekran getirme
    String stepName = state.steps[state.currentStep];
    Widget currentScreen;

    switch (stepName) {
      case "Welcome":
        currentScreen = const WelcomeScreen();
        break;
      case "Theme":
        currentScreen = const ThemeScreen();
        break;
      case "Location":
        currentScreen = const LocationScreen();
        break;
      case "Network":
        currentScreen = const NetworkScreen();
        break;
      case "Account":
        currentScreen = const AccountScreen();
        break;
      case "Type":
        currentScreen = const TypeScreen();
        break;
      case "Disk":
        currentScreen = const DiskSelectionScreen();
        break;
      case "Partitions":
        currentScreen = const ManualPartitionScreen();
        break;
      case "Kernel":
        currentScreen = const KernelScreen();
        break;
      case "Install":
        currentScreen = const InstallingScreen();
        break;
      default:
        currentScreen = Center(child: Text(state.t('page_not_found')));
    }

    return InstallerLayout(child: currentScreen);
  }
}

Future<int> _runAutoInstall(
  String profilePath,
  CommandRunner commandRunner,
  InstallerTranslationCatalog translationCatalog,
) async {
  final startedAt = DateTime.now();
  final statusHistory = <String>[];
  final technicalLogs = <String>[];

  void pushStatus(String message) {
    final line = '[DURUM] $message';
    stdout.writeln(line);
    statusHistory.add(message);
  }

  void pushLog(String message) {
    final sanitized = _sanitizeAutoInstallLog(message);
    stdout.writeln('[TEKNIK] $sanitized');
    technicalLogs.add(sanitized);
  }

  try {
    final profile = InstallProfile.fromJsonFile(profilePath);
    final selectedLanguage =
        translationCatalog.localeFor(profile.selectedLanguage) != null
        ? profile.selectedLanguage
        : translationCatalog.fallbackLocale;
    String t(String key, [Map<String, String> placeholders = const {}]) {
      var value = translationCatalog.translate(selectedLanguage, key);
      for (final entry in placeholders.entries) {
        value = value.replaceAll('{${entry.key}}', entry.value);
      }
      return value;
    }

    final validationErrors = profile.validate();
    if (validationErrors.isNotEmpty) {
      pushStatus(t('auto_profile_validation_failed'));
      for (final error in validationErrors) {
        pushLog(error);
      }
      return 2;
    }

    final stateMap = profile.toStateMap();
    stateMap['selectedLanguage'] = selectedLanguage;
    stateMap['selectedLocale'] = profile.selectedLocale.isNotEmpty
        ? profile.selectedLocale
        : (translationCatalog.localeFor(selectedLanguage)?.locale ?? '');
    stateMap['vmTestMode'] = _envFlag('RO_INSTALLER_VM_TEST_MODE');

    final extraKernelArgs =
        Platform.environment['RO_INSTALLER_EXTRA_KERNEL_ARGS']?.trim() ?? '';
    if (extraKernelArgs.isNotEmpty) {
      stateMap['extraKernelArgs'] = extraKernelArgs;
    }

    pushStatus(t('auto_profile_loaded', {'path': profilePath}));
    pushStatus(
      t('auto_profile_summary', {
        'disk': profile.selectedDisk,
        'method': profile.partitionMethod,
        'filesystem': profile.fileSystem,
      }),
    );

    final success = await InstallService.instance.runInstall(
      stateMap,
      (progress, status) {
        final percent = progress < 0 ? '--' : '${(progress * 100).round()}%';
        pushStatus(
          t('auto_progress_line', {'percent': percent, 'status': status}),
        );
      },
      pushLog,
      translate: t,
    );

    final finishedAt = DateTime.now();
    final exportResult = await InstallLogExportService.instance.exportSession(
      startedAt: startedAt,
      finishedAt: finishedAt,
      success: success,
      finalStatus: success
          ? t('auto_install_success')
          : t('auto_install_failure'),
      statusHistory: statusHistory,
      technicalLogs: technicalLogs,
      installContext: {
        ...profile.toJson(),
        'autoInstallMode': true,
        'vmTestMode': stateMap['vmTestMode'],
      },
    );

    if (exportResult.success) {
      pushLog('Oturum kaydi yazildi: ${exportResult.logPath}');
      pushLog('Oturum ozeti yazildi: ${exportResult.summaryPath}');
    } else {
      pushLog('Oturum disa aktarimi basarisiz: ${exportResult.error}');
    }

    if (!success) {
      pushStatus(t('auto_install_failed_done'));
      return 1;
    }

    if (_envFlag('RO_INSTALLER_AUTO_REBOOT')) {
      pushStatus(t('auto_rebooting'));
      final rebootResult = await commandRunner.run('systemctl', ['reboot']);
      if (!rebootResult.started) {
        pushLog('systemctl reboot baslatilamadi: ${rebootResult.stderr}');
        return 1;
      }
    } else {
      pushStatus(t('auto_reboot_disabled'));
    }

    return 0;
  } catch (e, stack) {
    pushLog('FATAL AUTO INSTALL: $e');
    pushLog(stack.toString());
    return 2;
  }
}

bool _envFlag(String key) {
  final raw = Platform.environment[key]?.trim().toLowerCase() ?? '';
  return raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on';
}

String _sanitizeAutoInstallLog(String raw) {
  var line = raw;

  line = line.replaceAllMapped(
    RegExp(r'(password\s+)(\S+)', caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  line = line.replaceAllMapped(
    RegExp(
      r"(printf '%s\\n' )'([^':\s]+):([^'\s]+)'(\s+\|\s+chpasswd)",
      caseSensitive: false,
    ),
    (m) => "${m.group(1)}'***:***'${m.group(4)}",
  );

  line = line.replaceAllMapped(
    RegExp('(root:)([^\\s\\\'"]+)', caseSensitive: false),
    (m) => '${m.group(1)}***',
  );

  return line;
}
