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

    void addNoFedoraKernelResponse(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallNoFedoraKernelValidationScript,
      ], exitCode: exitCode);
    }

    void addBrandingResponse(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'bash',
        '-c',
        postInstallBrandingValidationScript,
      ], exitCode: exitCode);
    }

    void addPlasmaLauncherResponse(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'bash',
        '-c',
        postInstallPlasmaLauncherValidationScript,
      ], exitCode: exitCode);
    }

    void addSwapResumeResponses(FakeCommandRunner fake) {
      fake.addResponse('sh', [
        '-c',
        'grep -Eq "[[:space:]]swap[[:space:]]" /mnt/etc/fstab',
      ]);
      fake.addResponse('sh', ['-c', postInstallSwapResumeValidationScript]);
    }

    void addNoGpuDebugArgResponse(
      FakeCommandRunner fake, {
      int exitCode = 0,
    }) {
      fake.addResponse('sh', [
        '-c',
        postInstallNoGpuDebugArgsValidationScript,
      ], exitCode: exitCode);
    }

    void addBootReferenceResponses(
      FakeCommandRunner fake, {
      String rootUuid = 'root-uuid-1234',
      String efiUuid = 'efi-uuid-5678',
      bool btrfs = false,
      int blsRootExitCode = 0,
    }) {
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'UUID',
        '/mnt',
      ], stdout: rootUuid);
      fake.addResponse('sh', [
        '-c',
        'grep -Eq "^UUID=$rootUuid[[:space:]]+/[[:space:]]" /mnt/etc/fstab',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -Eq "(^|[[:space:]])root=UUID=$rootUuid([[:space:]]|\$)" /mnt/etc/kernel/cmdline',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -R -E "^[[:space:]]*linux[[:space:]]+/[^[:space:]]*vmlinuz[^[:space:]]*" /mnt/boot/loader/entries/*.conf >/dev/null',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -R -E "^[[:space:]]*initrd[[:space:]]+/[^[:space:]]*initramfs[^[:space:]]*" /mnt/boot/loader/entries/*.conf >/dev/null',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -R -E "^[[:space:]]*options[[:space:]].*root=UUID=$rootUuid([[:space:]]|\$)" /mnt/boot/loader/entries/*.conf >/dev/null',
      ], exitCode: blsRootExitCode);
      if (blsRootExitCode != 0) {
        return;
      }
      if (btrfs) {
        fake.addResponse('sh', [
          '-c',
          'grep -R -E "^[[:space:]]*options[[:space:]].*rootflags=subvol=@" /mnt/boot/loader/entries/*.conf >/dev/null',
        ]);
      }
      fake.addResponse('findmnt', [
        '-rn',
        '-o',
        'UUID',
        '/mnt/boot/efi',
      ], stdout: efiUuid);
      fake.addResponse('sh', [
        '-c',
        'grep -Eq "^UUID=$efiUuid[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]" /mnt/etc/fstab',
      ]);
    }

    void addStableKernelResponse(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallStableKernelValidationScript,
      ], exitCode: exitCode);
    }

    void addBootloaderPackageResponse(
      FakeCommandRunner fake, {
      int exitCode = 0,
    }) {
      fake.addResponse('chroot', [
        '/mnt',
        'rpm',
        '-q',
        'dracut',
        'grub2-efi-x64',
        'shim-x64',
      ], exitCode: exitCode);
    }

    void addKernelImageResponse(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallKernelImageValidationScript,
      ], exitCode: exitCode);
    }

    void addExperimentalKernelResponse(
      FakeCommandRunner fake, {
      int exitCode = 0,
    }) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallExperimentalKernelValidationScript,
      ], exitCode: exitCode);
    }

    void addRoRepoResponses(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallRoRepoValidationScript,
      ], exitCode: exitCode);
    }

    void addRoDesktopAppsResponses(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallRoDesktopAppsValidationScript,
      ], exitCode: exitCode);
    }

    void addInstallerRemovalResponses(FakeCommandRunner fake) {
      fake.addResponse('test', ['!', '-e', '/mnt/usr/bin/ro-installer']);
      fake.addResponse('test', ['!', '-e', '/mnt/usr/bin/ro_installer']);
    }

    void addLiveUserCleanupResponses(
      FakeCommandRunner fake, {
      int accountExitCode = 0,
      int sddmExitCode = 0,
    }) {
      fake.addResponse('chroot', [
        '/mnt',
        'sh',
        '-c',
        '! getent passwd liveuser >/dev/null 2>&1',
      ], exitCode: accountExitCode);
      fake.addResponse('sh', [
        '-c',
        postInstallNoLiveUserSddmValidationScript,
      ], exitCode: sddmExitCode);
    }

    void addRoThemeResponses(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('chroot', [
        '/mnt',
        'rpm',
        '-q',
        'ro-theme',
      ], exitCode: exitCode);
      if (exitCode != 0) {
        return;
      }
      fake.addResponse('test', [
        '-f',
        '/mnt/usr/share/plasma/look-and-feel/org.ro.dark/metadata.json',
      ]);
      fake.addResponse('test', [
        '-f',
        '/mnt/usr/share/color-schemes/RoDark.colors',
      ]);
      fake.addResponse('test', [
        '-f',
        '/mnt/usr/share/sddm/themes/Ro/Main.qml',
      ]);
      fake.addResponse('test', [
        '-f',
        '/mnt/usr/share/plymouth/themes/ro-theme/ro-theme.plymouth',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -q "^LookAndFeelPackage=org.ro.dark\$" /mnt/etc/xdg/kdeglobals && grep -q "^ColorScheme=RoDark\$" /mnt/etc/xdg/kdeglobals',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -q "^name=RoDark\$" /mnt/etc/xdg/plasmarc',
      ]);
      fake.addResponse('sh', [
        '-c',
        'grep -q "^Theme=org.ro.dark\$" /mnt/etc/xdg/ksplashrc',
      ]);
    }

    test('sağlıklı kurulumda doğrulama geçer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake);
      addStableKernelResponse(fake);
      addRoRepoResponses(fake);
      addRoDesktopAppsResponses(fake);
      addRoThemeResponses(fake);
      addInstallerRemovalResponses(fake);
      addLiveUserCleanupResponses(fake);
      addPlasmaLauncherResponse(fake);
      addBootloaderPackageResponse(fake);
      addKernelImageResponse(fake);
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
      addBootReferenceResponses(fake, btrfs: true);
      fake.addResponse('sh', [
        '-c',
        'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
      ]);
      addNoGpuDebugArgResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'grep -q "rootflags=subvol=@" /mnt/etc/kernel/cmdline',
      ]);
      addSwapResumeResponses(fake);

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
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake);
      addStableKernelResponse(fake);
      addRoRepoResponses(fake);
      addRoDesktopAppsResponses(fake);
      addRoThemeResponses(fake);
      addInstallerRemovalResponses(fake);
      addLiveUserCleanupResponses(fake);
      addPlasmaLauncherResponse(fake);
      addBootloaderPackageResponse(fake);
      addKernelImageResponse(fake);
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
      addBootReferenceResponses(fake);
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

    test('live/debug GPU argümanı sızmışsa doğrulama düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake);
      addStableKernelResponse(fake);
      addRoRepoResponses(fake);
      addRoDesktopAppsResponses(fake);
      addRoThemeResponses(fake);
      addInstallerRemovalResponses(fake);
      addLiveUserCleanupResponses(fake);
      addPlasmaLauncherResponse(fake);
      addBootloaderPackageResponse(fake);
      addKernelImageResponse(fake);
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
      addBootReferenceResponses(fake);
      fake.addResponse('sh', [
        '-c',
        'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
      ]);
      addNoGpuDebugArgResponse(fake, exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final result = await const PostInstallValidationStage().execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('grafik boot parametreleri'));
    });

    test('SDDM liveuser kalıntısı sızmışsa doğrulama düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake);
      addStableKernelResponse(fake);
      addRoRepoResponses(fake);
      addRoDesktopAppsResponses(fake);
      addRoThemeResponses(fake);
      addInstallerRemovalResponses(fake);
      addLiveUserCleanupResponses(fake, sddmExitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        result.message,
        'SDDM liveuser kalıntısı hedef sisteme sızmış görünüyor.',
      );
    });

    test('Fedora stock kernel kalırsa stage düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake, exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        result.message,
        'Fedora stock kernel paketleri hedef sistemde kalmış görünüyor.',
      );
    });

    test(
      'experimental secildiyse experimental kernel binary paketleri dogrulanir',
      () async {
        final fake = FakeCommandRunner(defaultSuccess: false);
        fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
        fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
        addLocalizationResponses(fake);
        addBrandingResponse(fake);
        fake.addResponse('sh', [
          '-c',
          'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
        ]);
        addNoFedoraKernelResponse(fake);
        addStableKernelResponse(fake);
        addExperimentalKernelResponse(fake);
        addRoRepoResponses(fake);
        addRoDesktopAppsResponses(fake);
        addRoThemeResponses(fake);
        addInstallerRemovalResponses(fake);
        addLiveUserCleanupResponses(fake);
        addPlasmaLauncherResponse(fake);
        addBootloaderPackageResponse(fake);
        addKernelImageResponse(fake);
        fake.addResponse('sh', [
          '-c',
          'ls /mnt/boot/initramfs-*.img >/dev/null 2>&1',
        ]);
        fake.addResponse('test', [
          '-f',
          '/mnt/boot/efi/EFI/fedora/shimx64.efi',
        ]);
        fake.addResponse('test', [
          '-f',
          '/mnt/boot/efi/EFI/fedora/grubx64.efi',
        ]);
        fake.addResponse('test', ['-f', '/mnt/boot/efi/EFI/fedora/grub.cfg']);
        fake.addResponse('sh', [
          '-c',
          r'grep -q "configfile \$prefix/grub.cfg" /mnt/boot/efi/EFI/fedora/grub.cfg',
        ]);
        fake.addResponse('sh', [
          '-c',
          'ls /mnt/boot/efi/EFI/fedora/* >/dev/null 2>&1',
        ]);
        fake.addResponse('findmnt', [
          '--verify',
          '--tab-file',
          '/mnt/etc/fstab',
        ]);
        addBootReferenceResponses(fake);
        fake.addResponse('sh', [
          '-c',
          'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
        ]);
        addNoGpuDebugArgResponse(fake);
        addSwapResumeResponses(fake);

        final ctx = makeContext({
          'fileSystem': 'ext4',
          'partitionMethod': 'full',
          'selectedKernelChannels': ['stable', 'experimental'],
        }, fake);

        final stage = const PostInstallValidationStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
      },
    );

    test(
      'experimental secildiyse experimental kernel binary eksikliginde stage duser',
      () async {
        final fake = FakeCommandRunner(defaultSuccess: false);
        fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
        fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
        addLocalizationResponses(fake);
        addBrandingResponse(fake);
        fake.addResponse('sh', [
          '-c',
          'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
        ]);
        addNoFedoraKernelResponse(fake);
        addStableKernelResponse(fake);
        addExperimentalKernelResponse(fake, exitCode: 1);

        final ctx = makeContext({
          'fileSystem': 'ext4',
          'partitionMethod': 'full',
          'selectedKernelChannels': ['stable', 'experimental'],
        }, fake);

        final stage = const PostInstallValidationStage();
        final result = await stage.execute(ctx);

        expect(result.success, false);
        expect(
          result.message,
          'Experimental kernel binary paketleri hedef sistemde doğrulanamadı.',
        );
      },
    );

    test('bootloader paketleri doğrulanamazsa stage düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake);
      addStableKernelResponse(fake);
      addRoRepoResponses(fake);
      addRoDesktopAppsResponses(fake);
      addRoThemeResponses(fake);
      addInstallerRemovalResponses(fake);
      addLiveUserCleanupResponses(fake);
      addPlasmaLauncherResponse(fake);
      addBootloaderPackageResponse(fake, exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        result.message,
        'Bootloader için gerekli paketler hedef sistemde doğrulanamadı.',
      );
    });

    test('Ro uygulamaları doğrulanamazsa stage düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addLocalizationResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake);
      addStableKernelResponse(fake);
      addRoRepoResponses(fake);
      addRoDesktopAppsResponses(fake, exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'ext4',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        result.message,
        'Ro uygulamaları hedef sistemde doğrulanamadı: ro-assist, ro-control.',
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
