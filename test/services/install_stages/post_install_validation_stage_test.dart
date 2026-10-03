import 'dart:convert';
import 'package:ro_installer/models/installer_handoff.dart';
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
    void addHandoffResponses(FakeCommandRunner fake) {
      fake.addResponse('cat', [
        '/mnt$installerSeedPath',
      ], stdout: jsonEncode(installerSeed('tr')));
      fake.addResponse('cat', [
        '/mnt$installMetadataPath',
      ], stdout: jsonEncode(installMetadata()));
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

    void addStandardStorageResponses(FakeCommandRunner fake) {
      fake.addResponse('sh', [
        '-c',
        postInstallStandardStorageValidationScript,
      ]);
    }

    void addNoGpuDebugArgResponse(FakeCommandRunner fake, {int exitCode = 0}) {
      fake.addResponse('sh', [
        '-c',
        postInstallNoGpuDebugArgsValidationScript,
      ], exitCode: exitCode);
    }

    void addBootReferenceResponses(
      FakeCommandRunner fake, {
      String rootUuid = 'root-uuid-1234',
      String efiUuid = 'efi-uuid-5678',
      bool btrfs = true,
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
          'grep -R -E "^[[:space:]]*options[[:space:]].*rootflags=subvol=root" /mnt/boot/loader/entries/*.conf >/dev/null',
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

    test(
      'Ro desktop uygulama doğrulaması non-dynamic executable dosyalarda ldd zorlamaz',
      () {
        expect(
          postInstallRoDesktopAppsValidationScript,
          contains(r'validate_executable_runtime "$ro_assist_bin"'),
        );
        expect(
          postInstallRoDesktopAppsValidationScript,
          contains('/usr/libexec/ro-assist/ro-assist'),
        );
        expect(
          postInstallRoDesktopAppsValidationScript,
          contains('is not a dynamic ELF executable'),
        );
        expect(
          postInstallRoDesktopAppsValidationScript,
          isNot(contains(r'ldd -r "$ro_assist_bin"\nldd -r "$ro_control_bin"')),
        );
      },
    );

    void addInstallerRemovalResponses(FakeCommandRunner fake) {
      fake.addResponse('test', ['!', '-e', '/mnt/usr/bin/ro-installer']);
      fake.addResponse('test', ['!', '-e', '/mnt/usr/bin/ro_installer']);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/usr/libexec/ro-installer-launcher.sh',
      ]);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/usr/share/polkit-1/actions/org.roasd.installer.policy',
      ]);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/etc/polkit-1/rules.d/49-ro-installer-live.rules',
      ]);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/etc/sudoers.d/ro-installer-live',
      ]);
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
      addHandoffResponses(fake);
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
        'grep -q "rootflags=subvol=root" /mnt/etc/kernel/cmdline',
      ]);
      addStandardStorageResponses(fake);

      final ctx = makeContext({
        'fileSystem': 'btrfs',
        'partitionMethod': 'full',
      }, fake);

      final stage = const PostInstallValidationStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.commandLog.any(
          (c) =>
              c.args.join(' ').contains('/etc/locale.conf') ||
              c.args.join(' ').contains('/etc/localtime') ||
              c.args.join(' ').contains('langpacks-') ||
              c.args.join(' ').contains('/etc/vconsole.conf'),
        ),
        isFalse,
      );
      expect(
        fake.wasCalledWith('sh', ['-c', postInstallSwapResumeValidationScript]),
        isFalse,
      );
    });

    test(
      'standard storage mismatch fails validation without requiring swap',
      () async {
        final fake = FakeCommandRunner();
        addHandoffResponses(fake);
        addBootReferenceResponses(fake);
        fake.addResponse('sh', [
          '-c',
          postInstallStandardStorageValidationScript,
        ], exitCode: 1);
        final result = await const PostInstallValidationStage().execute(
          makeContext({'fileSystem': 'btrfs', 'partitionMethod': 'full'}, fake),
        );
        expect(result.success, isFalse);
        expect(result.message, contains('Standard Btrfs'));
        expect(
          fake.wasCalledWith('sh', [
            '-c',
            postInstallSwapResumeValidationScript,
          ]),
          isFalse,
        );
      },
    );

    test('live parametresi sızmışsa doğrulama düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addHandoffResponses(fake);
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
        'fileSystem': 'btrfs',
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
      addHandoffResponses(fake);
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
        'fileSystem': 'btrfs',
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
      addHandoffResponses(fake);
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
        'fileSystem': 'btrfs',
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

    test('canlı polkit kuralı sızmışsa doğrulama düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addHandoffResponses(fake);
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
      fake.addResponse('test', ['!', '-e', '/mnt/usr/bin/ro-installer']);
      fake.addResponse('test', ['!', '-e', '/mnt/usr/bin/ro_installer']);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/usr/libexec/ro-installer-launcher.sh',
      ]);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/usr/share/polkit-1/actions/org.roasd.installer.policy',
      ]);
      fake.addResponse('test', [
        '!',
        '-e',
        '/mnt/etc/polkit-1/rules.d/49-ro-installer-live.rules',
      ], exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'btrfs',
        'partitionMethod': 'full',
      }, fake);

      final result = await const PostInstallValidationStage().execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('Canlı oturum polkit kuralı'));
    });

    test('Fedora stock kernel kalırsa stage düşer', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('test', ['-f', '/mnt/etc/fstab']);
      fake.addResponse('test', ['-f', '/mnt/etc/kernel/cmdline']);
      addHandoffResponses(fake);
      addBrandingResponse(fake);
      fake.addResponse('sh', [
        '-c',
        'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
      ]);
      addNoFedoraKernelResponse(fake, exitCode: 1);

      final ctx = makeContext({
        'fileSystem': 'btrfs',
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
        addHandoffResponses(fake);
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
        fake.addResponse('sh', [
          '-c',
          'grep -q "rootflags=subvol=root" /mnt/etc/kernel/cmdline',
        ]);
        addStandardStorageResponses(fake);

        final ctx = makeContext({
          'fileSystem': 'btrfs',
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
        addHandoffResponses(fake);
        addBrandingResponse(fake);
        fake.addResponse('sh', [
          '-c',
          'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
        ]);
        addNoFedoraKernelResponse(fake);
        addStableKernelResponse(fake);
        addExperimentalKernelResponse(fake, exitCode: 1);

        final ctx = makeContext({
          'fileSystem': 'btrfs',
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
      addHandoffResponses(fake);
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
        'fileSystem': 'btrfs',
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
      addHandoffResponses(fake);
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
        'fileSystem': 'btrfs',
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

    for (final path in [installerSeedPath, installMetadataPath]) {
      test('$path must exist', () async {
        final fake = FakeCommandRunner();
        if (path == installMetadataPath) {
          fake.addResponse('cat', [
            '/mnt$installerSeedPath',
          ], stdout: jsonEncode(installerSeed('tr')));
        }
        fake.addResponse('cat', ['/mnt$path'], exitCode: 1);
        final result = await const PostInstallValidationStage().execute(
          makeContext({'fileSystem': 'btrfs', 'partitionMethod': 'full'}, fake),
        );
        expect(result.success, isFalse);
        expect(result.message, contains('metadata okunamadı'));
      });
    }

    test(
      'secret-bearing or malformed handoff fails without source disclosure',
      () async {
        for (final seed in [
          '{bad-json',
          jsonEncode({...installerSeed('tr'), 'password': 'secret'}),
        ]) {
          final fake = FakeCommandRunner();
          fake.addResponse('cat', ['/mnt$installerSeedPath'], stdout: seed);
          fake.addResponse('cat', [
            '/mnt$installMetadataPath',
          ], stdout: jsonEncode(installMetadata()));
          final result = await const PostInstallValidationStage().execute(
            makeContext({
              'fileSystem': 'btrfs',
              'partitionMethod': 'full',
            }, fake),
          );
          expect(result.success, isFalse);
          expect(result.message, isNot(contains('secret')));
        }
      },
    );
  });
}
