import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/models/install_profile.dart';

void main() {
  Map<String, dynamic> valid() => {
    'schemaVersion': 1,
    'selectedDisk': '/dev/vda',
    'partitionMethod': 'full',
    'fileSystem': 'btrfs',
    'selectedLanguage': 'tr',
    'confirmDestructive': true,
  };

  test('full/Btrfs requires no account or location and round-trips safely', () {
    final profile = InstallProfile.fromJson(valid());
    expect(profile.validate(), isEmpty);
    expect(
      InstallProfile.fromJsonString(jsonEncode(profile.toJson())).toJson(),
      profile.toJson(),
    );
    expect(
      InstallProfile.fromJsonFile(
        'test/fixtures/profile_full_btrfs.json',
      ).validate(),
      isEmpty,
    );
  });

  test(
    'legacy identity, location, kernel and storage inputs are discarded',
    () {
      final profile = InstallProfile.fromJson({
        ...valid(),
        'username': 'old-user',
        'password': 'private-password',
        'passwordHash': 'hash',
        'fullName': 'Old Name',
        'timezone': 'Asia/Tokyo',
        'keyboard': 'jp106',
        'isAdministrator': true,
        'selectedRegion': 'Japan',
        'selectedLocale': 'ja_JP.UTF-8',
        'selectedKernelChannels': ['experimental'],
        'manualPartitions': [],
        'existingEfiPartition': '/dev/vda3',
        'linuxDiskSizeGB': 64,
        'selectedFreeSpace': {'startSector': 1},
      });

      expect(profile.validate(), isEmpty);
      expect(profile.toJson().keys.toSet(), {
        'schemaVersion',
        'selectedDisk',
        'partitionMethod',
        'fileSystem',
        'selectedLanguage',
        'confirmDestructive',
        'encryptionEnabled',
      });
      expect(profile.toStateMap(), profile.toJson());
      expect(profile.toString(), isNot(contains('private-password')));
      expect(profile.toString(), isNot(contains('old-user')));
    },
  );

  for (final consent in [null, false, 'true', 1]) {
    test('confirmation $consent is not explicit boolean consent', () {
      final input = valid()..remove('confirmDestructive');
      if (consent != null) input['confirmDestructive'] = consent;
      expect(InstallProfile.fromJson(input).validate(), isNotEmpty);
    });
  }
  test('canonical false cannot be overridden by an alias', () {
    expect(
      InstallProfile.fromJson({
        ...valid(),
        'confirmDestructive': false,
        'confirm_destructive': true,
      }).validate(),
      isNotEmpty,
    );
  });

  test('snake-case boolean consent is accepted', () {
    final input = valid()..remove('confirmDestructive');
    input['confirm_destructive'] = true;
    expect(InstallProfile.fromJson(input).validate(), isEmpty);
  });

  for (final mode in ['manual', 'alongside', 'free_space', 'unknown']) {
    test('$mode still fails closed', () {
      final profile = InstallProfile.fromJson({
        ...valid(),
        'partitionMethod': mode,
      });
      expect(profile.partitionMethod, mode);
      expect(
        profile.validate(),
        contains('Storage MVP yalnızca full-disk erase destekler: $mode'),
      );
    });
  }
  for (final invalid in [
    {'fileSystem': 'ext4'},
    {'fileSystem': 'xfs'},
    {'selectedDisk': ''},
    {'selectedDisk': '/dev/sda;echo unsafe'},
    {'schemaVersion': 2},
  ]) {
    test('$invalid fails validation', () {
      expect(
        InstallProfile.fromJson({...valid(), ...invalid}).validate(),
        isNotEmpty,
      );
    });
  }
  for (final request in [
    {'encryptionEnabled': true, 'encryptionPassphrase': 'secret'},
    {
      'storage': {
        'encryption': {'enabled': true, 'passphrase': 'secret'},
      },
    },
    {
      'storage': {
        'encryption': {'enabled': false},
      },
      'encryptionEnabled': true,
    },
    {
      'storage': {
        'encryption': {'enabled': true},
      },
      'encryptionEnabled': false,
    },
    {
      'encryption': {'enabled': true, 'passphrase': 'secret'},
    },
    {'encryption': true},
    {
      'storage': {'encryption': true},
    },
    {'encryptionType': 'luks2'},
    {'encryptionEnabled': 'true'},
  ]) {
    test(
      'encryption request $request fails closed without retaining secrets',
      () {
        final profile = InstallProfile.fromJson({...valid(), ...request});
        expect(profile.encryptionEnabled, isTrue);
        expect(
          profile.validate(),
          contains('LUKS kurulumu henüz desteklenmiyor.'),
        );
        expect(jsonEncode(profile.toStateMap()), isNot(contains('secret')));
        expect(profile.toString(), isNot(contains('passphrase')));
      },
    );
  }
}
