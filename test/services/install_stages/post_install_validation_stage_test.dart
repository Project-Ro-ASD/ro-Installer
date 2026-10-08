import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ro_installer/models/installer_handoff.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/post_install_validation_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

const rootUuid = '11111111-2222-3333-4444-555555555555';
const efiUuid = 'ABCD-1234';
const fedoraBlsVersion = '7.2.8-200.fc44.x86_64';
const fedoraBlsEntry = 'boot/loader/entries/arbitrary-$fedoraBlsVersion.conf';
const cleanupPaths = [
  '/usr/bin/ro-installer',
  '/usr/bin/ro_installer',
  '/usr/libexec/ro-installer-launcher.sh',
  '/usr/libexec/ro-installer-helper',
  '/usr/libexec/ro-installer-backend',
  '/usr/lib64/ro-installer',
  '/usr/lib/ro-installer',
  '/usr/share/applications/ro-installer.desktop',
  '/usr/share/polkit-1/actions/org.roasd.installer.helper.policy',
  '/usr/share/polkit-1/actions/org.roasd.installer.policy',
  '/etc/polkit-1/rules.d/49-ro-installer-live.rules',
  '/etc/sudoers.d/ro-installer-live',
];
const noLiveUser =
    r'status=0; getent passwd liveuser >/dev/null || status=$?; [ "$status" -eq 2 ]';

StageContext context(
  FakeCommandRunner runner, {
  Map<String, dynamic>? state,
  List<String>? logs,
}) {
  return StageContext(
    state: state ?? {},
    commandRunner: runner,
    log: (message) => logs?.add(message),
    onProgress: (_, _) {},
    runCmd:
        (
          cmd,
          args,
          log, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async {
          final result = await runner.run(cmd, args);
          return result.started && allowedExitCodes.contains(result.exitCode);
        },
  );
}

FakeCommandRunner healthyRunner({FakeCommandRunner? runner}) {
  final fake = runner ?? FakeCommandRunner(defaultSuccess: false);
  fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
  fake.addResponse('cat', [
    '/mnt$installerSeedPath',
  ], stdout: jsonEncode(installerSeed('tr')));
  fake.addResponse('cat', [
    '/mnt$installMetadataPath',
  ], stdout: jsonEncode(installMetadata()));
  fake.addResponse('sh', ['-c', postInstallMachineIdentityValidationScript]);
  fake.addResponse('chroot', [
    '/mnt',
    'sh',
    '-c',
    postInstallInstallerRemovalValidationScript,
  ]);
  for (final path in cleanupPaths) {
    fake.addResponse('test', ['!', '-e', '/mnt$path']);
    fake.addResponse('test', ['!', '-L', '/mnt$path']);
  }
  fake.addResponse('chroot', ['/mnt', 'sh', '-c', noLiveUser]);
  fake.addResponse('sh', ['-c', postInstallNoLiveUserSddmValidationScript]);
  fake.addResponse('chroot', [
    '/mnt',
    'bash',
    '-c',
    postInstallPlasmaLauncherValidationScript,
  ]);
  fake.addResponse('findmnt', ['--verify', '--tab-file', '/mnt/etc/fstab']);
  fake.addResponse('findmnt', [
    '-rn',
    '-o',
    'UUID',
    '--mountpoint',
    '/mnt',
  ], stdout: rootUuid);
  fake.addResponse('findmnt', [
    '-rn',
    '-o',
    'UUID',
    '--mountpoint',
    '/mnt/boot/efi',
  ], stdout: efiUuid);
  fake.addResponse('sh', [
    '-c',
    postInstallStandardStorageValidationScript,
    'storage-validation',
    rootUuid,
    efiUuid,
  ]);
  fake.addResponse('chroot', [
    '/mnt',
    'sh',
    '-c',
    postInstallKernelImageValidationScript,
  ]);
  fake.addResponse('chroot', [
    '/mnt',
    'sh',
    '-c',
    postInstallBlsValidationScript,
    'bls-validation',
    rootUuid,
  ]);
  fake.addResponse('sh', ['-c', postInstallNoGpuDebugArgsValidationScript]);
  for (final binary in ['shimx64.efi', 'grubx64.efi']) {
    fake.addResponse('test', ['-s', '/mnt/boot/efi/EFI/fedora/$binary']);
  }
  fake.addResponse('sh', [
    '-c',
    postInstallGrubStubValidationScript,
    'grub-validation',
    rootUuid,
  ]);
  return fake;
}

/// Execute the production validators in a temporary filesystem. Target paths
/// are redirected; findmnt and RPM are fixture executables with real exit codes.
class TechnicalTarget {
  final Directory root = Directory.systemTemp.createTempSync('pr07-target-');
  TechnicalTarget() {
    for (final path in [
      'usr/lib/modules',
      'boot/loader/entries',
      'boot/grub2',
      'boot/efi/EFI/fedora',
      'etc/kernel',
      'var/lib/dbus',
      'bin',
    ]) {
      Directory('${root.path}/$path').createSync(recursive: true);
    }
    Link('${root.path}/lib').createSync('usr/lib');
    write('etc/machine-id', '1234567890abcdef1234567890abcdef\n');
    Link('${root.path}/var/lib/dbus/machine-id').createSync('/etc/machine-id');
    write('live-machine-id', 'abcdef1234567890abcdef123456789012\n');
    write(
      'etc/kernel/cmdline',
      'root=UUID=$rootUuid ro rootflags=subvol=root rhgb quiet\n',
    );
    write(
      'etc/fstab',
      [
        for (final entry in layout.entries)
          'UUID=$rootUuid ${entry.value} btrfs defaults,subvol=${entry.key} 0 0',
        'UUID=$efiUuid /boot/efi vfat defaults 0 2',
        '',
      ].join('\n'),
    );
    write(
      'mounts',
      [
        for (final entry in layout.entries)
          '${root.path}${entry.value == '/' ? '' : entry.value}\tbtrfs\t$rootUuid\t/${entry.key}',
        '${root.path}/boot/efi\tvfat\t$efiUuid\t/',
        '',
      ].join('\n'),
    );
    write('boot/grub2/grub.cfg', 'generated grub config\n');
    write(
      'boot/efi/EFI/fedora/grub.cfg',
      'search --no-floppy --fs-uuid --set=dev $rootUuid\n'
          r'set prefix=($dev)/root/boot/grub2'
          '\n'
          r'configfile $prefix/grub.cfg'
          '\n',
    );
    executable('findmnt', r'''
last=""
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; output="$1"; fi
  last="$1"
  shift
done
[ "$FINDMNT_ERROR" != 1 ] || exit 2
awk -F '\t' -v point="$last" -v output="$output" '
  $1 == point {
    found=1
    if (output == "FSTYPE,UUID") print $2, $3
    else print $2, $3, $4
  }
  END { exit !found }
' "$MOUNT_TABLE"
''');
    executable('rpm', r'''
if [ "$1" = -qa ]; then
  [ "$RPM_MODE" != db-error ] || { echo "cannot read RPM DB" >&2; exit 1; }
  [ "$RPM_MODE" != inventory-installed ] || echo ro-installer
  exit 0
fi
case "$RPM_MODE" in
  installed) echo ro-installer-1.0; exit 0 ;;
  query-error) echo "cannot open RPM DB" >&2; exit 1 ;;
  command-error) exit 127 ;;
  empty-error) exit 1 ;;
  *) echo "package ro-installer is not installed"; exit 1 ;;
esac
''');
  }
  static const layout = {
    'root': '/',
    'home': '/home',
    'var_log': '/var/log',
    'var_cache': '/var/cache',
    'var_tmp': '/var/tmp',
  };
  File file(String path) => File('${root.path}/$path');
  void write(String path, String value) => file(path).writeAsStringSync(value);
  void replace(String path, String from, String to) =>
      write(path, file(path).readAsStringSync().replaceAll(from, to));
  void executable(String name, String script) {
    write('bin/$name', '#!/bin/sh\n$script');
    expect(
      Process.runSync('chmod', ['+x', file('bin/$name').path]).exitCode,
      0,
    );
  }

  void kernel(String version) {
    Directory('${root.path}/usr/lib/modules/$version').createSync();
    write('boot/vmlinuz-$version', 'kernel-$version');
    write('boot/initramfs-$version.img', 'initramfs-$version');
    write(
      'boot/loader/entries/arbitrary-$version.conf',
      'title Prepared kernel\nversion $version\nlinux /vmlinuz-$version\n'
          'initrd /initramfs-$version.img\n'
          'options root=UUID=$rootUuid ro rootflags=subvol=root rhgb quiet\n',
    );
  }

  void fedoraBls() {
    kernel(fedoraBlsVersion);
    write(
      fedoraBlsEntry,
      'title Fedora Linux\n'
      'version $fedoraBlsVersion\n'
      'linux /root/boot/vmlinuz-$fedoraBlsVersion\n'
      'initrd /root/boot/initramfs-$fedoraBlsVersion.img '
      r'$tuned_initrd'
      '\noptions root=UUID=$rootUuid ro rootflags=subvol=root rhgb quiet\n',
    );
  }

  Future<ProcessResult> run(
    String script, {
    List<String> args = const [],
    Map<String, String> env = const {},
  }) {
    if (script == postInstallMachineIdentityValidationScript) {
      script = script
          .replaceAll(
            'if [ -r /etc/machine-id ]',
            'if [ -r "${root.path}/live-machine-id" ]',
          )
          .replaceAll(
            'cat /etc/machine-id',
            'cat "${root.path}/live-machine-id"',
          );
    }
    // These two awk literals are logical fstab mountpoints, not host paths.
    script = script
        .replaceAll('== "/boot/efi"', '== "__ESP_POINT__"')
        .replaceAll('== "/boot"', '== "__BOOT_POINT__"');
    final redirected = script.replaceAllMapped(
      RegExp(
        r'/mnt(?:/[A-Za-z0-9_./-]+)?|/usr/lib/modules|/lib/modules|(?<![A-Za-z0-9_./-])/boot|/etc/kernel/cmdline',
      ),
      (m) => m[0]!.startsWith('/mnt')
          ? '${root.path}${m[0]!.substring(4)}'
          : '${root.path}${m[0]}',
    );
    return Process.run(
      'sh',
      [
        '-c',
        redirected
            .replaceAll('__ESP_POINT__', '/boot/efi')
            .replaceAll('__BOOT_POINT__', '/boot'),
        'technical-validation',
        ...args,
      ],
      environment: {
        ...env,
        'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
        'MOUNT_TABLE': file('mounts').path,
      },
    );
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  group('Stage 8 technical orchestration', () {
    test('healthy target needs no Compose product policy', () async {
      final fake = healthyRunner();
      expect(
        (await const PostInstallValidationStage().execute(
          context(fake),
        )).success,
        true,
      );
      final commands = fake.commandLog.map((c) => c.commandLine).join('\n');
      for (final forbidden in [
        'ro-theme',
        'ro-assist',
        'ro-control',
        'ro-repo',
        'ro-kernel-stable',
        'ro-kernel-experimental',
        'https://',
        'RoDark',
        'os-release',
        'PRETTY_NAME',
        'dracut\ngrub2-efi',
        'subvol=@',
      ]) {
        expect(commands, isNot(contains(forbidden)));
      }
      expect(
        fake.commandNames.every(
          (name) => ['test', 'cat', 'sh', 'chroot', 'findmnt'].contains(name),
        ),
        true,
      );
    });
    for (final state in [
      {'partitionMethod': 'manual'},
      {'partitionMethod': 'alongside'},
      {'partitionMethod': 'free_space'},
      {'fileSystem': 'ext4'},
      {'fileSystem': 'xfs'},
    ]) {
      test('unsupported $state fails before commands', () async {
        final fake = FakeCommandRunner(defaultSuccess: false);
        expect(
          (await const PostInstallValidationStage().execute(
            context(fake, state: state),
          )).success,
          false,
        );
        expect(fake.commandLog, isEmpty);
      });
    }
    for (final path in cleanupPaths) {
      test('cleanup residue $path fails', () async {
        final fake = FakeCommandRunner();
        fake.addResponse('test', ['!', '-e', '/mnt$path'], exitCode: 1);
        fake.addResponse('cat', [
          '/mnt$installerSeedPath',
        ], stdout: jsonEncode(installerSeed('tr')));
        fake.addResponse('cat', [
          '/mnt$installMetadataPath',
        ], stdout: jsonEncode(installMetadata()));
        expect(
          (await const PostInstallValidationStage().execute(
            context(fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('findmnt'), false);
      });
    }
    for (final path in cleanupPaths) {
      test('dangling installer symlink $path fails validation', () async {
        final fake = FakeCommandRunner();
        fake.addResponse('test', ['!', '-L', '/mnt$path'], exitCode: 1);
        fake.addResponse('cat', [
          '/mnt$installerSeedPath',
        ], stdout: jsonEncode(installerSeed('tr')));
        fake.addResponse('cat', [
          '/mnt$installMetadataPath',
        ], stdout: jsonEncode(installMetadata()));
        expect(
          (await const PostInstallValidationStage().execute(
            context(fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('findmnt'), false);
      });
    }
    for (final entry in [
      ['chroot', '/mnt', 'sh', '-c', noLiveUser],
      ['sh', '-c', postInstallNoLiveUserSddmValidationScript],
      [
        'chroot',
        '/mnt',
        'bash',
        '-c',
        postInstallPlasmaLauncherValidationScript,
      ],
    ]) {
      test('live account/session/launcher failure stops validation', () async {
        final fake = FakeCommandRunner();
        fake.addResponse(entry.first, entry.skip(1).toList(), exitCode: 1);
        fake.addResponse('cat', [
          '/mnt$installerSeedPath',
        ], stdout: jsonEncode(installerSeed('tr')));
        fake.addResponse('cat', [
          '/mnt$installMetadataPath',
        ], stdout: jsonEncode(installMetadata()));
        expect(
          (await const PostInstallValidationStage().execute(
            context(fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('findmnt'), false);
      });
    }
    for (final path in [installerSeedPath, installMetadataPath]) {
      for (final missing in [true, false]) {
        test(
          'handoff $path missing=$missing fails without logging JSON',
          () async {
            final fake = FakeCommandRunner();
            const secret = '{"password":"private-example",broken';
            fake.addResponse(
              'cat',
              ['/mnt$installerSeedPath'],
              stdout: path == installerSeedPath
                  ? secret
                  : jsonEncode(installerSeed('tr')),
              exitCode: path == installerSeedPath && missing ? 1 : 0,
            );
            fake.addResponse(
              'cat',
              ['/mnt$installMetadataPath'],
              stdout: path == installMetadataPath
                  ? secret
                  : jsonEncode(installMetadata()),
              exitCode: path == installMetadataPath && missing ? 1 : 0,
            );
            final logs = <String>[];
            expect(
              (await const PostInstallValidationStage().execute(
                context(fake, logs: logs),
              )).success,
              false,
            );
            expect(logs.join(), isNot(contains('private-example')));
          },
        );
      }
    }
    for (final bad in [
      {'schema_version': 2, 'installer_ui_language_hint': 'tr'},
      {...installerSeed('tr'), 'password': 'private-example'},
      {...installerSeed('tr'), 'username': 'identity-example'},
    ]) {
      test('seed allowlist/schema rejects $bad', () async {
        final fake = FakeCommandRunner();
        fake.addResponse('cat', [
          '/mnt$installerSeedPath',
        ], stdout: jsonEncode(bad));
        fake.addResponse('cat', [
          '/mnt$installMetadataPath',
        ], stdout: jsonEncode(installMetadata()));
        expect(
          (await const PostInstallValidationStage().execute(
            context(fake),
          )).success,
          false,
        );
      });
    }
    for (final bad in [
      {...installMetadata(), 'layout_schema_version': 2},
      {...installMetadata(), 'hostname': 'identity-example'},
      {
        ...installMetadata(),
        'subvolumes': ['root', 'home'],
      },
    ]) {
      test('metadata allowlist/layout rejects $bad', () async {
        final fake = FakeCommandRunner();
        fake.addResponse('cat', [
          '/mnt$installerSeedPath',
        ], stdout: jsonEncode(installerSeed('tr')));
        fake.addResponse('cat', [
          '/mnt$installMetadataPath',
        ], stdout: jsonEncode(bad));
        expect(
          (await const PostInstallValidationStage().execute(
            context(fake),
          )).success,
          false,
        );
      });
    }
    for (final point in ['/mnt', '/mnt/boot/efi']) {
      test('UUID query failure $point fails closed', () async {
        final fake = FakeCommandRunner(defaultSuccess: false);
        fake.addResponse(
          'findmnt',
          ['-rn', '-o', 'UUID', '--mountpoint', point],
          exitCode: 127,
          started: false,
        );
        healthyRunner(runner: fake);
        final result = await const PostInstallValidationStage().execute(
          context(fake),
        );
        expect(result.success, false);
        expect(
          result.message,
          contains(point == '/mnt' ? 'Root UUID' : 'EFI UUID'),
        );
      });
    }
    for (final entry in [
      ['sh', '-c', postInstallMachineIdentityValidationScript],
      [
        'chroot',
        '/mnt',
        'sh',
        '-c',
        postInstallInstallerRemovalValidationScript,
      ],
      ['findmnt', '--verify', '--tab-file', '/mnt/etc/fstab'],
      [
        'sh',
        '-c',
        postInstallStandardStorageValidationScript,
        'storage-validation',
        rootUuid,
        efiUuid,
      ],
      ['chroot', '/mnt', 'sh', '-c', postInstallKernelImageValidationScript],
      [
        'chroot',
        '/mnt',
        'sh',
        '-c',
        postInstallBlsValidationScript,
        'bls-validation',
        rootUuid,
      ],
      ['sh', '-c', postInstallNoGpuDebugArgsValidationScript],
      ['test', '-s', '/mnt/boot/efi/EFI/fedora/shimx64.efi'],
      ['test', '-s', '/mnt/boot/efi/EFI/fedora/grubx64.efi'],
      [
        'sh',
        '-c',
        postInstallGrubStubValidationScript,
        'grub-validation',
        rootUuid,
      ],
      ['test', '!', '-L', '/mnt/usr/bin/ro-installer'],
    ].asMap().entries) {
      test(
        'technical failure ${entry.key} stops at first inconsistency',
        () async {
          final args = entry.value;
          final fake = FakeCommandRunner(defaultSuccess: false);
          fake.addResponse(args.first, args.skip(1).toList(), exitCode: 1);
          healthyRunner(runner: fake);
          expect(
            (await const PostInstallValidationStage().execute(
              context(fake),
            )).success,
            false,
          );
          expect(fake.commandLog.last.command, args.first);
          expect(fake.commandLog.last.args, args.skip(1).toList());
        },
      );
    }
  });

  group('filesystem technical validators', () {
    late TechnicalTarget target;
    setUp(() => target = TechnicalTarget());
    tearDown(() => target.dispose());
    test(
      'valid machine identity accepts absolute symlink, relative symlink and matching file',
      () async {
        expect(
          (await target.run(
            postInstallMachineIdentityValidationScript,
          )).exitCode,
          0,
        );
        final dbus = Link('${target.root.path}/var/lib/dbus/machine-id');
        dbus.deleteSync();
        dbus.createSync('../../../etc/machine-id');
        expect(
          (await target.run(
            postInstallMachineIdentityValidationScript,
          )).exitCode,
          0,
        );
        dbus.deleteSync();
        target.write(
          'var/lib/dbus/machine-id',
          target.file('etc/machine-id').readAsStringSync(),
        );
        expect(
          (await target.run(
            postInstallMachineIdentityValidationScript,
          )).exitCode,
          0,
        );
      },
    );
    for (final bad in [
      '',
      'uninitialized\n',
      '123abc\n',
      'z' * 32,
      '0' * 32,
      '1234567890abcdef1234567890abcdef\nextra',
    ]) {
      test(
        'invalid machine ID rejected without output: length ${bad.length}',
        () async {
          target.write('etc/machine-id', bad);
          final result = await target.run(
            postInstallMachineIdentityValidationScript,
          );
          expect(result.exitCode, isNot(0));
          expect(result.stdout, isEmpty);
        },
      );
    }
    test('missing machine-id rejected', () async {
      target.file('etc/machine-id').deleteSync();
      expect(
        (await target.run(postInstallMachineIdentityValidationScript)).exitCode,
        isNot(0),
      );
    });
    test('copied live ID rejected', () async {
      target.write(
        'etc/machine-id',
        target.file('live-machine-id').readAsStringSync(),
      );
      expect(
        (await target.run(postInstallMachineIdentityValidationScript)).exitCode,
        isNot(0),
      );
    });
    test('incoherent or missing D-Bus ID rejected', () async {
      Link('${target.root.path}/var/lib/dbus/machine-id').deleteSync();
      expect(
        (await target.run(postInstallMachineIdentityValidationScript)).exitCode,
        isNot(0),
      );
      target.write('var/lib/dbus/machine-id', 'different');
      expect(
        (await target.run(postInstallMachineIdentityValidationScript)).exitCode,
        isNot(0),
      );
    });
    test('wrong D-Bus symlink rejected', () async {
      final link = Link('${target.root.path}/var/lib/dbus/machine-id');
      link.deleteSync();
      link.createSync('/wrong/machine-id');
      expect(
        (await target.run(postInstallMachineIdentityValidationScript)).exitCode,
        isNot(0),
      );
    });
    test('normal RPM absence status 1 passes', () async {
      expect(
        (await target.run(
          postInstallInstallerRemovalValidationScript,
        )).exitCode,
        0,
      );
    });
    for (final mode in [
      'installed',
      'inventory-installed',
      'db-error',
      'query-error',
      'command-error',
      'empty-error',
    ]) {
      test('RPM $mode fails closed', () async {
        expect(
          (await target.run(
            postInstallInstallerRemovalValidationScript,
            env: {'RPM_MODE': mode},
          )).exitCode,
          isNot(0),
        );
      });
    }
    test('five mounts and ESP validate', () async {
      expect(
        (await target.run(
          postInstallStandardStorageValidationScript,
          args: [rootUuid, efiUuid],
        )).exitCode,
        0,
      );
    });
    final storageCases = <String, void Function(TechnicalTarget)>{
      'wrong subvolume': (t) => t.replace('mounts', '/var_log', '/wrong'),
      'wrong root UUID': (t) => t.replace('mounts', rootUuid, 'wrong-uuid'),
      'wrong root filesystem': (t) => t.replace('mounts', 'btrfs', 'ext4'),
      'wrong root FSROOT': (t) => t.replace('mounts', '/root', '/wrong'),
      'wrong fstab UUID': (t) => t.replace('etc/fstab', rootUuid, 'wrong-uuid'),
      'wrong fstab subvolume': (t) =>
          t.replace('etc/fstab', 'subvol=var_cache', 'subvol=wrong'),
      'disk swap': (t) => t.write(
        'etc/fstab',
        '${t.file('etc/fstab').readAsStringSync()}UUID=swap none swap defaults 0 0\n',
      ),
      'separate boot mount': (t) => t.write(
        'mounts',
        '${t.file('mounts').readAsStringSync()}${t.root.path}/boot\text4\tboot-uuid\t/\n',
      ),
      'separate boot fstab': (t) => t.write(
        'etc/fstab',
        '${t.file('etc/fstab').readAsStringSync()}UUID=boot /boot ext4 defaults 0 0\n',
      ),
      'missing ESP': (t) => t.write(
        'mounts',
        t
            .file('mounts')
            .readAsLinesSync()
            .where((l) => !l.contains('/boot/efi'))
            .join('\n'),
      ),
      'wrong ESP UUID': (t) => t.replace('mounts', efiUuid, 'wrong-efi'),
      'wrong ESP type': (t) => t.replace('mounts', 'vfat', 'ext4'),
      'wrong ESP fstab UUID': (t) =>
          t.replace('etc/fstab', efiUuid, 'wrong-efi'),
    };
    for (final entry in storageCases.entries) {
      test('storage rejects ${entry.key}', () async {
        entry.value(target);
        expect(
          (await target.run(
            postInstallStandardStorageValidationScript,
            args: [rootUuid, efiUuid],
          )).exitCode,
          isNot(0),
        );
      });
    }
    test(
      'mount tool error is not mistaken for absence of separate boot',
      () async {
        expect(
          (await target.run(
            postInstallStandardStorageValidationScript,
            args: [rootUuid, efiUuid],
            env: {'FINDMNT_ERROR': '1'},
          )).exitCode,
          isNot(0),
        );
      },
    );
    for (final version in [
      '6.x.y-custom',
      '6.17.1-300.fc43.x86_64',
      '6.17.1-ro_stable',
    ]) {
      test('kernel/BLS package-neutral acceptance $version', () async {
        target.kernel(version);
        expect(
          (await target.run(postInstallKernelImageValidationScript)).exitCode,
          0,
        );
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          0,
        );
      });
    }
    test(
      'real Fedora 44 Btrfs BLS with optional tuned initrd passes',
      () async {
        target.fedoraBls();
        final result = await target.run(
          postInstallBlsValidationScript,
          args: [rootUuid],
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
      },
    );
    test(
      'Fedora Btrfs BLS concrete initramfs without tuned token passes',
      () async {
        target.fedoraBls();
        target.replace(fedoraBlsEntry, r' $tuned_initrd', '');
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          0,
        );
      },
    );
    test('BLS accepts directly existing installed-root artifacts', () async {
      target.fedoraBls();
      for (final name in [
        'vmlinuz-$fedoraBlsVersion',
        'initramfs-$fedoraBlsVersion.img',
      ]) {
        target.replace(
          fedoraBlsEntry,
          '/root/boot/$name',
          target.file('boot/$name').path,
        );
      }
      expect(
        (await target.run(
          postInstallBlsValidationScript,
          args: [rootUuid],
        )).exitCode,
        0,
      );
    });
    for (final change in {
      'wrong version': ['version $fedoraBlsVersion', 'version wrong-version'],
      'kernel file mismatch': [
        '/root/boot/vmlinuz-$fedoraBlsVersion',
        '/root/boot/wrong-kernel',
      ],
      'wrong concrete initramfs': [
        '/root/boot/initramfs-$fedoraBlsVersion.img',
        '/root/boot/initramfs-wrong.img',
      ],
      'missing BLS initrd': [
        'initrd /root/boot/initramfs-$fedoraBlsVersion.img '
            r'$tuned_initrd',
        '',
      ],
      'only tuned token': ['/root/boot/initramfs-$fedoraBlsVersion.img ', ''],
      'unknown symbolic token': [r'$tuned_initrd', r'$anything'],
      'unknown braced symbolic token': [r'$tuned_initrd', r'${tuned_initrd}'],
      'unresolved additional concrete initrd': [
        r'$tuned_initrd',
        '/root/boot/missing-initrd',
      ],
      'wrong root UUID': ['root=UUID=$rootUuid', 'root=UUID=wrong'],
      'missing rootflags': ['rootflags=subvol=root', ''],
      'live image': ['rhgb quiet', 'rhgb quiet rd.live.image'],
      'live installer stage': ['rhgb quiet', 'rhgb quiet inst.stage2=live'],
      'live CD label': ['rhgb quiet', 'rhgb quiet CDLABEL=live'],
    }.entries) {
      test('real Fedora BLS rejects ${change.key}', () async {
        target.fedoraBls();
        target.write('boot/wrong-kernel', 'wrong kernel bytes');
        target.write('boot/initramfs-wrong.img', 'wrong initramfs bytes');
        target.replace(fedoraBlsEntry, change.value[0], change.value[1]);
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          isNot(0),
        );
      });
    }
    test('real Fedora BLS missing concrete initramfs file fails', () async {
      target.fedoraBls();
      target.file('boot/initramfs-$fedoraBlsVersion.img').deleteSync();
      expect(
        (await target.run(
          postInstallBlsValidationScript,
          args: [rootUuid],
        )).exitCode,
        isNot(0),
      );
    });
    for (final name in [
      'vmlinuz-$fedoraBlsVersion',
      'initramfs-$fedoraBlsVersion.img',
    ]) {
      for (final prefix in [
        '/root/boot/./',
        '/root/boot/../boot/',
        '/root/boot//',
      ]) {
        test('real Fedora BLS rejects unsafe path $prefix$name', () async {
          target.fedoraBls();
          target.replace(fedoraBlsEntry, '/root/boot/$name', '$prefix$name');
          expect(
            (await target.run(
              postInstallBlsValidationScript,
              args: [rootUuid],
            )).exitCode,
            isNot(0),
          );
        });
      }
      test(
        'real Fedora BLS rejects unsupported /root prefix for $name',
        () async {
          target.fedoraBls();
          Directory('${target.root.path}/boot/token').createSync();
          target
              .file('boot/$name')
              .copySync('${target.root.path}/boot/token/$name');
          target.replace(
            fedoraBlsEntry,
            '/root/boot/$name',
            '/root/token/$name',
          );
          expect(
            (await target.run(
              postInstallBlsValidationScript,
              args: [rootUuid],
            )).exitCode,
            isNot(0),
          );
        },
      );
    }
    test(
      'BLS filename and copied artifact names are package-neutral',
      () async {
        target.kernel('6.1-custom');
        Directory(
          '${target.root.path}/boot/token/6.1-custom',
        ).createSync(recursive: true);
        target
            .file('boot/vmlinuz-6.1-custom')
            .copySync('${target.root.path}/boot/token/6.1-custom/linux');
        target
            .file('boot/initramfs-6.1-custom.img')
            .copySync('${target.root.path}/boot/token/6.1-custom/initrd');
        target.replace(
          'boot/loader/entries/arbitrary-6.1-custom.conf',
          '/vmlinuz-6.1-custom',
          '/token/6.1-custom/linux',
        );
        target.replace(
          'boot/loader/entries/arbitrary-6.1-custom.conf',
          '/initramfs-6.1-custom.img',
          '/token/6.1-custom/initrd',
        );
        target
            .file('boot/loader/entries/arbitrary-6.1-custom.conf')
            .renameSync(
              '${target.root.path}/boot/loader/entries/opaque-entry.conf',
            );
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          0,
        );
        target.write('boot/token/6.1-custom/linux', 'different kernel');
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          isNot(0),
        );
      },
    );
    test('additional conflicting GRUB prefix rejected', () async {
      target.write(
        'boot/efi/EFI/fedora/grub.cfg',
        '${target.file('boot/efi/EFI/fedora/grub.cfg').readAsStringSync()}set prefix=(\$dev)/wrong\n',
      );
      expect(
        (await target.run(
          postInstallGrubStubValidationScript,
          args: [rootUuid],
        )).exitCode,
        isNot(0),
      );
    });
    test('no kernel candidate fails', () async {
      expect(
        (await target.run(postInstallKernelImageValidationScript)).exitCode,
        isNot(0),
      );
      expect(
        (await target.run(
          postInstallBlsValidationScript,
          args: [rootUuid],
        )).exitCode,
        isNot(0),
      );
    });
    test('missing/empty matching initramfs fails', () async {
      target.kernel('6.1-custom');
      target.file('boot/initramfs-6.1-custom.img').deleteSync();
      expect(
        (await target.run(postInstallKernelImageValidationScript)).exitCode,
        isNot(0),
      );
      target.write('boot/initramfs-6.1-custom.img', '');
      expect(
        (await target.run(postInstallKernelImageValidationScript)).exitCode,
        isNot(0),
      );
    });
    test('every kernel requires its own BLS entry', () async {
      target.kernel('6.1-custom');
      target.kernel('6.2-custom');
      expect(
        (await target.run(
          postInstallBlsValidationScript,
          args: [rootUuid],
        )).exitCode,
        0,
      );
      target.file('boot/loader/entries/arbitrary-6.2-custom.conf').deleteSync();
      expect(
        (await target.run(
          postInstallBlsValidationScript,
          args: [rootUuid],
        )).exitCode,
        isNot(0),
      );
    });
    for (final change in {
      'wrong UUID': ['root=UUID=$rootUuid', 'root=UUID=wrong'],
      'missing rootflags': ['rootflags=subvol=root', ''],
      'old rootflags': ['rootflags=subvol=root', 'rootflags=subvol=@'],
      'wrong initramfs': ['/initramfs-6.1-custom.img', '/initramfs-wrong.img'],
      'missing initramfs': ['initrd /initramfs-6.1-custom.img', ''],
      'wrong version': ['version 6.1-custom', 'version 6.2-wrong'],
      'missing linux': ['linux /vmlinuz-6.1-custom', ''],
      'resume': ['rhgb quiet', 'rhgb quiet resume=UUID=swap'],
      'live': ['rhgb quiet', 'rhgb quiet rd.live.image'],
    }.entries) {
      test('BLS rejects ${change.key}', () async {
        target.kernel('6.1-custom');
        target.replace(
          'boot/loader/entries/arbitrary-6.1-custom.conf',
          change.value[0],
          change.value[1],
        );
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          isNot(0),
        );
      });
    }
    for (final arg in [
      'resume=UUID=swap',
      'rootflags=subvol=@',
      'rd.live.image',
      'inst.stage2=x',
      'CDLABEL=x',
      'root=live:x',
    ]) {
      test('cmdline rejects $arg', () async {
        target.kernel('6.1-custom');
        target.write(
          'etc/kernel/cmdline',
          '${target.file('etc/kernel/cmdline').readAsStringSync().trim()} $arg\n',
        );
        expect(
          (await target.run(
            postInstallBlsValidationScript,
            args: [rootUuid],
          )).exitCode,
          isNot(0),
        );
      });
    }
    test('GRUB exact root prefix and redirect pass', () async {
      expect(
        (await target.run(
          postInstallGrubStubValidationScript,
          args: [rootUuid],
        )).exitCode,
        0,
      );
    });
    for (final change in {
      'wrong UUID': [rootUuid, 'wrong-uuid'],
      'old prefix': ['/root/boot/grub2', '/@/boot/grub2'],
      'wrong prefix': ['/root/boot/grub2', '/boot/grub2'],
      'missing redirect': [r'configfile $prefix/grub.cfg', ''],
    }.entries) {
      test('GRUB rejects ${change.key}', () async {
        target.replace(
          'boot/efi/EFI/fedora/grub.cfg',
          change.value[0],
          change.value[1],
        );
        expect(
          (await target.run(
            postInstallGrubStubValidationScript,
            args: [rootUuid],
          )).exitCode,
          isNot(0),
        );
      });
    }
    test(
      'missing optional SDDM state passes, liveuser residue fails',
      () async {
        expect(
          (await target.run(
            postInstallNoLiveUserSddmValidationScript,
          )).exitCode,
          0,
        );
        target.write('etc/sddm.conf', '[Autologin]\nUser=liveuser\n');
        expect(
          (await target.run(
            postInstallNoLiveUserSddmValidationScript,
          )).exitCode,
          isNot(0),
        );
      },
    );
    test('unreadable GPU scan inputs fail closed', () async {
      target.file('etc/kernel/cmdline').deleteSync();
      expect(
        (await target.run(postInstallNoGpuDebugArgsValidationScript)).exitCode,
        isNot(0),
      );
    });
    test('live/debug GPU arguments still rejected', () async {
      target.kernel('6.1-custom');
      target.replace('etc/kernel/cmdline', 'quiet', 'quiet nomodeset');
      expect(
        (await target.run(postInstallNoGpuDebugArgsValidationScript)).exitCode,
        isNot(0),
      );
    });
  });
}
