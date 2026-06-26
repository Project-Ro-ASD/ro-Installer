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
  /// Profil şema sürümü. V1 mevcut Btrfs tabanlı profil sözleşmesidir.
  final int schemaVersion;

  /// Hedef disk yolu (ör: '/dev/sda', '/dev/nvme0n1')
  final String selectedDisk;

  /// Bölümleme yöntemi: 'full', 'alongside', 'free_space', 'manual'
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

  /// Ayrılmış alana kur modunda seçilen boş alan segmenti
  final Map<String, dynamic> selectedFreeSpace;

  /// Seçilen ülke/bölge adı (ör: 'Türkiye', '日本')
  final String selectedRegion;

  /// Kurulum arayüzü ve motoru için dil kodu (ör: 'tr', 'en', 'es')
  final String selectedLanguage;

  /// Kurulu sisteme yazılacak locale override değeri (ör: 'tr_TR.UTF-8')
  final String selectedLocale;

  /// Kurulum kernel politikası: 'stable' ro-kernel-stable kanalını,
  /// 'experimental' ro-kernel-experimental kanalını temsil eder.
  final List<String> selectedKernelChannels;

  /// Disk şifreleme isteği. V1 profil sözleşmesi bu alanı tanır; stage desteği
  /// tamamlanana kadar etkin profiller doğrulamada bilinçli olarak düşürülür.
  final InstallProfileEncryption encryption;

  const InstallProfile({
    this.schemaVersion = 1,
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
    this.selectedFreeSpace = const {},
    this.selectedRegion = 'Türkiye',
    this.selectedLanguage = 'tr',
    this.selectedLocale = '',
    this.selectedKernelChannels = const ['stable'],
    this.encryption = const InstallProfileEncryption(),
  });

  /// JSON Map'ten oluşturur.
  factory InstallProfile.fromJson(Map<String, dynamic> json) {
    return InstallProfile(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      selectedDisk: json['selectedDisk'] as String? ?? '',
      partitionMethod: json['partitionMethod'] as String? ?? 'full',
      fileSystem: (json['fileSystem'] as String?)?.toLowerCase() ?? 'btrfs',
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
      selectedFreeSpace: json['selectedFreeSpace'] is Map
          ? Map<String, dynamic>.from(json['selectedFreeSpace'] as Map)
          : const {},
      selectedRegion: json['selectedRegion'] as String? ?? 'Türkiye',
      selectedLanguage:
          json['selectedLanguage'] as String? ??
          json['language'] as String? ??
          'tr',
      selectedLocale:
          json['selectedLocale'] as String? ?? json['locale'] as String? ?? '',
      selectedKernelChannels: _parseKernelChannels(
        json['selectedKernelChannels'] ?? json['kernelChannels'],
      ),
      encryption: InstallProfileEncryption.fromJson(json),
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
    'schemaVersion': schemaVersion,
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
    'selectedFreeSpace': selectedFreeSpace,
    'selectedRegion': selectedRegion,
    'selectedLanguage': selectedLanguage,
    'selectedLocale': selectedLocale,
    'selectedKernelChannels': selectedKernelChannels,
    'storage': {'encryption': encryption.toJson()},
  };

  /// Stage'lerin beklediği state Map'ine dönüştürür.
  ///
  /// Mevcut stage'ler `ctx.state['selectedDisk']` gibi anahtarlar kullanıyor.
  /// Bu metot, profildeki verileri bu anahtarlarla eşleştirir.
  /// İleride stage'ler doğrudan InstallProfile kullanmaya geçtiğinde
  /// bu metot kaldırılabilir.
  Map<String, dynamic> toStateMap() => {
    'schemaVersion': schemaVersion,
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
    'selectedFreeSpace': selectedFreeSpace,
    'selectedRegion': selectedRegion,
    'selectedLanguage': selectedLanguage,
    'selectedLocale': selectedLocale,
    'selectedKernelChannels': selectedKernelChannels,
    'encryptionEnabled': encryption.enabled,
    'encryptionType': encryption.type,
    'encryptionPassphrase': encryption.passphrase,
  };

  /// Profili doğrular ve hata listesi döndürür.
  /// Boş liste = geçerli profil.
  List<String> validate() {
    final errors = <String>[];

    if (selectedDisk.isEmpty) {
      errors.add('Hedef disk seçilmedi.');
    }
    if (schemaVersion < 1) {
      errors.add('Geçersiz profil şema sürümü: $schemaVersion');
    }
    if (![
      'full',
      'alongside',
      'free_space',
      'manual',
    ].contains(partitionMethod)) {
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
    if (selectedKernelChannels.isEmpty) {
      errors.add('En az bir kernel kanalı seçilmelidir.');
    }
    for (final channel in selectedKernelChannels) {
      if (!['stable', 'experimental'].contains(channel)) {
        errors.add('Geçersiz kernel kanalı: $channel');
      }
    }
    if (encryption.enabled) {
      if (encryption.type != 'luks2') {
        errors.add('Geçersiz şifreleme türü: ${encryption.type}');
      }
      if (encryption.passphrase.isEmpty) {
        errors.add('LUKS parolası boş olamaz.');
      } else if (encryption.passphrase.length < 8) {
        errors.add('LUKS parolası en az 8 karakter olmalıdır.');
      }
      errors.add(
        'LUKS stage desteği henüz tamamlanmadı; şifreli profil güvenli şekilde durduruldu.',
      );
    }
    if (partitionMethod == 'alongside' && linuxDiskSizeGB < 40) {
      errors.add('Alongside kurulumu için en az 40 GB gerekli.');
    }
    if (partitionMethod == 'free_space' && selectedFreeSpace.isEmpty) {
      errors.add('Ayrılmış alana kur için boş alan seçilmelidir.');
    }
    if (partitionMethod == 'manual' && manualPartitions.isEmpty) {
      errors.add('Manuel modda bölüm planı boş olamaz.');
    }
    if (partitionMethod == 'manual') {
      final hasRoot = manualPartitions.any((p) => p['mount'] == '/');
      if (!hasRoot) {
        errors.add('Manuel modda root (/) bölümü tanımlanmalıdır.');
      }
      for (final partition in manualPartitions) {
        if (partition['isFreeSpace'] == true) {
          continue;
        }
        final name = (partition['name'] ?? 'isimsiz bolum').toString();
        final mount = (partition['mount'] ?? 'unmounted').toString();
        final type = (partition['type'] ?? '').toString();
        if (mount == '/boot/efi') {
          if (type != 'fat32' && type != 'vfat') {
            errors.add('Manuel profilde EFI bölümü FAT32 olmalıdır: $name');
          }
          continue;
        }
        if (mount == '[SWAP]') {
          if (type != 'linux-swap' && type != 'swap') {
            errors.add(
              'Manuel profilde swap bölümü linux-swap olmalıdır: $name',
            );
          }
          continue;
        }
        if (mount != 'unmounted' && type != 'btrfs') {
          errors.add(
            'Manuel profilde mount edilen bölümler Btrfs olmalıdır: $name ($type)',
          );
        }
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
        'encryption: ${encryption.enabled ? encryption.type : 'off'}, '
        'user: $username)';
  }
}

class InstallProfileEncryption {
  final bool enabled;
  final String type;
  final String passphrase;

  const InstallProfileEncryption({
    this.enabled = false,
    this.type = 'none',
    this.passphrase = '',
  });

  factory InstallProfileEncryption.fromJson(Map<String, dynamic> json) {
    final storage = json['storage'];
    final nestedEncryption = storage is Map ? storage['encryption'] : null;
    final raw = nestedEncryption is Map
        ? Map<String, dynamic>.from(nestedEncryption)
        : <String, dynamic>{};

    final enabled =
        raw['enabled'] as bool? ?? json['encryptionEnabled'] as bool? ?? false;
    final type =
        raw['type'] as String? ??
        json['encryptionType'] as String? ??
        (enabled ? 'luks2' : 'none');
    final passphrase =
        raw['passphrase'] as String? ??
        json['encryptionPassphrase'] as String? ??
        '';

    return InstallProfileEncryption(
      enabled: enabled,
      type: enabled ? type : 'none',
      passphrase: passphrase,
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'type': type};
}

List<String> _parseKernelChannels(Object? raw) {
  final channels = <String>[];

  void addChannel(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isNotEmpty && !channels.contains(normalized)) {
      channels.add(normalized);
    }
  }

  if (raw is Iterable) {
    for (final entry in raw) {
      addChannel(entry.toString());
    }
  } else if (raw is String && raw.trim().isNotEmpty) {
    for (final entry in raw.split(RegExp(r'[, ]+'))) {
      addChannel(entry);
    }
  }

  if (channels.isEmpty) {
    return const ['stable'];
  }
  return channels;
}
