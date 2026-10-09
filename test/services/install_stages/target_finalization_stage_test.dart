import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/installer_handoff.dart';
import 'package:ro_installer/models/standard_storage_layout.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/install_stages/target_finalization_stage.dart';

class RecordingWriter extends FakeCommandRunner {
  RecordingWriter({this.cleanupFixture});

  final LiveCleanupFixture? cleanupFixture;
  final writes = <String, String>{};
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    if (stdinText != null) writes[args.last] = stdinText;
    final recorded = await super.run(
      command,
      args,
      isMock: isMock,
      onLog: onLog,
      timeout: timeout,
      stdinText: stdinText,
    );
    if (cleanupFixture != null &&
        command == 'chroot' &&
        args.length == 4 &&
        args[0] == '/mnt' &&
        args[1] == 'sh' &&
        args[2] == '-c' &&
        args[3] == targetLiveCleanupScript) {
      final result = await cleanupFixture!.run(args[3]);
      return CommandResult(
        command: command,
        args: args,
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
        started: true,
      );
    }
    return recorded;
  }
}

/// Run the production cleanup with only target paths redirected. System/account
/// tools are stubs; sh, awk, sed and filesystem mutations execute for real.
class LiveCleanupFixture {
  final Directory root = Directory.systemTemp.createTempSync('pr-a4-target-');

  LiveCleanupFixture() {
    for (final entry in {
      'systemctl': 'exit 0',
      'rpm': 'exit 1',
      'getent': 'exit 1',
      'userdel': 'exit 99',
    }.entries) {
      write('bin/${entry.key}', '#!/bin/sh\n${entry.value}\n');
      expect(
        Process.runSync('chmod', [
          '+x',
          file('bin/${entry.key}').path,
        ]).exitCode,
        0,
      );
    }
  }

  File file(String path) => File('${root.path}/$path');

  void write(String path, String content) {
    file(path).parent.createSync(recursive: true);
    file(path).writeAsStringSync(content);
  }

  Future<ProcessResult> run(String script) => Process.run(
    'sh',
    [
      '-c',
      script.replaceAllMapped(
        RegExp(r'/(?:etc|usr|var)/'),
        (match) => '${root.path}${match[0]}',
      ),
    ],
    environment: {'PATH': '${root.path}/bin:/usr/bin:/bin'},
  );
}

StageContext context(
  RecordingWriter runner, {
  String disk = '/dev/vda',
  String language = 'tr',
  bool smoke = false,
}) {
  runner.addResponse('blkid', [
    '-s',
    'UUID',
    '-o',
    'value',
    '$disk${disk.contains('nvme') || disk.contains('mmcblk') ? 'p' : ''}2',
  ], stdout: 'root-uuid');
  runner.addResponse('blkid', [
    '-s',
    'UUID',
    '-o',
    'value',
    '$disk${disk.contains('nvme') || disk.contains('mmcblk') ? 'p' : ''}1',
  ], stdout: 'esp-uuid');
  return StageContext(
    state: {
      'selectedDisk': disk,
      'partitionMethod': 'full',
      'fileSystem': 'btrfs',
      'selectedLanguage': language,
      'vmTestMode': smoke,
    },
    commandRunner: runner,
    log: (_) {},
    onProgress: (_, _) {},
    runCmd:
        (
          cmd,
          args,
          log, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async {
          final result = await runner.run(cmd, args, isMock: isMock);
          return result.started && allowedExitCodes.contains(result.exitCode);
        },
  );
}

void main() {
  const rpmQuery = ['/mnt', 'rpm', '-qa', '--qf', '%{NAME}\n'];
  group('Plasma Setup target cleanup fixtures', () {
    late LiveCleanupFixture target;
    late RecordingWriter runner;
    const override = '[Autologin]\nUser=plasma-setup\nSession=plasma\n';
    const overridePath = 'etc/plasmalogin.conf.d/99-plasma-setup.conf';

    setUp(() {
      target = LiveCleanupFixture();
      runner = RecordingWriter(cleanupFixture: target);
      target.write(overridePath, override);
    });
    tearDown(() => target.root.deleteSync(recursive: true));

    Future<void> finalize() async {
      final result = await const TargetFinalizationStage().execute(
        context(runner),
      );
      final cleanupCalls = runner.commandLog.where(
        (c) => c.command == 'chroot' && c.args.last == targetLiveCleanupScript,
      );
      expect(result.success, isTrue, reason: result.message);
      expect(cleanupCalls, isNotEmpty);
      expect(target.file(overridePath).readAsStringSync(), override);
      expect(target.file('etc/plasma-setup-done').existsSync(), isFalse);
    }

    test(
      'clears copied OOBE and Live PLM state, retaining SDDM cleanup',
      () async {
        target.write('etc/plasma-setup-done', 'copied Live completion\n');
        const before = '''# Composed login configuration
[General]
User=liveuser
Session=keep-general
DisplayServer=wayland
[Autologin]
Session=plasma.desktop
User=liveuser
Relogin=false
[Theme]
Current=ro-asd
User=liveuser
Session=keep-theme
[Autologin][Other]
User=liveuser
Session=keep-nested-group
''';
        const after = '''# Composed login configuration
[General]
User=liveuser
Session=keep-general
DisplayServer=wayland
[Autologin]
Relogin=false
[Theme]
Current=ro-asd
User=liveuser
Session=keep-theme
[Autologin][Other]
User=liveuser
Session=keep-nested-group
''';
        target.write('etc/plasmalogin.conf', before);
        target.write(
          'etc/sddm.conf',
          '[Autologin]\nUser=liveuser\nSession=plasma.desktop\n[Theme]\nCurrent=ro\n',
        );
        target.write(
          'etc/sddm.conf.d/20-autologin.conf',
          '[Autologin]\nUser=liveuser\nSession=plasma\n',
        );
        const unrelatedSddm = '[Autologin]\nUser=alice\nSession=plasma\n';
        target.write('etc/sddm.conf.d/30-other.conf', unrelatedSddm);
        for (final path in [
          'var/lib/sddm/state.conf',
          'var/lib/sddm/.cache/copied',
          'var/lib/sddm/.config/copied',
          'var/lib/sddm/.local/copied',
        ]) {
          target.write(path, 'Live state');
        }

        for (var pass = 0; pass < 2; pass++) {
          await finalize();
          expect(target.file('etc/plasmalogin.conf').readAsStringSync(), after);
          expect(
            target.file('etc/sddm.conf').readAsStringSync(),
            '[Autologin]\nSession=plasma.desktop\n[Theme]\nCurrent=ro\n',
          );
          expect(
            target.file('etc/sddm.conf.d/20-autologin.conf').readAsStringSync(),
            '[Autologin]\nSession=plasma\n',
          );
          expect(
            target.file('etc/sddm.conf.d/30-other.conf').readAsStringSync(),
            unrelatedSddm,
          );
          for (final path in ['state.conf', '.cache', '.config', '.local']) {
            expect(
              FileSystemEntity.typeSync(
                '${target.root.path}/var/lib/sddm/$path',
              ),
              FileSystemEntityType.notFound,
            );
          }
          expect(
            target
                .file('etc')
                .parent
                .listSync(recursive: true)
                .where((entry) => entry.path.contains('.ro-clean.')),
            isEmpty,
          );
        }
      },
    );

    test('missing marker and PLM main config succeed repeatedly', () async {
      await finalize();
      await finalize();
      expect(target.file('etc/plasmalogin.conf').existsSync(), isFalse);
    });

    for (final session in ['plasma.desktop', 'plasma']) {
      test('clears associated $session after the Live user key', () async {
        target.write(
          'etc/plasmalogin.conf',
          '[Autologin]\nUser=liveuser\nSession=$session\nRelogin=true\n',
        );
        await finalize();
        expect(
          target.file('etc/plasmalogin.conf').readAsStringSync(),
          '[Autologin]\nRelogin=true\n',
        );
      });
    }

    test('accepts spacing and preserves comments and unrelated keys', () async {
      target.write(
        'etc/plasmalogin.conf',
        '  [Autologin]  \n\tSession = plasma.desktop  \n'
            '# User=alice\n User = liveuser \t\nRelogin = false\n'
            '[General]\nUser=liveuser\nSession=keep\n',
      );
      await finalize();
      expect(
        target.file('etc/plasmalogin.conf').readAsStringSync(),
        '  [Autologin]  \n# User=alice\nRelogin = false\n'
        '[General]\nUser=liveuser\nSession=keep\n',
      );
    });

    for (final user in ['alice', 'liveuser-backup', 'plasma-setup']) {
      test('preserves main config autologin for $user', () async {
        final config =
            '[Autologin]\nSession=plasma.desktop\nUser=$user\n'
            '# User=liveuser\n[General]\nUser=liveuser\nSession=keep\n';
        target.write('etc/plasmalogin.conf', config);
        await finalize();
        await finalize();
        expect(target.file('etc/plasmalogin.conf').readAsStringSync(), config);
      });
    }

    test('preserves a session without an explicit Live user', () async {
      const config = '[Autologin]\nSession=plasma.desktop\n# User=liveuser\n';
      target.write('etc/plasmalogin.conf', config);
      await finalize();
      expect(target.file('etc/plasmalogin.conf').readAsStringSync(), config);
    });

    test(
      'preserves the session when a later User selects another account',
      () async {
        target.write(
          'etc/plasmalogin.conf',
          '[Autologin]\nUser=liveuser\nSession=custom.desktop\nUser=alice\n',
        );
        await finalize();
        expect(
          target.file('etc/plasmalogin.conf').readAsStringSync(),
          '[Autologin]\nSession=custom.desktop\nUser=alice\n',
        );
      },
    );

    test('cleans a Live user without a Session key', () async {
      target.write('etc/plasmalogin.conf', '[Autologin]\nUser=liveuser\n');
      await finalize();
      expect(
        target.file('etc/plasmalogin.conf').readAsStringSync(),
        '[Autologin]\n',
      );
    });
  });
  for (final disk in ['/dev/sda', '/dev/nvme0n1', '/dev/mmcblk0']) {
    test('$disk keeps PR-04 UUID fstab and all five subvolumes', () async {
      final runner = RecordingWriter();
      final result = await const TargetFinalizationStage().execute(
        context(runner, disk: disk),
      );
      expect(result.success, isTrue);
      final fstab = runner.writes['/mnt/etc/fstab']!;
      for (final entry in StandardStorageLayout.subvolumes.entries) {
        expect(
          fstab,
          contains(
            'UUID=root-uuid ${entry.value} btrfs defaults,compress=zstd:1,subvol=${entry.key} 0 0',
          ),
        );
      }
      expect(
        fstab,
        contains('UUID=esp-uuid /boot/efi vfat umask=0077,shortname=winnt 0 2'),
      );
      expect(
        fstab.split('\n').where((s) => s.startsWith('UUID=')),
        hasLength(6),
      );
      expect(fstab, isNot(contains('swap')));
      expect(
        runner.wasCalledWith('findmnt', [
          '--verify',
          '--tab-file',
          '/mnt/etc/fstab',
        ]),
        isTrue,
      );
    });
  }

  test(
    'offline finalization performs no removed identity/package policy',
    () async {
      final runner = RecordingWriter();
      expect(
        (await const TargetFinalizationStage().execute(
          context(runner),
        )).success,
        isTrue,
      );
      final commands = runner.commandLog
          .map((c) => '${c.command} ${c.args.join(' ')}')
          .join('\n');
      for (final forbidden in [
        'dnf',
        'useradd',
        'chpasswd',
        'passwd -l',
        '/etc/hostname',
        '/etc/localtime',
        '/etc/locale.conf',
        '/etc/vconsole.conf',
        '00-keyboard.conf',
        'os-release',
        'yum.repos.d',
        'copr',
        'langpacks',
        'ro-kernel',
        'kernel-core',
      ]) {
        expect(commands, isNot(contains(forbidden)), reason: forbidden);
      }
      for (final mount in ['dev', 'proc', 'sys', 'run']) {
        expect(
          runner.wasCalledWith('mount', ['--rbind', '/$mount', '/mnt/$mount']),
          isTrue,
        );
        expect(
          runner.wasCalledWith('mount', ['--make-rslave', '/mnt/$mount']),
          isTrue,
        );
      }
      expect(
        runner.wasCalledWith('rm', [
          '-f',
          '/mnt/etc/machine-id',
          '/mnt/var/lib/dbus/machine-id',
        ]),
        isTrue,
      );
      expect(
        runner.wasCalledWith('systemd-machine-id-setup', ['--root=/mnt']),
        isTrue,
      );
      expect(
        runner.wasCalledWith('ln', [
          '-sf',
          '/etc/machine-id',
          '/mnt/var/lib/dbus/machine-id',
        ]),
        isTrue,
      );
      expect(runner.wasCalledWith('touch', ['/mnt/.autorelabel']), isTrue);
      expect(
        runner.wasCalledWith('chroot', [
          '/mnt',
          'sh',
          '-c',
          targetLiveCleanupScript,
        ]),
        isTrue,
      );
      expect(targetLiveCleanupScript, contains('userdel -r liveuser'));
      expect(targetLiveCleanupScript, contains(r'rpm -qf "$path"'));
      expect(commands, isNot(contains('rm -rf /usr/lib/ro-installer')));
    },
  );

  test(
    'seed/metadata use only allowlisted JSON keys and argument-safe stdin',
    () async {
      final runner = RecordingWriter();
      const hint = 'tr"\n\$(touch /tmp/should-not-execute)';
      final ctx = context(runner, language: hint);
      ctx.state.addAll({
        'username': 'old-user',
        'password': 'secret',
        'selectedTimezone': 'Asia/Tokyo',
        'selectedKernelChannels': ['experimental'],
      });
      expect(
        (await const TargetFinalizationStage().execute(ctx)).success,
        isTrue,
      );
      final seed = jsonDecode(runner.writes['/mnt$installerSeedPath']!);
      final metadata = jsonDecode(runner.writes['/mnt$installMetadataPath']!);
      expect(seed, {'schema_version': 1, 'installer_ui_language_hint': hint});
      expect(metadata, installMetadata());
      expect(isValidInstallerHandoff(seed, metadata), isTrue);
      for (final c in runner.commandLog) {
        expect(c.args.join(' '), isNot(contains(hint)));
        expect(c.args.join(' '), isNot(contains('secret')));
      }
      expect(jsonEncode(seed), isNot(contains('password')));
      expect(jsonEncode(metadata), isNot(contains('username')));
      for (final path in [installerSeedPath, installMetadataPath]) {
        expect(runner.wasCalledWith('chmod', ['0644', '/mnt$path']), isTrue);
        expect(
          runner.commandLog
              .firstWhere((c) => c.args.last == '/mnt$path')
              .stdinTextProvided,
          isTrue,
        );
      }
    },
  );

  test(
    'installed ro-installer is erased locally and DB absence is verified',
    () async {
      final runner = RecordingWriter();
      runner.addResponse('chroot', rpmQuery, stdout: 'ro-installer\nsystemd\n');
      runner.addResponse('chroot', rpmQuery, stdout: 'systemd\n');
      expect(
        (await const TargetFinalizationStage().execute(
          context(runner),
        )).success,
        isTrue,
      );
      expect(
        runner.wasCalledWith('chroot', ['/mnt', 'rpm', '-e', 'ro-installer']),
        isTrue,
      );
      expect(
        runner.commandLog.where(
          (c) => c.command == 'chroot' && c.args.contains('-qa'),
        ),
        hasLength(2),
      );
    },
  );
  test('absent installer package needs no erase', () async {
    final runner = RecordingWriter();
    expect(
      (await const TargetFinalizationStage().execute(context(runner))).success,
      isTrue,
    );
    expect(
      runner.wasCalledWith('chroot', ['/mnt', 'rpm', '-e', 'ro-installer']),
      isFalse,
    );
  });
  for (final failure in ['query', 'erase', 'still-installed']) {
    test('$failure fails closed before cleanup or handoff writes', () async {
      final runner = RecordingWriter();
      runner.addResponse(
        'chroot',
        rpmQuery,
        stdout: 'ro-installer\n',
        exitCode: failure == 'query' ? 1 : 0,
      );
      if (failure == 'erase') {
        runner.addResponse('chroot', [
          '/mnt',
          'rpm',
          '-e',
          'ro-installer',
        ], exitCode: 1);
      }
      if (failure == 'still-installed') {
        runner.addResponse('chroot', rpmQuery, stdout: 'ro-installer\n');
      }
      expect(
        (await const TargetFinalizationStage().execute(
          context(runner),
        )).success,
        isFalse,
      );
      expect(runner.writes, isEmpty);
      expect(
        runner.wasCalledWith('chroot', [
          '/mnt',
          'sh',
          '-c',
          targetLiveCleanupScript,
        ]),
        isFalse,
      );
    });
  }
  test('QEMU smoke service contract is retained', () async {
    final runner = RecordingWriter();
    expect(
      (await const TargetFinalizationStage().execute(
        context(runner, smoke: true),
      )).success,
      isTrue,
    );
    expect(
      runner.commandLog.any(
        (c) => c.args.join(' ').contains('RO_INSTALLER_VM_BOOT_OK'),
      ),
      isTrue,
    );
    expect(
      runner.wasCalledWith('chroot', [
        '/mnt',
        'systemctl',
        'enable',
        'ro-installer-vm-smoke.service',
      ]),
      isTrue,
    );
  });
  for (final command in ['mount', 'systemd-machine-id-setup', 'blkid', 'sh']) {
    test('$command failure stops finalization', () async {
      final runner = RecordingWriter();
      runner.addResponseForCommand(command, exitCode: 1);
      // Explicit blkid fixture responses would supersede fallback failure.
      final ctx = context(runner);
      if (command == 'blkid') {
        runner.reset();
        runner.addResponseForCommand('blkid', exitCode: 1);
      }
      expect(
        (await const TargetFinalizationStage().execute(ctx)).success,
        isFalse,
      );
    });
  }
}
