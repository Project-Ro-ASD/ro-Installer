import 'standard_storage_layout.dart';

const installerSeedPath = '/var/lib/ro-asd/firstboot/installer-seed-v1.json';
const installMetadataPath = '/var/lib/ro-asd/install/metadata.json';

Map<String, dynamic> installerSeed(String language) => {
  'schema_version': 1,
  'installer_ui_language_hint': language,
};

Map<String, dynamic> installMetadata() => {
  'schema_version': 1,
  'layout_schema_version': 1,
  'install_mode': 'full',
  'filesystem': 'btrfs',
  'subvolumes': StandardStorageLayout.subvolumes.keys.toList(),
};

/// Exact allowlists keep provenance and the firstboot hint free of identity/secrets.
bool isValidInstallerHandoff(Object? seed, Object? metadata) {
  if (seed is! Map || metadata is! Map) return false;
  final language = seed['installer_ui_language_hint'];
  if (seed.length != 2 ||
      seed['schema_version'] != 1 ||
      language is! String ||
      language.trim().isEmpty) {
    return false;
  }
  final expected = installMetadata();
  if (metadata.length != expected.length ||
      !expected.keys.every(metadata.containsKey)) {
    return false;
  }
  for (final key in expected.keys.where((key) => key != 'subvolumes')) {
    if (metadata[key] != expected[key]) return false;
  }
  final subvolumes = metadata['subvolumes'];
  final names = StandardStorageLayout.subvolumes.keys.toList();
  return subvolumes is List &&
      subvolumes.length == names.length &&
      List.generate(
        names.length,
        (i) => subvolumes[i] == names[i],
      ).every((v) => v);
}
