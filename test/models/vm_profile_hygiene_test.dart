import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/install_profile.dart';

void main() {
  test(
    'VM generated profile drops secrets and preserves fail-closed requests',
    () async {
      final shell = File('test_qemu_vm.sh').readAsStringSync();
      final python = shell
          .split('prepare_vm_profile() {')
          .last
          .split("python3 - <<'PY'\n")
          .last
          .split('\nPY\n')
          .first;
      final directory = Directory.systemTemp.createTempSync('pr05-vm-profile-');
      addTearDown(() => directory.deleteSync(recursive: true));
      for (final options in [
        {'confirmDestructive': true},
        {},
        {'confirmDestructive': false},
        {'confirmDestructive': false, 'confirm_destructive': true},
        {'confirmDestructive': true, 'partitionMethod': 'manual'},
        {'confirmDestructive': true, 'encryptionEnabled': true},
        {
          'confirmDestructive': true,
          'storage': {
            'encryption': {'enabled': true, 'passphrase': 'private-secret'},
          },
        },
        {
          'confirmDestructive': true,
          'storage': {
            'encryption': {'enabled': false},
          },
          'encryptionEnabled': true,
        },
      ]) {
        final input = {
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
          'selectedLanguage': 'tr',
          'username': 'old-user',
          'password': 'private-secret',
          'encryptionPassphrase': 'private-secret',
          ...options,
        };
        final source = File('${directory.path}/source.json')
          ..writeAsStringSync(jsonEncode(input));
        final target = File('${directory.path}/out.json');
        final result = await Process.run(
          'python3',
          ['-c', python],
          environment: {
            'VM_PROFILE_SOURCE': source.path,
            'VM_PROFILE_TARGET': target.path,
            'VM_GUEST_DISK': '/dev/vda',
          },
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final output =
            jsonDecode(target.readAsStringSync()) as Map<String, dynamic>;
        final expected = InstallProfile.fromJson({
          ...input,
          'selectedDisk': '/dev/vda',
        });
        expect(output, expected.toJson());
        expect(target.readAsStringSync(), isNot(contains('private-secret')));
        expect(target.readAsStringSync(), isNot(contains('old-user')));
        expect(InstallProfile.fromJson(output).validate(), expected.validate());
      }
    },
  );
}
