import 'package:test/test.dart';
import 'package:ro_installer/models/installer_handoff.dart';

void main() {
  test('v1 hint and layout metadata are accepted', () {
    expect(
      isValidInstallerHandoff(installerSeed('tr'), installMetadata()),
      isTrue,
    );
  });
  for (final key in [
    'username',
    'full_name',
    'password',
    'password_hash',
    'isAdministrator',
    'wifi',
    'timezone',
    'locale',
    'keyboard',
    'hostname',
    'kernel_channel',
    'repository',
    'passphrase',
  ]) {
    test('seed and metadata reject extra $key fields', () {
      expect(
        isValidInstallerHandoff({
          ...installerSeed('tr'),
          key: 'value',
        }, installMetadata()),
        isFalse,
      );
      expect(
        isValidInstallerHandoff(installerSeed('tr'), {
          ...installMetadata(),
          key: 'value',
        }),
        isFalse,
      );
    });
  }
  for (final key in [
    'schema_version',
    'layout_schema_version',
    'install_mode',
    'filesystem',
    'subvolumes',
  ]) {
    test('metadata requires canonical $key', () {
      final missing = installMetadata()..remove(key);
      expect(isValidInstallerHandoff(installerSeed('tr'), missing), isFalse);
      expect(
        isValidInstallerHandoff(installerSeed('tr'), {
          ...installMetadata(),
          key: 'wrong',
        }),
        isFalse,
      );
    });
  }
  test('seed schema and nonempty language are required', () {
    expect(
      isValidInstallerHandoff({
        'schema_version': 2,
        'installer_ui_language_hint': 'tr',
      }, installMetadata()),
      isFalse,
    );
    expect(
      isValidInstallerHandoff(installerSeed(''), installMetadata()),
      isFalse,
    );
    expect(
      isValidInstallerHandoff({'schema_version': 1}, installMetadata()),
      isFalse,
    );
  });
  test('old, missing, nested and reordered subvolume layouts are rejected', () {
    for (final names in [
      ['@', '@home'],
      ['root', 'home', 'var_log', 'var_cache'],
      ['root', 'home', 'var_log', 'var_cache', 'root/var_tmp'],
      ['home', 'root', 'var_log', 'var_cache', 'var_tmp'],
    ]) {
      expect(
        isValidInstallerHandoff(installerSeed('tr'), {
          ...installMetadata(),
          'subvolumes': names,
        }),
        isFalse,
      );
    }
  });
}
