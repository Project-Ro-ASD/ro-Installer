import 'package:test/test.dart';
import 'package:ro_installer/models/install_profile.dart';

void main() {
  group('InstallProfile', () {
    test('schemaVersion ve encryption alanlarını state map içine taşır', () {
      final profile = InstallProfile.fromJson({
        'schemaVersion': 1,
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'full',
        'username': 'tester',
        'password': 'secure123',
        'storage': {
          'encryption': {'enabled': false, 'type': 'none'},
        },
      });

      expect(profile.validate(), isEmpty);
      expect(profile.schemaVersion, 1);
      expect(profile.encryption.enabled, false);
      expect(profile.toStateMap()['encryptionEnabled'], false);
      expect(profile.toStateMap()['encryptionType'], 'none');
    });

    test(
      'Btrfs disi fileSystem profilde sessizce degistirilmez ve reddedilir',
      () {
        final profile = InstallProfile.fromJson({
          'selectedDisk': '/dev/vda',
          'partitionMethod': 'full',
          'fileSystem': 'ext4',
          'username': 'tester',
          'password': 'secure123',
        });

        final errors = profile.validate();

        expect(profile.fileSystem, 'ext4');
        expect(profile.toStateMap()['fileSystem'], 'ext4');
        expect(
          errors,
          contains('Geçersiz dosya sistemi: yalnizca btrfs desteklenir.'),
        );
      },
    );

    test('manuel profilde mount edilen Btrfs disi bolum reddedilir', () {
      final profile = InstallProfile.fromJson({
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'manual',
        'username': 'tester',
        'password': 'secure123',
        'manualPartitions': [
          {
            'name': '/dev/vda1',
            'type': 'fat32',
            'mount': '/boot/efi',
            'isPlanned': true,
            'isFreeSpace': false,
          },
          {
            'name': '/dev/vda2',
            'type': 'ext4',
            'mount': '/',
            'isPlanned': true,
            'isFreeSpace': false,
          },
        ],
      });

      expect(
        profile.validate(),
        contains(
          'Manuel profilde mount edilen bölümler Btrfs olmalıdır: /dev/vda2 (ext4)',
        ),
      );
    });

    test('LUKS etkin profil stage desteği tamamlanana kadar reddedilir', () {
      final profile = InstallProfile.fromJson({
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'full',
        'username': 'tester',
        'password': 'secure123',
        'storage': {
          'encryption': {
            'enabled': true,
            'type': 'luks2',
            'passphrase': 'luks-passphrase',
          },
        },
      });

      final errors = profile.validate();

      expect(profile.encryption.enabled, true);
      expect(profile.encryption.type, 'luks2');
      expect(profile.toStateMap()['encryptionPassphrase'], 'luks-passphrase');
      expect(
        errors,
        contains(
          'LUKS stage desteği henüz tamamlanmadı; şifreli profil güvenli şekilde durduruldu.',
        ),
      );
    });

    test('LUKS passphrase JSON export içine yazılmaz', () {
      final profile = InstallProfile.fromJson({
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'full',
        'username': 'tester',
        'password': 'secure123',
        'storage': {
          'encryption': {
            'enabled': true,
            'type': 'luks2',
            'passphrase': 'very-secret-passphrase',
          },
        },
      });

      expect(profile.toJson().toString(), isNot(contains('very-secret')));
    });
  });
}
