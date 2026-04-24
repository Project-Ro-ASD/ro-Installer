import 'dart:async';
import 'package:flutter/material.dart';
import '../data/keyboard_presets.dart';
import '../data/location_presets.dart';
import '../services/network_service.dart';
import '../services/disk_service.dart';
import '../l10n/installer_translation_catalog.dart';
import '../utils/account_validation.dart';

class InstallerState extends ChangeNotifier {
  int _currentStep = 0;
  int get currentStep => _currentStep;

  InstallerState({required this.translations, this.platformLocaleName = ''}) {
    _initNetworkChecker();
  }

  final InstallerTranslationCatalog translations;
  final String platformLocaleName;

  Timer? _networkTimer;

  void _initNetworkChecker() {
    // İlk çalıştırma
    _checkNetworkPeriodically();
    // Ardından her 5 saniyede bir kontrol et
    _networkTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _checkNetworkPeriodically();
    });
  }

  @override
  void dispose() {
    _networkTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkNetworkPeriodically() async {
    final wasEthernetConnected = isEthernetConnected;
    isEthernetConnected = await NetworkService.instance.checkEthernet();

    if (wasEthernetConnected != isEthernetConnected) {
      // Otomatik bağlantı ayarı
      if (isEthernetConnected) networkStatus = 'connected';
      notifyListeners();
    }
  }

  Future<void> scanWifiNetworks() async {
    isScanningWifi = true;
    notifyListeners();

    wifiNetworks = await NetworkService.instance.scanWifi();

    // Halihazırda bağlı Wi-Fi varsa statüyü connected yap
    final isWifiConnected = wifiNetworks.any((net) => net['inUse'] == true);
    if (isWifiConnected && networkStatus == 'offline') {
      networkStatus = 'connected';
    }

    isScanningWifi = false;
    notifyListeners();
  }

  Future<bool> connectToWifi(String ssid, String password) async {
    final success = await NetworkService.instance.connectWifi(
      ssid,
      password,
      isMock: isMockEnabled,
    );
    if (success) {
      await scanWifiNetworks(); // Listeyi yenile
      networkStatus = 'connected';
      notifyListeners();
    }
    return success;
  }

  // Adımlar listesi (Dinamik - partitionMethod ve installType'a göre şekillenir)
  List<String> get steps {
    List<String> baseSteps = [
      "Welcome",
      "Theme",
      "Location",
      "Network",
      "Account",
      "Type",
      "Disk",
    ];

    if (partitionMethod == 'manual') {
      baseSteps.add("Partitions");
    }

    // Standart kurulumda Kernel adımı kullanıcıya gösterilmez (Atlanır)
    if (installType == 'advanced') {
      baseSteps.add("Kernel");
    }

    baseSteps.add("Install");
    return baseSteps;
  }

  // ---- Geliştirici & Test Modu ----
  bool isDeveloperMode =
      false; // Geliştirici arayüz elemanlarını (varsa) gizler
  bool isMockEnabled =
      false; // GERÇEK KURULUM MODU: FFI/Sistem komutları DİREKT olarak çalıştırılır!

  // ---- 1. Welcome ----
  String selectedLanguage = 'tr'; // Varsayılan Türkçe

  // ---- 2. Theme ----
  String themeMode = 'dark'; // 'light' veya 'dark'

  // ---- 3. Location ----
  String selectedRegion = 'Türkiye';
  String selectedTimezone = 'Europe/Istanbul';
  String selectedKeyboard = 'trq';

  // ---- 4. Network ----
  String networkStatus = 'offline'; // 'offline' or 'connected'
  bool isEthernetConnected = false;
  List<Map<String, dynamic>> wifiNetworks = [];
  bool isScanningWifi = false;

  // ---- 5. Account ----
  String fullName = 'Geliştirici Test';
  String username = 'roasd';
  String password = '1234';
  bool isAdministrator = true;

  // ---- 6. Type ----
  String installType = 'standard'; // Deneysel varsayılan

  // ---- 7. Disk ----
  String selectedDisk = '';
  Map<String, dynamic>? selectedDiskDetails;
  double totalDiskSizeGB = 120.0;
  String fileSystem = 'btrfs'; // Deneysel için btrfs
  String partitionMethod = 'full';
  double linuxDiskSizeGB = 60.0;

  // Manuel Bölümlendirme Planı / Haritası
  List<Map<String, dynamic>> manualPartitions = [];

  // ---- Alongside (Yanına Kur) Algılama ----
  bool hasExistingOS = false;
  String detectedOS = '';
  bool hasExistingEfi = false;
  String existingEfiPartition = '';
  int diskFreeSpaceBytes = 0;
  int largestFreeContiguousBytes = 0;
  String diskBootMode = 'unknown';
  String diskPartitionTable = 'unknown';
  String shrinkCandidatePartition = '';
  String shrinkCandidateFs = '';
  int shrinkCandidateSizeBytes = 0;
  int alongsideMaxLinuxSizeBytes = 0;
  List<String> alongsideBlockers = [];
  bool isDetectingOS = false; // UI'da loading göstermek için

  // ---- 8. Kernel ----
  String kernelType = 'stable'; // Deneysel varsayılan

  // Navigasyon metodları
  void nextStep() {
    if (_currentStep < steps.length - 1) {
      _currentStep++;
      notifyListeners();
    }
  }

  void previousStep() {
    if (_currentStep > 0) {
      _currentStep--;
      notifyListeners();
    }
  }

  void goToStep(int stepIndex) {
    if (stepIndex >= 0 &&
        stepIndex < steps.length &&
        stepIndex <= _currentStep) {
      // Sadece ilerlediği adımlara veya geriye dönebilir
      _currentStep = stepIndex;
      notifyListeners();
    }
  }

  // State Güncelleme metodları
  void updateTheme(String mode) {
    themeMode = mode;
    notifyListeners();
  }

  void updateLanguage(String languageCode, {bool syncLocationPreset = true}) {
    if (translations.localeFor(languageCode) == null) {
      return;
    }
    selectedLanguage = languageCode;
    if (syncLocationPreset) {
      final preset = preferredLocationPresetForLanguage(languageCode);
      if (preset != null) {
        selectedRegion = preset.region;
        selectedTimezone = preset.timezone;
        selectedKeyboard = preset.keyboard;
      }
    }
    notifyListeners();
  }

  List<InstallerLocale> get availableLocales => translations.selectableLocales;
  int get activeLocaleCount => translations.selectableLocales.length;
  int get draftLocaleCount => translations.inactiveLocales.length;

  InstallerLocale get selectedLocale {
    return translations.localeFor(selectedLanguage) ??
        translations.localeFor(translations.fallbackLocale) ??
        translations.selectableLocales.first;
  }

  List<LocationPreset> get locationPresets =>
      List<LocationPreset>.unmodifiable(kLocationPresets);

  List<String> get availableRegions =>
      locationPresets.map((preset) => preset.region).toList(growable: false);

  List<String> get availableTimezones =>
      locationPresets.map((preset) => preset.timezone).toSet().toList()..sort();

  List<String> get availableKeyboards =>
      locationPresets.map((preset) => preset.keyboard).toSet().toList()
        ..sort((left, right) {
          return keyboardLabelFor(left).compareTo(keyboardLabelFor(right));
        });

  LocationPreset? get selectedRegionPreset {
    for (final preset in locationPresets) {
      if (preset.region == selectedRegion) {
        return preset;
      }
    }
    return null;
  }

  LocationPreset? preferredLocationPresetForLanguage(String languageCode) {
    return defaultLocationPresetForLanguage(
      languageCode,
      localeName: platformLocaleName,
    );
  }

  KeyboardPreset? keyboardPresetFor(String code) {
    for (final preset in kKeyboardPresets) {
      if (preset.code == code) {
        return preset;
      }
    }
    return null;
  }

  String keyboardLabelFor(String code) {
    return keyboardPresetFor(code)?.label ?? code.toUpperCase();
  }

  String get selectedKeyboardLabel {
    return keyboardLabelFor(selectedKeyboard);
  }

  void updateLocation({String? region, String? timezone, String? keyboard}) {
    if (region != null) selectedRegion = region;
    if (timezone != null) selectedTimezone = timezone;
    if (keyboard != null) selectedKeyboard = keyboard;
    notifyListeners();
  }

  void applyLocationPreset(String region) {
    LocationPreset? preset;
    for (final candidate in locationPresets) {
      if (candidate.region == region) {
        preset = candidate;
        break;
      }
    }
    if (preset == null) {
      return;
    }

    selectedRegion = preset.region;
    selectedTimezone = preset.timezone;
    selectedKeyboard = preset.keyboard;
    notifyListeners();
  }

  void updateInstallType(String type) {
    installType = type;
    // Eğer standart kurulum seçilirse, deneysel kernel kapatılıp otomatik stable yapılır
    if (type == 'standard') {
      kernelType = 'stable';
    }
    notifyListeners();
  }

  void updateKernel(String type) {
    kernelType = type;
    notifyListeners();
  }

  void updateAccount(String fName, String uName, String pass, bool isAdmin) {
    fullName = fName.trim();
    username = normalizeLinuxUsername(uName);
    password = pass.trim();
    isAdministrator = isAdmin;
    notifyListeners();
  }

  void updateDiskParams(String disk, String fs, String partition) {
    selectedDisk = disk;
    fileSystem = 'btrfs';
    partitionMethod = partition;
    notifyListeners();
  }

  void updateFileSystem(String fs) {
    fileSystem = 'btrfs';
    notifyListeners();
  }

  void updatePartitionMethod(String method) {
    partitionMethod = method;
    notifyListeners();
  }

  void updateLinuxDiskSize(double sizeGb) {
    final maxGb = alongsideMaxLinuxSizeBytes > 0
        ? alongsideMaxLinuxSizeBytes / (1024 * 1024 * 1024)
        : totalDiskSizeGB;
    linuxDiskSizeGB = sizeGb.clamp(40.0, maxGb < 40.0 ? 40.0 : maxGb);
    notifyListeners();
  }

  void selectDisk(Map<String, dynamic> diskObj) {
    final newDisk = diskObj['name'] as String;
    // Eğer önceden seçilen disk ile yenisi farklıysa eski disk bölümlerini iptal et (Sıfırla)
    if (selectedDisk != newDisk) {
      manualPartitions.clear();
    }
    selectedDiskDetails = diskObj;
    selectedDisk = newDisk;
    hasExistingOS = false;
    detectedOS = '';
    hasExistingEfi = false;
    existingEfiPartition = '';
    diskFreeSpaceBytes = 0;
    largestFreeContiguousBytes = 0;
    diskBootMode = 'unknown';
    diskPartitionTable = 'unknown';
    shrinkCandidatePartition = '';
    shrinkCandidateFs = '';
    shrinkCandidateSizeBytes = 0;
    alongsideMaxLinuxSizeBytes = 0;
    alongsideBlockers = [];

    // Boyutu Byte'dan GB'a çeviriyoruz
    final sizeBytes = diskObj['size'];
    if (sizeBytes != null && sizeBytes is int) {
      totalDiskSizeGB = sizeBytes / (1024 * 1024 * 1024);
      if (totalDiskSizeGB < 40) {
        totalDiskSizeGB = 40.0; // Slider patlamamasi icin min deger
      }
      linuxDiskSizeGB = (totalDiskSizeGB - 40).clamp(40.0, totalDiskSizeGB);
    }
    notifyListeners();

    // Alongside için arka planda disk detaylarını çek
    _detectDiskOS(newDisk);
  }

  Future<void> _detectDiskOS(String diskName) async {
    isDetectingOS = true;
    notifyListeners();

    try {
      final details = await DiskService.instance.detectDiskDetails(diskName);
      hasExistingOS = details['hasExistingOS'] as bool;
      detectedOS = details['detectedOS'] as String;
      hasExistingEfi = details['hasEfiPartition'] as bool;
      existingEfiPartition = details['efiPartitionName'] as String;
      diskFreeSpaceBytes = details['freeSpaceBytes'] as int;
      largestFreeContiguousBytes =
          (details['largestFreeContiguousBytes'] as int?) ?? 0;
      diskBootMode = (details['bootMode'] as String?) ?? 'unknown';
      diskPartitionTable = (details['partitionTable'] as String?) ?? 'unknown';
      shrinkCandidatePartition =
          (details['shrinkCandidatePartition'] as String?) ?? '';
      shrinkCandidateFs = (details['shrinkCandidateFs'] as String?) ?? '';
      shrinkCandidateSizeBytes =
          (details['shrinkCandidateSizeBytes'] as int?) ?? 0;
      alongsideMaxLinuxSizeBytes =
          (details['alongsideMaxLinuxSizeBytes'] as int?) ?? 0;
      alongsideBlockers = (details['alongsideBlockers'] as List<dynamic>? ?? [])
          .map((entry) => entry.toString())
          .toList();
      final maxGb = alongsideMaxLinuxSizeBytes > 0
          ? alongsideMaxLinuxSizeBytes / (1024 * 1024 * 1024)
          : totalDiskSizeGB;
      if (maxGb >= 40.0) {
        linuxDiskSizeGB = linuxDiskSizeGB.clamp(40.0, maxGb);
      }
    } catch (e) {
      hasExistingOS = false;
      detectedOS = '';
      hasExistingEfi = false;
      existingEfiPartition = '';
      diskFreeSpaceBytes = 0;
      largestFreeContiguousBytes = 0;
      diskBootMode = 'unknown';
      diskPartitionTable = 'unknown';
      shrinkCandidatePartition = '';
      shrinkCandidateFs = '';
      shrinkCandidateSizeBytes = 0;
      alongsideMaxLinuxSizeBytes = 0;
      alongsideBlockers = [];
    }

    isDetectingOS = false;
    notifyListeners();
  }
}

extension LocalizationExtension on InstallerState {
  String t(String key, [Map<String, String> placeholders = const {}]) {
    var value = translations.translate(selectedLanguage, key);
    for (final entry in placeholders.entries) {
      value = value.replaceAll('{${entry.key}}', entry.value);
    }
    return value;
  }
}
