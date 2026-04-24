import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/bootloader_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = false,
}) {
  return StageContext(
    state: state,
    log: (msg) {},
    onProgress: (p, s) {},
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
          return allowedExitCodes.contains(result.exitCode);
        },
    isMock: isMock,
  );
}

void main() {
  group('BootloaderStage', () {
    void addHappyPathResponses(
      FakeCommandRunner fake, {
      bool separateBoot = false,
    }) {
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'SOURCE',
        '/mnt/boot/efi',
      ], stdout: '/dev/sda1');
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'UUID',
        '/mnt',
      ], stdout: 'root-uuid-1234');
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'SOURCE',
        '/mnt',
      ], stdout: '/dev/sda2');
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'SOURCE',
        '/mnt/boot',
      ], stdout: separateBoot ? '/dev/sda3' : '/dev/sda2');
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'UUID',
        '/mnt/boot',
      ], stdout: separateBoot ? 'boot-uuid-5678' : 'root-uuid-1234');
    }

    test(
      'boot zinciri shim stub ve efibootmgr ile doğru sırayla çalışır',
      () async {
        final fake = FakeCommandRunner();
        addHappyPathResponses(fake);

        final ctx = makeContext(<String, dynamic>{}, fake);
        final stage = const BootloaderStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final findmntEfiIdx = fake.commandLog.indexWhere(
          (c) =>
              c.command == 'findmnt' &&
              c.args.join(' ') == '-rn -o SOURCE /mnt/boot/efi',
        );
        final rootUuidIdx = fake.commandLog.indexWhere(
          (c) =>
              c.command == 'findmnt' && c.args.join(' ') == '-rn -o UUID /mnt',
        );
        final cmdlineIdx = fake.commandLog.indexWhere(
          (c) =>
              c.command == 'sh' &&
              c.args.join(' ').contains('/mnt/etc/kernel/cmdline'),
        );
        final dracutIdx = fake.commandLog.indexWhere(
          (c) => c.command == 'chroot' && c.args.contains('dracut'),
        );
        final kernelInstallIdx = fake.commandLog.indexWhere(
          (c) =>
              c.command == 'chroot' &&
              c.args.join(' ').contains('kernel-install'),
        );
        final shimCheckIdx = fake.commandLog.indexWhere(
          (c) =>
              c.command == 'test' &&
              c.args.join(' ') == '-f /mnt/boot/efi/EFI/fedora/shimx64.efi',
        );
        final stubWriteIdx = fake.commandLog.indexWhere(
          (c) =>
              c.command == 'sh' &&
              c.args.join(' ').contains('/mnt/boot/efi/EFI/fedora/grub.cfg'),
        );
        final mkconfigIdx = fake.commandLog.indexWhere(
          (c) => c.command == 'chroot' && c.args.contains('grub2-mkconfig'),
        );
        final efibootmgrIdx = fake.commandLog.indexWhere(
          (c) => c.command == 'efibootmgr',
        );

        expect(rootUuidIdx, greaterThan(findmntEfiIdx));
        expect(cmdlineIdx, greaterThan(rootUuidIdx));
        expect(dracutIdx, greaterThan(cmdlineIdx));
        expect(kernelInstallIdx, greaterThan(dracutIdx));
        expect(shimCheckIdx, greaterThan(kernelInstallIdx));
        expect(stubWriteIdx, greaterThan(shimCheckIdx));
        expect(mkconfigIdx, greaterThan(stubWriteIdx));
        expect(efibootmgrIdx, greaterThan(mkconfigIdx));

        expect(
          fake.wasCalledWith('efibootmgr', [
            '-c',
            '-d',
            '/dev/sda',
            '-p',
            '1',
            '-L',
            'Fedora',
            '-l',
            r'\EFI\fedora\shimx64.efi',
          ]),
          true,
        );
      },
    );

    test(
      'btrfs tam kurulumda kernel cmdline içine subvol bilgisi yazar',
      () async {
        final fake = FakeCommandRunner();
        addHappyPathResponses(fake);

        final state = <String, dynamic>{
          'fileSystem': 'btrfs',
          'partitionMethod': 'full',
        };
        final ctx = makeContext(state, fake);

        final stage = const BootloaderStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
        expect(
          fake.wasCalledWith('sh', [
            '-c',
            'echo "root=UUID=root-uuid-1234 ro rootflags=subvol=@ rhgb quiet" > /mnt/etc/kernel/cmdline',
          ]),
          true,
        );
      },
    );

    test('manuel btrfs modunda subvol rootflags yazar', () async {
      final fake = FakeCommandRunner();
      addHappyPathResponses(fake);

      final state = <String, dynamic>{
        'fileSystem': 'btrfs',
        'partitionMethod': 'manual',
      };
      final ctx = makeContext(state, fake);

      final stage = const BootloaderStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.wasCalledWith('sh', [
          '-c',
          'echo "root=UUID=root-uuid-1234 ro rootflags=subvol=@ rhgb quiet" > /mnt/etc/kernel/cmdline',
        ]),
        true,
      );
    });

    test(
      'manuel btrfs kurulumda ayrı boot yoksa EFI stub /@/boot/grub2 yolunu kullanır',
      () async {
        final fake = FakeCommandRunner();
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt/boot/efi',
        ], stdout: '/dev/sda1');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'UUID',
          '/mnt',
        ], stdout: 'root-uuid-1234');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt',
        ], stdout: '/dev/sda2');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt/boot',
        ], exitCode: 1);
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'UUID',
          '/mnt/boot',
        ], exitCode: 1);

        final ctx = makeContext(<String, dynamic>{
          'fileSystem': 'btrfs',
          'partitionMethod': 'manual',
        }, fake);
        final stage = const BootloaderStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final stubCommand = fake.commandLog.firstWhere(
          (c) =>
              c.command == 'sh' &&
              c.args.join(' ').contains('/mnt/boot/efi/EFI/fedora/grub.cfg'),
        );
        expect(
          stubCommand.args.join(' '),
          contains(r'set prefix=($dev)/@/boot/grub2'),
        );
      },
    );

    test('ayrı boot bölümü varsa EFI stub /grub2 yolunu kullanır', () async {
      final fake = FakeCommandRunner();
      addHappyPathResponses(fake, separateBoot: true);

      final ctx = makeContext(<String, dynamic>{}, fake);
      final stage = const BootloaderStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      final stubCommand = fake.commandLog.firstWhere(
        (c) =>
            c.command == 'sh' &&
            c.args.join(' ').contains('/mnt/boot/efi/EFI/fedora/grub.cfg'),
      );
      expect(
        stubCommand.args.join(' '),
        contains('search --no-floppy --fs-uuid --set=dev boot-uuid-5678'),
      );
      expect(stubCommand.args.join(' '), contains(r'set prefix=($dev)/grub2'));
    });

    test(
      'btrfs tam kurulumda root UUID ile /@/boot/grub2 yolunu kullanır',
      () async {
        final fake = FakeCommandRunner();
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt/boot/efi',
        ], stdout: '/dev/sda1');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'UUID',
          '/mnt',
        ], stdout: 'root-uuid-1234');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt',
        ], stdout: '/dev/sda2');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt/boot',
        ], exitCode: 1);
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'UUID',
          '/mnt/boot',
        ], exitCode: 1);

        final ctx = makeContext(<String, dynamic>{
          'fileSystem': 'btrfs',
          'partitionMethod': 'full',
        }, fake);
        final stage = const BootloaderStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final stubCommand = fake.commandLog.firstWhere(
          (c) =>
              c.command == 'sh' &&
              c.args.join(' ').contains('/mnt/boot/efi/EFI/fedora/grub.cfg'),
        );
        expect(
          stubCommand.args.join(' '),
          contains('search --no-floppy --fs-uuid --set=dev root-uuid-1234'),
        );
        expect(
          stubCommand.args.join(' '),
          contains(r'set prefix=($dev)/@/boot/grub2'),
        );
      },
    );

    test(
      '/boot ayrı bölüm değilse btrfs olmayan kurulumda /boot/grub2 yolunu kullanır',
      () async {
        final fake = FakeCommandRunner();
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt/boot/efi',
        ], stdout: '/dev/sda1');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'UUID',
          '/mnt',
        ], stdout: 'root-uuid-1234');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt',
        ], stdout: '/dev/sda2');
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'SOURCE',
          '/mnt/boot',
        ], exitCode: 1);
        fake.addResponse('findmnt', [
          '-rn',
          '-o',
          'UUID',
          '/mnt/boot',
        ], exitCode: 1);

        final ctx = makeContext(<String, dynamic>{
          'fileSystem': 'ext4',
          'partitionMethod': 'full',
        }, fake);
        final stage = const BootloaderStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final stubCommand = fake.commandLog.firstWhere(
          (c) =>
              c.command == 'sh' &&
              c.args.join(' ').contains('/mnt/boot/efi/EFI/fedora/grub.cfg'),
        );
        expect(
          stubCommand.args.join(' '),
          contains(r'set prefix=($dev)/boot/grub2'),
        );
      },
    );

    test('kernel-install başarısız olursa stage hata ile durur', () async {
      final fake = FakeCommandRunner();
      addHappyPathResponses(fake);
      fake.addResponse(
        'chroot',
        [
          '/mnt',
          'sh',
          '-c',
          'kver=\$(ls /lib/modules | head -1) && kernel-install add \$kver /lib/modules/\$kver/vmlinuz',
        ],
        exitCode: 1,
        stderr: 'kernel-install failed',
      );

      final ctx = makeContext(<String, dynamic>{}, fake);
      final stage = const BootloaderStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, 'kernel-install başarısız oldu.');
    });

    test('grub2-mkconfig başarısız olursa stage hata ile durur', () async {
      final fake = FakeCommandRunner();
      addHappyPathResponses(fake);
      fake.addResponse(
        'chroot',
        ['/mnt', 'grub2-mkconfig', '-o', '/boot/grub2/grub.cfg'],
        exitCode: 1,
        stderr: 'mkconfig failed',
      );

      final ctx = makeContext(<String, dynamic>{}, fake);
      final stage = const BootloaderStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, 'grub2-mkconfig başarısız oldu.');
    });
  });
}
