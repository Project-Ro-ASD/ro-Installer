import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/post_install_validation_stage.dart';
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
  group('PostInstallValidationStage', () {
    void addLocalizationResponses(
      FakeCommandRunner fake, {
      String locale = 'en_US.UTF-8',
      String keymap = 'trq',
      String x11Layout = 'tr',
      String timezone = 'Europe/Istanbul',
      List<String> packages = const ['glibc-langpack-en', 'langpacks-en'],
    }) {
      fake.addResponse('test', ['-f', '/mnt/etc/locale.conf']);
      fake.addResponse('sh', [
        '-c',
        'grep -q "^LANG=$locale\$" /mnt/etc/locale.conf',
      ]);
      fake.addResponse('test', ['-f', '/mnt/etc/vconsole.conf']);
      fake.addResponse('sh', [
        '-c',
        'grep -q "^KEYMAP=$keymap\$" /mnt/etc/vconsole.conf',
      ]);
      fake.addResponse('test', [
        '-f',
        '/mnt/etc/X11/xorg.conf.d/00-keyboard.conf',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -q \'Option "XkbLayout" "$x11Layout"\' /mnt/etc/X11/xorg.conf.d/00-keyboard.conf',
      ]);
      fake.addResponse('sh', [
        '-c',
        '[ "\$(readlink /mnt/etc/localtime)" = "/usr/share/zoneinfo/$timezone" ]',
      ]);
      fake.addResponse('chroot', ['/mnt', 'rpm', '-q', ...packages]);
    }

    test('sağlıklı kurulumda doğrulama geçer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      fake.addResponse('chroot', [
        '/mnt',
        'rpm',
        '-q',
        'kernel-core',
        'dracut',
        'grub2-efi-x64',
        'shim-x64',
      ]);
      fake.addResponse('sh', ['-c', 'ls /mnt/boot/vmlinuz-* >/dev/null 2>&1']);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/initramfs-*.img >/dev/null 2>&1',
      ]);
      fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/shimx64.efi']);
      fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/grubx64.efi']);
      fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/grub.cfg']);
      fake.addResponse('sh', [
        '-c',
        r'grep -q "configfile \$prefix/grub.cfg" /mnt/boot/efi/EFI/fedora/grub.cfg',
      ]);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/efi/EFI/fedora/* >/dev/null 2>&1',
      ]);
      fake.addResponse('findmnt', ['--verify', '--tab-file', '/mnt/etc/fstab']);
      fake.addResponse('sh', [
        '-c',
        'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -q "rootflags=subvol=@" /mnt/etc/kernel/cmdline',
      ]);

      final ctx = makeContext({
        'fileSystem': 'btrfs',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
    });

    test('live parametresi sızmışsa doğrulama düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      fake.addResponse('chroot', [
        '/mnt',
        'rpm',
        '-q',
        'kernel-core',
        'dracut',
        'grub2-efi-x64',
        'shim-x64',
      ]);
      fake.addResponse('sh', ['-c', 'ls /mnt/boot/vmlinuz-* >/dev/null 2>&1']);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/initramfs-*.img >/dev/null 2>&1',
      ]);
      fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/shimx64.efi']);
      fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/grubx64.efi']);
      fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/grub.cfg']);
      fake.addResponse('sh', [
        '-c',
        r'grep -q "configfile \$prefix/grub.cfg" /mnt/boot/efi/EFI/fedora/grub.cfg',
      ]);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/efi/EFI/fedora/* >/dev/null 2>&1',
      ]);
      fake.addResponse('findmnt', ['--verify', '--tab-file', '/mnt/etc/fstab']);
      fake.addResponse('sh', [
        '-c',
        'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
      ], exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('Live ISO'));
    });

    test('boot paketleri doğrulanamazsa stage düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      fake.addResponse('chroot', [
        '/mnt',
        'rpm',
        '-q',
        'kernel-core',
        'dracut',
        'grub2-efi-x64',
        'shim-x64',
      ], exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        result.message,
        'Boot için gerekli paketler hedef sistemde doğrulanamadı.',
      );
    });

    test('locale ayari eksikse stage düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      fake.addResponse('test', ['-f', '/mnt/etc/locale.conf'], exitCode: 1);

      final ctx = makeContext(const {
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, '/mnt/etc/locale.conf bulunamadı.');
    });
  });
}
