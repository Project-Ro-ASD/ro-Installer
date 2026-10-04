import 'dart:io';

import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/bootloader_stage.dart';
import 'package:ro_installer/services/install_stages/post_install_validation_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

StageContext makeContext(Map<String, dynamic> state, FakeCommandRunner runner) {
  return StageContext(
    state: state,
    log: (_) {},
    onProgress: (_, _) {},
    commandRunner: runner,
    runCmd:
        (
          cmd,
          args,
          onLog, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async {
          final result = await runner.run(cmd, args);
          return result.started && allowedExitCodes.contains(result.exitCode);
        },
  );
}

void mountResponses(
  FakeCommandRunner fake, {
  String esp = '/dev/sda1',
  String root = 'btrfs   /root',
  int bootExit = 1,
}) {
  fake.addResponse('findmnt', [
    '-rn',
    '-o',
    'FSTYPE,FSROOT',
    '--mountpoint',
    '/mnt',
  ], stdout: root);
  fake.addResponse('findmnt', [
    '-rn',
    '--mountpoint',
    '/mnt/boot',
  ], exitCode: bootExit);
  fake.addResponse('findmnt', [
    '-rn',
    '-o',
    'SOURCE',
    '/mnt/boot/efi',
  ], stdout: esp);
  fake.addResponse('findmnt', [
    '-rn',
    '-o',
    'UUID',
    '/mnt',
  ], stdout: 'root-uuid-1234');
}

/// Runs production shell scripts against an isolated prepared-target fixture.
/// Only target paths are redirected; discovery and loops are executed by sh.
class KernelFixture {
  final Directory root = Directory.systemTemp.createTempSync('pr06-kernels-');
  KernelFixture({bool mergedUsr = true}) {
    Directory('${root.path}/usr/lib/modules').createSync(recursive: true);
    Directory('${root.path}/boot').createSync();
    Directory('${root.path}/bin').createSync();
    if (mergedUsr) {
      Link('${root.path}/lib').createSync('usr/lib');
    } else {
      Directory('${root.path}/lib/modules').createSync(recursive: true);
    }
    for (final tool in ['dracut', 'kernel-install', 'rpm', 'dnf', 'grubby']) {
      final file = File('${root.path}/bin/$tool');
      final body = tool == 'dracut'
          ? r'''
[ "$FAIL_TOOL" != dracut ] || exit 13
printf initramfs > "$2"
'''
          : tool == 'kernel-install'
          ? r'''
[ "$FAIL_TOOL" != kernel-install ] || exit 17
'''
          : 'exit 99\n';
      file.writeAsStringSync('''#!/bin/sh
printf '%s' '$tool' >> "\$CALL_LOG"
printf '\\t%s' "\$@" >> "\$CALL_LOG"
printf '\\n' >> "\$CALL_LOG"
$body
''');
      final chmod = Process.runSync('chmod', ['+x', file.path]);
      if (chmod.exitCode != 0) throw StateError('fixture chmod failed');
    }
  }
  void candidate(
    String version, {
    String? imageLocation = 'boot',
    String tree = 'usr/lib',
  }) {
    Directory(
      '${root.path}/$tree/modules/$version',
    ).createSync(recursive: true);
    if (imageLocation != null) {
      final path = imageLocation == 'boot'
          ? 'boot/vmlinuz-$version'
          : '$tree/modules/$version/vmlinuz';
      File('${root.path}/$path').writeAsStringSync('kernel');
    }
  }

  Future<ProcessResult> run(String script, {String failTool = ''}) {
    final redirected = script.replaceAllMapped(
      RegExp(r'/usr/lib/modules|/lib/modules|/boot'),
      (match) => '${root.path}${match[0]}',
    );
    return Process.run(
      'sh',
      ['-c', redirected],
      environment: {
        'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
        'CALL_LOG': '${root.path}/calls',
        'FAIL_TOOL': failTool,
      },
    );
  }

  List<String> get calls => File('${root.path}/calls').existsSync()
      ? File('${root.path}/calls').readAsLinesSync()
      : [];
  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  group('prepared kernel shell fixtures', () {
    for (final version in [
      '6.x.y-custom',
      '6.17.1-300.fc43.x86_64',
      '6.17.1-ro_stable',
    ]) {
      test('$version uses the same artifact path', () async {
        final fixture = KernelFixture();
        addTearDown(fixture.dispose);
        fixture.candidate(version);
        expect((await fixture.run(bootloaderDracutScript)).exitCode, 0);
        expect((await fixture.run(bootloaderKernelInstallScript)).exitCode, 0);
        expect(fixture.calls, [
          'dracut\t-f\t${fixture.root.path}/boot/initramfs-$version.img\t$version',
          'kernel-install\tadd\t$version\t${fixture.root.path}/boot/vmlinuz-$version',
        ]);
        expect(
          (await fixture.run(postInstallKernelImageValidationScript)).exitCode,
          0,
        );
        File('${fixture.root.path}/boot/initramfs-$version.img').deleteSync();
        expect(
          (await fixture.run(postInstallKernelImageValidationScript)).exitCode,
          isNot(0),
        );
      });
    }
    test(
      'multiple versions are prepared once despite merged /lib; stray tree skipped',
      () async {
        final fixture = KernelFixture();
        addTearDown(fixture.dispose);
        fixture.candidate('6.1-ro_experimental');
        fixture.candidate('6.2-custom', imageLocation: 'modules');
        fixture.candidate('6.3-incomplete', imageLocation: null);
        final dracut = await fixture.run(bootloaderDracutScript);
        expect(dracut.exitCode, 0);
        expect(
          dracut.stderr,
          contains('Skipping incomplete prepared kernel: 6.3-incomplete'),
        );
        expect((await fixture.run(bootloaderKernelInstallScript)).exitCode, 0);
        expect(fixture.calls.length, 4);
        for (final version in ['6.1-ro_experimental', '6.2-custom']) {
          expect(
            fixture.calls
                .where(
                  (line) =>
                      line.startsWith('dracut\t') &&
                      line.endsWith('\t$version'),
                )
                .length,
            1,
          );
          expect(
            fixture.calls
                .where(
                  (line) => line.startsWith('kernel-install\tadd\t$version\t'),
                )
                .length,
            1,
          );
        }
        expect(
          fixture.calls.any(
            (line) => RegExp(r'^(rpm|dnf|grubby)\b').hasMatch(line),
          ),
          false,
        );
      },
    );
    test('independent /lib module image is supported', () async {
      final fixture = KernelFixture(mergedUsr: false);
      addTearDown(fixture.dispose);
      fixture.candidate('6.4-other', tree: 'lib', imageLocation: 'modules');
      expect((await fixture.run(bootloaderDracutScript)).exitCode, 0);
      expect((await fixture.run(bootloaderKernelInstallScript)).exitCode, 0);
      expect(fixture.calls.last, endsWith('/lib/modules/6.4-other/vmlinuz'));
    });
    for (final incomplete in [false, true]) {
      test('no complete candidate fails closed (stray=$incomplete)', () async {
        final fixture = KernelFixture();
        addTearDown(fixture.dispose);
        if (incomplete) fixture.candidate('6.1-stray', imageLocation: null);
        for (final script in [
          bootloaderDracutScript,
          bootloaderKernelInstallScript,
          postInstallKernelImageValidationScript,
        ]) {
          final result = await fixture.run(script);
          expect(result.exitCode, isNot(0));
          expect(
            result.stderr,
            contains('No complete prepared kernel candidate'),
          );
        }
        expect(fixture.calls, isEmpty);
      });
    }
    for (final tool in ['dracut', 'kernel-install']) {
      test('$tool failure stops processing', () async {
        final fixture = KernelFixture();
        addTearDown(fixture.dispose);
        fixture.candidate('6.1-custom');
        fixture.candidate('6.2-custom');
        final script = tool == 'dracut'
            ? bootloaderDracutScript
            : bootloaderKernelInstallScript;
        expect((await fixture.run(script, failTool: tool)).exitCode, isNot(0));
        expect(fixture.calls.length, 1);
      });
    }
  });

  group('BootloaderStage', () {
    test('standard cmdline, root GRUB prefix and boot ordering', () async {
      final fake = FakeCommandRunner();
      mountResponses(fake);
      final result = await const BootloaderStage().execute(
        makeContext({
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
          'resolvedSwapDevice': '/dev/sda3',
        }, fake),
      );
      expect(result.success, true);
      final commands = fake.commandLog.map((c) => c.commandLine).toList();
      int index(String value) =>
          commands.indexWhere((c) => c.contains(value.trim()));
      expect(
        commands[index('/mnt/etc/kernel/cmdline')],
        contains(
          'root=UUID=root-uuid-1234 ro rootflags=subvol=root rhgb quiet',
        ),
      );
      final stub = commands[index('/mnt/boot/efi/EFI/fedora/grub.cfg')];
      expect(
        stub,
        contains('search --no-floppy --fs-uuid --set=dev root-uuid-1234'),
      );
      expect(stub, contains(r'set prefix=($dev)/root/boot/grub2'));
      expect(stub, contains(r'configfile $prefix/grub.cfg'));
      expect(
        index(bootloaderDracutScript),
        greaterThan(index('/mnt/etc/kernel/cmdline')),
      );
      expect(
        index(bootloaderKernelInstallScript),
        greaterThan(index(bootloaderDracutScript)),
      );
      expect(
        index('grub2-mkconfig'),
        greaterThan(index(bootloaderKernelInstallScript)),
      );
      expect(index('efibootmgr'), greaterThan(index('grub2-mkconfig')));
      expect(commands.join('\n'), contains('GRUB_ENABLE_BLSCFG=true'));
      for (final forbidden in [
        '/@/boot/grub2',
        'subvol=@',
        'resume=',
        'rpm ',
        'dnf ',
        'copr',
        'ro-kernel',
        'grubby',
        'grub2-install',
      ]) {
        expect(commands.join('\n'), isNot(contains(forbidden)));
      }
    });
    for (final entry in {
      '/dev/sda1': ['/dev/sda', '1'],
      '/dev/nvme0n1p2': ['/dev/nvme0n1', '2'],
      '/dev/mmcblk0p3': ['/dev/mmcblk0', '3'],
    }.entries) {
      test('UEFI parsing ${entry.key}', () async {
        final fake = FakeCommandRunner();
        mountResponses(fake, esp: entry.key);
        expect(
          (await const BootloaderStage().execute(
            makeContext({}, fake),
          )).success,
          true,
        );
        expect(
          fake.wasCalledWith('efibootmgr', [
            '-c',
            '-d',
            entry.value[0],
            '-p',
            entry.value[1],
            '-L',
            'Ro-ASD',
            '-l',
            r'\EFI\fedora\shimx64.efi',
          ]),
          true,
        );
      });
    }
    for (final state in [
      {'partitionMethod': 'manual', 'fileSystem': 'btrfs'},
      {'partitionMethod': 'full', 'fileSystem': 'ext4'},
    ]) {
      test('unsupported state $state rejected before commands', () async {
        final fake = FakeCommandRunner();
        expect(
          (await const BootloaderStage().execute(
            makeContext(state, fake),
          )).success,
          false,
        );
        expect(fake.commandLog, isEmpty);
      });
    }
    for (final root in ['btrfs /@', 'ext4 /', '']) {
      test('unexpected mounted root $root rejected', () async {
        final fake = FakeCommandRunner();
        mountResponses(fake, root: root);
        expect(
          (await const BootloaderStage().execute(
            makeContext({}, fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('chroot'), false);
      });
    }
    test('separate boot fails closed', () async {
      final fake = FakeCommandRunner();
      mountResponses(fake, bootExit: 0);
      expect(
        (await const BootloaderStage().execute(makeContext({}, fake))).success,
        false,
      );
      expect(fake.wasCommandCalled('chroot'), false);
    });
    for (final path in ['shimx64.efi', 'grubx64.efi']) {
      test('missing EFI $path fails', () async {
        final fake = FakeCommandRunner();
        mountResponses(fake);
        fake.addResponse('test', [
          '-f',
          '/mnt/boot/efi/EFI/fedora/$path',
        ], exitCode: 1);
        expect(
          (await const BootloaderStage().execute(
            makeContext({}, fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('efibootmgr'), false);
      });
    }
    for (final args in [
      ['/mnt', 'sh', '-c', bootloaderDracutScript],
      ['/mnt', 'sh', '-c', bootloaderKernelInstallScript],
      ['/mnt', 'grub2-mkconfig', '-o', '/boot/grub2/grub.cfg'],
    ]) {
      test('failed boot command ${args[1]} aborts stage', () async {
        final fake = FakeCommandRunner();
        mountResponses(fake);
        fake.addResponse('chroot', args, exitCode: 1);
        expect(
          (await const BootloaderStage().execute(
            makeContext({}, fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('efibootmgr'), false);
      });
    }
    test('firmware command failure propagates', () async {
      final fake = FakeCommandRunner();
      mountResponses(fake);
      fake.addResponseForCommand('efibootmgr', exitCode: 1);
      expect(
        (await const BootloaderStage().execute(makeContext({}, fake))).success,
        false,
      );
    });
    for (final args in [
      ['-rn', '-o', 'FSTYPE,FSROOT', '--mountpoint', '/mnt'],
      ['-rn', '--mountpoint', '/mnt/boot'],
      ['-rn', '-o', 'SOURCE', '/mnt/boot/efi'],
      ['-rn', '-o', 'UUID', '/mnt'],
    ]) {
      test('failed mount/UUID probe $args prevents target writes', () async {
        final fake = FakeCommandRunner();
        // Override probes before the normal queued successful responses.
        fake.addResponse('findmnt', args, exitCode: 127, started: false);
        mountResponses(fake);
        expect(
          (await const BootloaderStage().execute(
            makeContext({}, fake),
          )).success,
          false,
        );
        expect(fake.wasCommandCalled('sh'), false);
        expect(fake.wasCommandCalled('chroot'), false);
      });
    }
    test('invalid EFI device rejected', () async {
      final fake = FakeCommandRunner();
      mountResponses(fake, esp: 'invalid');
      expect(
        (await const BootloaderStage().execute(makeContext({}, fake))).success,
        false,
      );
      expect(fake.wasCommandCalled('efibootmgr'), false);
    });
  });
}
