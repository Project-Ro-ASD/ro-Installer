import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  final commandRunner = CommandRunner.instance;
  final autoProfilePath = Platform.environment['RO_INSTALLER_AUTO_PROFILE']?.trim() ?? '';
  final isAutoInstallMode = autoProfilePath.isNotEmpty;
  // ═══════════════════════════════════════════════════
  // ROOT YETKİ KONTROLÜ
  // Disk yazma, mount, mkfs, sgdisk gibi tüm komutlar
  // root yetkisi gerektirir. Root değilse pkexec ile
  // kendini yeniden başlatır.
  // ═══════════════════════════════════════════════════
  
  // Mevcut kullanıcı root mu kontrol et
  final idResult = await commandRunner.run('id', ['-u']);
  final uid = int.tryParse(Platform.environment['UID'] ?? 
      idResult.stdout.trim()) ?? -1;
  
  if (uid != 0) {
    if (isAutoInstallMode) {
      debugPrint('[ro-Installer] Otomatik profil modu root yetkisiyle doğrudan çalıştırılmalıdır.');
      debugPrint('[ro-Installer] Önerilen kullanım: sudo env RO_INSTALLER_AUTO_PROFILE=... /path/to/ro_installer');
      exit(1);
    }

    // Root değiliz — pkexec ile yeniden başlat
    debugPrint('[ro-Installer] Root yetkisi gerekiyor (UID: $uid). pkexec ile yükseltiliyor...');
    
    // Kendi çalıştırılabilir dosyamızın yolunu bul
    final execPath = Platform.resolvedExecutable;
    
    final result = await commandRunner.run('pkexec', [execPath, ...Platform.executableArguments]);
    if (!result.started) {
      debugPrint('[ro-Installer] pkexec başlatılamadı: ${result.stderr}');
      debugPrint('[ro-Installer] Lütfen uygulamayı "sudo ro-installer" ile başlatın.');
      exit(1);
    }

    // pkexec bittiğinde (kullanıcı iptal etti veya uygulama kapandı)
    exit(result.exitCode);
  }

  debugPrint('[ro-Installer] Root yetkisi doğrulandı (UID: $uid). Başlatılıyor...');

  if (isAutoInstallMode) {
    final exitCode = await _runAutoInstall(autoProfilePath, commandRunner);
    exit(exitCode);
  }

  runApp(
    ChangeNotifierProvider(
      create: (_) => InstallerState(),
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
          title: 'Ro-ASD OS Installer',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: state.themeMode == 'dark' ? ThemeMode.dark : ThemeMode.light,
          debugShowCheckedModeBanner: false,
          home: const MainScreenWrapper(),
        );
      },
    );
  }
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
        currentScreen = const Center(child: Text("Sayfa Bulunamadı"));
    }

    return InstallerLayout(child: currentScreen);
  }
}

Future<int> _runAutoInstall(String profilePath, CommandRunner commandRunner) async {
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
    final validationErrors = profile.validate();
    if (validationErrors.isNotEmpty) {
      pushStatus('Profil dogrulamasi basarisiz.');
      for (final error in validationErrors) {
        pushLog(error);
      }
      return 2;
    }

    final stateMap = profile.toStateMap();
    stateMap['vmTestMode'] = _envFlag('RO_INSTALLER_VM_TEST_MODE');

    final extraKernelArgs =
        Platform.environment['RO_INSTALLER_EXTRA_KERNEL_ARGS']?.trim() ?? '';
    if (extraKernelArgs.isNotEmpty) {
      stateMap['extraKernelArgs'] = extraKernelArgs;
    }

    pushStatus('Otomatik kurulum profili yuklendi: $profilePath');
    pushStatus(
      'Disk=${profile.selectedDisk} Yontem=${profile.partitionMethod} DosyaSistemi=${profile.fileSystem}',
    );

    final success = await InstallService.instance.runInstall(
      stateMap,
      (progress, status) {
        pushStatus('${(progress * 100).round()}% - $status');
      },
      pushLog,
    );

    final finishedAt = DateTime.now();
    final exportResult = await InstallLogExportService.instance.exportSession(
      startedAt: startedAt,
      finishedAt: finishedAt,
      success: success,
      finalStatus: success ? 'Kurulum basarili.' : 'Kurulum basarisiz.',
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
      pushStatus('Otomatik kurulum basarisiz tamamlandi.');
      return 1;
    }

    if (_envFlag('RO_INSTALLER_AUTO_REBOOT')) {
      pushStatus('Kurulum basarili. Sistem yeniden baslatiliyor...');
      final rebootResult = await commandRunner.run('systemctl', ['reboot']);
      if (!rebootResult.started) {
        pushLog('systemctl reboot baslatilamadi: ${rebootResult.stderr}');
        return 1;
      }
    } else {
      pushStatus('Kurulum basarili. Otomatik yeniden baslatma kapali.');
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
