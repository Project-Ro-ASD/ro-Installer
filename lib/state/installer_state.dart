import 'package:flutter/material.dart';
import '../services/disk_service.dart';
import '../l10n/installer_translation_catalog.dart';

class InstallerState extends ChangeNotifier {
  int _currentStep = 0;
  int get currentStep => _currentStep;

  InstallerState({required this.translations});

  final InstallerTranslationCatalog translations;

  // Disk discovery may still complete after the state has been disposed.
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_isDisposed) {
      return;
    }
    super.notifyListeners();
  }

  // Initial Setup owns first-user configuration.
  List<String> get steps => const ["Welcome", "Disk", "Install"];

  // ---- Geliştirici & Test Modu ----
  bool isDeveloperMode =
      false; // Geliştirici arayüz elemanlarını (varsa) gizler
  bool isMockEnabled =
      false; // GERÇEK KURULUM MODU: FFI/Sistem komutları DİREKT olarak çalıştırılır!

  // ---- 1. Welcome ----
  String selectedLanguage = 'tr'; // Varsayılan Türkçe

  // ---- 7. Disk ----
  String selectedDisk = '';
  Map<String, dynamic>? selectedDiskDetails;
  double totalDiskSizeGB = 120.0;
  String fileSystem = 'btrfs'; // Deneysel için btrfs
  String partitionMethod = 'full';
  double linuxDiskSizeGB = 60.0;
  Map<String, dynamic> selectedFreeSpace = {};

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
  List<String> unsupportedStorageBlockers = [];
  List<String> unsupportedStorageDetails = [];
  bool isDetectingOS = false; // UI'da loading göstermek için

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
  void updateLanguage(String languageCode) {
    if (translations.localeFor(languageCode) == null) return;
    selectedLanguage = languageCode;
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
    selectedFreeSpace = {};
    if (method != 'full') {
      notifyListeners();
      return;
    }
    partitionMethod = 'full';
    notifyListeners();
  }

  void updateLinuxDiskSize(double sizeGb) {
    final maxGb = alongsideMaxLinuxSizeBytes > 0
        ? alongsideMaxLinuxSizeBytes / (1024 * 1024 * 1024)
        : totalDiskSizeGB;
    linuxDiskSizeGB = sizeGb.clamp(40.0, maxGb < 40.0 ? 40.0 : maxGb);
    notifyListeners();
  }

  void updateFreeSpaceSelection(Map<String, dynamic>? freeSpace) {
    selectedFreeSpace = freeSpace == null
        ? {}
        : Map<String, dynamic>.from(freeSpace);
    notifyListeners();
  }

  void selectDisk(Map<String, dynamic> diskObj) {
    final newDisk = diskObj['name'] as String;
    // Eğer önceden seçilen disk ile yenisi farklıysa eski disk bölümlerini iptal et (Sıfırla)
    if (selectedDisk != newDisk) {
      manualPartitions.clear();
      selectedFreeSpace = {};
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
    unsupportedStorageBlockers = [];
    unsupportedStorageDetails = [];

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
      unsupportedStorageBlockers =
          (details['unsupportedStorageBlockers'] as List<dynamic>? ?? [])
              .map((entry) => entry.toString())
              .toList();
      unsupportedStorageDetails =
          (details['unsupportedStorageDetails'] as List<dynamic>? ?? [])
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
      unsupportedStorageBlockers = [];
      unsupportedStorageDetails = [];
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
