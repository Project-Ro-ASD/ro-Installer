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
          'encryption': {
            'enabled': false,
            'type': 'none',
          },
        },
      });

      expect(profile.validate(), isEmpty);
      expect(profile.schemaVersion, 1);
      expect(profile.encryption.enabled, false);
      expect(profile.toStateMap()['encryptionEnabled'], false);
      expect(profile.toStateMap()['encryptionType'], 'none');
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
