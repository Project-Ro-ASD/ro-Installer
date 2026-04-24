import 'dart:convert';
import 'dart:io';
import '../utils/account_validation.dart';

/// Kurulum yapılandırma profili.
///
/// GUI bu modeli doldurur → kurulum motoruna verir.
/// Test sistemi JSON dosyasından okur → kurulum motoruna verir.
/// Böylece **aynı kurulum senaryosu hem GUI'den hem JSON'dan çalıştırılabilir**.
///
/// Kullanım:
/// ```dart
/// // GUI'den:
/// final profile = InstallProfile(
///   selectedDisk: '/dev/sda',
///   partitionMethod: 'full',
///   fileSystem: 'btrfs',
///   username: 'smurat',
///   password: 'güvenli_şifre',
///   timezone: 'Europe/Istanbul',
///   keyboard: 'trq',
/// );
///
/// // JSON'dan (test senaryosu):
/// final profile = InstallProfile.fromJsonFile('test/profiles/full_btrfs.json');
///
/// // Stage'lere aktarım:
/// final stateMap = profile.toStateMap();
/// ```
class InstallProfile {
  /// Hedef disk yolu (ör: '/dev/sda', '/dev/nvme0n1')
  final String selectedDisk;

  /// Bölümleme yöntemi: 'full', 'alongside', 'manual'
  final String partitionMethod;

  /// Dosya sistemi türü: yalnizca 'btrfs'
  final String fileSystem;

  /// Kullanıcı adı
  final String username;

  /// Kullanıcı parolası
  final String password;

  /// Zaman dilimi (ör: 'Europe/Istanbul')
  final String timezone;

  /// Klavye düzeni (ör: 'trq', 'us')
  final String keyboard;

  /// Kullanıcı yönetici mi? (sudo yetkisi)
  final bool isAdministrator;

  /// Alongside modunda Linux'a ayrılacak disk boyutu (GB)
  final double linuxDiskSizeGB;

  /// Mevcut EFI bölümü var mı? (alongside modu)
  final bool hasExistingEfi;

  /// Mevcut EFI bölüm yolu (alongside modu, ör: '/dev/sda1')
  final String existingEfiPartition;

  /// Alongside modunda küçültülecek mevcut bölüm yolu
  final String shrinkCandidatePartition;

  /// Alongside modunda küçültülecek mevcut bölüm dosya sistemi
  final String shrinkCandidateFs;

  /// Alongside modunda küçültülecek bölümün toplam boyutu
  final int shrinkCandidateSizeBytes;

  /// Manuel modda kullanıcının oluşturduğu bölüm planı
  final List<Map<String, dynamic>> manualPartitions;

  /// Seçilen ülke/bölge adı (ör: 'Türkiye', '日本')
  final String selectedRegion;

  /// Kurulum arayüzü ve motoru için dil kodu (ör: 'tr', 'en', 'es')
  final String selectedLanguage;

  /// Kurulu sisteme yazılacak locale override değeri (ör: 'tr_TR.UTF-8')
  final String selectedLocale;

  const InstallProfile({
    required this.selectedDisk,
    required this.partitionMethod,
    this.fileSystem = 'btrfs',
    required this.username,
    required this.password,
    this.timezone = 'Europe/Istanbul',
    this.keyboard = 'trq',
    this.isAdministrator = true,
    this.linuxDiskSizeGB = 60.0,
    this.hasExistingEfi = false,
    this.existingEfiPartition = '',
    this.shrinkCandidatePartition = '',
    this.shrinkCandidateFs = '',
    this.shrinkCandidateSizeBytes = 0,
    this.manualPartitions = const [],
    this.selectedRegion = 'Türkiye',
    this.selectedLanguage = 'tr',
    this.selectedLocale = '',
  });

  /// JSON Map'ten oluşturur.
  factory InstallProfile.fromJson(Map<String, dynamic> json) {
    return InstallProfile(
      selectedDisk: json['selectedDisk'] as String? ?? '',
      partitionMethod: json['partitionMethod'] as String? ?? 'full',
      fileSystem: 'btrfs',
      username: json['username'] as String? ?? 'user',
      password: json['password'] as String? ?? '',
      timezone:
          json['timezone'] as String? ??
          json['selectedTimezone'] as String? ??
          'Europe/Istanbul',
      keyboard:
          json['keyboard'] as String? ??
          json['selectedKeyboard'] as String? ??
          'trq',
      isAdministrator: json['isAdministrator'] as bool? ?? true,
      linuxDiskSizeGB: (json['linuxDiskSizeGB'] as num?)?.toDouble() ?? 60.0,
      hasExistingEfi: json['hasExistingEfi'] as bool? ?? false,
      existingEfiPartition: json['existingEfiPartition'] as String? ?? '',
      shrinkCandidatePartition:
          json['shrinkCandidatePartition'] as String? ?? '',
      shrinkCandidateFs: json['shrinkCandidateFs'] as String? ?? '',
      shrinkCandidateSizeBytes: json['shrinkCandidateSizeBytes'] as int? ?? 0,
      manualPartitions:
          (json['manualPartitions'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      selectedRegion: json['selectedRegion'] as String? ?? 'Türkiye',
      selectedLanguage:
          json['selectedLanguage'] as String? ??
          json['language'] as String? ??
          'tr',
      selectedLocale:
          json['selectedLocale'] as String? ?? json['locale'] as String? ?? '',
    );
  }

  /// JSON dosyasından oluşturur (test senaryoları için).
  factory InstallProfile.fromJsonFile(String path) {
    final content = File(path).readAsStringSync();
    final json = jsonDecode(content) as Map<String, dynamic>;
    return InstallProfile.fromJson(json);
  }

  /// JSON string'inden oluşturur.
  factory InstallProfile.fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return InstallProfile.fromJson(json);
  }

  /// JSON Map'e dönüştürür.
  Map<String, dynamic> toJson() => {
    'selectedDisk': selectedDisk,
    'partitionMethod': partitionMethod,
    'fileSystem': fileSystem,
    'username': username,
    'password': password,
    'timezone': timezone,
    'keyboard': keyboard,
    'isAdministrator': isAdministrator,
    'linuxDiskSizeGB': linuxDiskSizeGB,
    'hasExistingEfi': hasExistingEfi,
    'existingEfiPartition': existingEfiPartition,
    'shrinkCandidatePartition': shrinkCandidatePartition,
    'shrinkCandidateFs': shrinkCandidateFs,
    'shrinkCandidateSizeBytes': shrinkCandidateSizeBytes,
    'manualPartitions': manualPartitions,
    'selectedRegion': selectedRegion,
    'selectedLanguage': selectedLanguage,
    'selectedLocale': selectedLocale,
  };

  /// Stage'lerin beklediği state Map'ine dönüştürür.
  ///
  /// Mevcut stage'ler `ctx.state['selectedDisk']` gibi anahtarlar kullanıyor.
  /// Bu metot, profildeki verileri bu anahtarlarla eşleştirir.
  /// İleride stage'ler doğrudan InstallProfile kullanmaya geçtiğinde
  /// bu metot kaldırılabilir.
  Map<String, dynamic> toStateMap() => {
    'selectedDisk': selectedDisk,
    'partitionMethod': partitionMethod,
    'fileSystem': fileSystem,
    'username': username,
    'password': password,
    'selectedTimezone': timezone,
    'selectedKeyboard': keyboard,
    'isAdministrator': isAdministrator,
    'linuxDiskSizeGB': linuxDiskSizeGB,
    'hasExistingEfi': hasExistingEfi,
    'existingEfiPartition': existingEfiPartition,
    'shrinkCandidatePartition': shrinkCandidatePartition,
    'shrinkCandidateFs': shrinkCandidateFs,
    'shrinkCandidateSizeBytes': shrinkCandidateSizeBytes,
    'manualPartitions': manualPartitions,
    'selectedRegion': selectedRegion,
    'selectedLanguage': selectedLanguage,
    'selectedLocale': selectedLocale,
  };

  /// Profili doğrular ve hata listesi döndürür.
  /// Boş liste = geçerli profil.
  List<String> validate() {
    final errors = <String>[];

    if (selectedDisk.isEmpty) {
      errors.add('Hedef disk seçilmedi.');
    }
    if (!['full', 'alongside', 'manual'].contains(partitionMethod)) {
      errors.add('Geçersiz bölümleme yöntemi: $partitionMethod');
    }
    if (fileSystem != 'btrfs') {
      errors.add('Geçersiz dosya sistemi: yalnizca btrfs desteklenir.');
    }
    if (username.isEmpty) {
      errors.add('Kullanıcı adı boş olamaz.');
    }
    if (!isValidLinuxUsername(username)) {
      errors.add(
        'Kullanıcı adı Linux kurallarına uymuyor: $username (harf veya _ ile başlamalı, sadece kucuk harf/rakam/_/- içermeli)',
      );
    }
    if (password.isEmpty) {
      errors.add('Parola boş olamaz.');
    }
    if (password.length < 4) {
      errors.add('Parola en az 4 karakter olmalıdır.');
    }
    if (selectedLanguage.isEmpty) {
      errors.add('Dil kodu boş olamaz.');
    }
    if (partitionMethod == 'alongside' && linuxDiskSizeGB < 40) {
      errors.add('Alongside kurulumu için en az 40 GB gerekli.');
    }
    if (partitionMethod == 'manual' && manualPartitions.isEmpty) {
      errors.add('Manuel modda bölüm planı boş olamaz.');
    }
    if (partitionMethod == 'manual') {
      final hasRoot = manualPartitions.any((p) => p['mount'] == '/');
      if (!hasRoot) {
        errors.add('Manuel modda root (/) bölümü tanımlanmalıdır.');
      }
    }

    return errors;
  }

  /// Profil geçerli mi?
  bool get isValid => validate().isEmpty;

  @override
  String toString() {
    return 'InstallProfile('
        'disk: $selectedDisk, '
        'method: $partitionMethod, '
        'fs: $fileSystem, '
        'language: $selectedLanguage, '
        'user: $username)';
  }
}
