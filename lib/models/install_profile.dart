import 'dart:convert';
import 'dart:io';

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

  /// Dosya sistemi türü: 'btrfs', 'ext4', 'xfs'
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

  /// Manuel modda kullanıcının oluşturduğu bölüm planı
  final List<Map<String, dynamic>> manualPartitions;

  /// Seçilen bölge/dil (ör: 'Europe/Istanbul', 'tr_TR.UTF-8')
  final String selectedRegion;

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
    this.manualPartitions = const [],
    this.selectedRegion = 'Europe/Istanbul',
  });

  /// JSON Map'ten oluşturur.
  factory InstallProfile.fromJson(Map<String, dynamic> json) {
    return InstallProfile(
      selectedDisk: json['selectedDisk'] as String? ?? '',
      partitionMethod: json['partitionMethod'] as String? ?? 'full',
      fileSystem: json['fileSystem'] as String? ?? 'btrfs',
      username: json['username'] as String? ?? 'user',
      password: json['password'] as String? ?? '',
      timezone: json['timezone'] as String? ??
          json['selectedTimezone'] as String? ??
          'Europe/Istanbul',
      keyboard: json['keyboard'] as String? ??
          json['selectedKeyboard'] as String? ??
          'trq',
      isAdministrator: json['isAdministrator'] as bool? ?? true,
      linuxDiskSizeGB: (json['linuxDiskSizeGB'] as num?)?.toDouble() ?? 60.0,
      hasExistingEfi: json['hasExistingEfi'] as bool? ?? false,
      existingEfiPartition: json['existingEfiPartition'] as String? ?? '',
      manualPartitions: (json['manualPartitions'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      selectedRegion: json['selectedRegion'] as String? ?? 'Europe/Istanbul',
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
        'manualPartitions': manualPartitions,
        'selectedRegion': selectedRegion,
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
        'manualPartitions': manualPartitions,
        'selectedRegion': selectedRegion,
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
    if (!['btrfs', 'ext4', 'xfs'].contains(fileSystem)) {
      errors.add('Geçersiz dosya sistemi: $fileSystem');
    }
    if (username.isEmpty) {
      errors.add('Kullanıcı adı boş olamaz.');
    }
    if (username.contains(' ') || username.contains(RegExp(r'[^a-z0-9_-]'))) {
      errors.add('Kullanıcı adı geçersiz karakterler içeriyor: $username');
    }
    if (password.isEmpty) {
      errors.add('Parola boş olamaz.');
    }
    if (password.length < 4) {
      errors.add('Parola en az 4 karakter olmalıdır.');
    }
    if (partitionMethod == 'alongside' && linuxDiskSizeGB < 20) {
      errors.add('Alongside kurulumu için en az 20 GB gerekli.');
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
        'user: $username)';
  }
}
