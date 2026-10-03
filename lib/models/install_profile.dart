import 'dart:convert';
import 'dart:io';

/// Automated full-disk MVP profile. Initial Setup owns user and system settings.
/// Legacy identity/secret fields are accepted as unknown input and discarded.
class InstallProfile {
  const InstallProfile({
    this.schemaVersion = 1,
    required this.selectedDisk,
    this.partitionMethod = 'full',
    this.fileSystem = 'btrfs',
    this.selectedLanguage = 'tr',
    this.confirmDestructive = false,
    this.encryptionEnabled = false,
  });

  final int schemaVersion;
  final String selectedDisk;
  final String partitionMethod;
  final String fileSystem;
  final String selectedLanguage;
  final bool confirmDestructive;
  // A request flag only; never retain an encryption secret.
  final bool encryptionEnabled;

  factory InstallProfile.fromJson(Map<String, dynamic> json) {
    final storage = json['storage'];
    final nested = storage is Map ? storage['encryption'] : null;
    final topLevel = json['encryption'];
    bool requestsEncryption(Object? value) => value != null && value != false;
    bool requestsType(Object? value) =>
        value != null && value.toString().toLowerCase() != 'none';
    return InstallProfile(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      selectedDisk: json['selectedDisk'] as String? ?? '',
      partitionMethod: json['partitionMethod'] as String? ?? 'full',
      fileSystem: (json['fileSystem'] as String?)?.toLowerCase() ?? 'btrfs',
      selectedLanguage:
          json['selectedLanguage'] as String? ??
          json['language'] as String? ??
          'tr',
      confirmDestructive:
          (json.containsKey('confirmDestructive')
              ? json['confirmDestructive']
              : json['confirm_destructive']) ==
          true,
      encryptionEnabled:
          requestsEncryption(json['encryptionEnabled']) ||
          requestsType(json['encryptionType']) ||
          (nested is Map &&
              (requestsEncryption(nested['enabled']) ||
                  requestsType(nested['type']))) ||
          (topLevel is Map &&
              (requestsEncryption(topLevel['enabled']) ||
                  requestsType(topLevel['type']))) ||
          (nested is! Map && requestsEncryption(nested)) ||
          (topLevel is! Map && requestsEncryption(topLevel)),
    );
  }

  factory InstallProfile.fromJsonFile(String path) =>
      InstallProfile.fromJsonString(File(path).readAsStringSync());

  factory InstallProfile.fromJsonString(String source) =>
      InstallProfile.fromJson(jsonDecode(source) as Map<String, dynamic>);

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'selectedDisk': selectedDisk,
    'partitionMethod': partitionMethod,
    'fileSystem': fileSystem,
    'selectedLanguage': selectedLanguage,
    'confirmDestructive': confirmDestructive,
    'encryptionEnabled': encryptionEnabled,
  };

  Map<String, dynamic> toStateMap() => toJson();

  List<String> validate() {
    final errors = <String>[];
    if (schemaVersion != 1) errors.add('Desteklenmeyen profil şema sürümü.');
    if (!RegExp(r'^/dev/[A-Za-z0-9_-]+$').hasMatch(selectedDisk)) {
      errors.add('Geçersiz hedef disk yolu.');
    }
    if (partitionMethod != 'full') {
      errors.add(
        'Storage MVP yalnızca full-disk erase destekler: $partitionMethod',
      );
    }
    if (fileSystem != 'btrfs') {
      errors.add('Geçersiz dosya sistemi: yalnizca btrfs desteklenir.');
    }
    if (!confirmDestructive) {
      errors.add('Destructive installation requires confirmDestructive=true.');
    }
    if (encryptionEnabled) errors.add('LUKS kurulumu henüz desteklenmiyor.');
    return errors;
  }

  @override
  String toString() => jsonEncode(toJson());
}
