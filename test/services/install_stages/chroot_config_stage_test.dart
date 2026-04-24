import 'package:test/test.dart';
import 'package:ro_installer/services/install_stages/chroot_config_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = true,
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
  group('ChrootConfigStage', () {
    test('yönetici kullanıcı güvenli bir şekilde oluşturulur', () async {
      final fake = FakeCommandRunner();
      final state = {
        'username': 'testuser',
        'password': 'testpassword',
        'isAdministrator': true,
      };
      final ctx = makeContext(state, fake);

      final stage = const ChrootConfigStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      // 1. useradd çalıştırıldı mı?
      expect(
        fake.wasCalledWith('chroot', [
          '/mnt',
          'useradd',
          '-m',
          '-s',
          '/bin/bash',
          '-G',
          'wheel',
          'testuser',
        ]),
        true,
        reason: 'useradd komutu çalıştırılmadı',
      );

      // 2. Parola belirlendi mi?
      expect(
        fake.wasCalledWith('chroot', [
          '/mnt',
          'sh',
          '-c',
          "printf '%s\\n' 'testuser:testpassword' | chpasswd",
        ]),
        true,
        reason: 'chpasswd ile parola belirlenmedi',
      );

      // 3. Root kilitlendi mi?
      expect(
        fake.wasCalledWith('chroot', ['/mnt', 'passwd', '-l', 'root']),
        true,
        reason: 'root hesabı kilitlenmedi (güvenlik zafiyeti)',
      );

      // 4. Sudo yetkisi verildi mi?
      expect(
        fake.wasCalledWith('chroot', [
          '/mnt',
          'sh',
          '-c',
          "printf '%s\\n' 'testuser ALL=(ALL:ALL) ALL' > /etc/sudoers.d/testuser",
        ]),
        true,
        reason: 'sudo yetkisi verilmedi',
      );
    });

    test(
      'normal kullanıcı wheel grubuna eklenmez ve sudoers yazılmaz',
      () async {
        final fake = FakeCommandRunner();
        final state = {
          'username': 'normaluser',
          'password': '1234',
          'isAdministrator': false,
        };
        final ctx = makeContext(state, fake);

        final stage = const ChrootConfigStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
        expect(
          fake.wasCalledWith('chroot', [
            '/mnt',
            'useradd',
            '-m',
            '-s',
            '/bin/bash',
            'normaluser',
          ]),
          true,
        );
        expect(
          fake.wasCalledWith('chroot', [
            '/mnt',
            'useradd',
            '-m',
            '-s',
            '/bin/bash',
            '-G',
            'wheel',
            'normaluser',
          ]),
          false,
          reason: 'Normal kullanıcı yanlışlıkla wheel grubuna eklendi',
        );
        expect(
          fake.commandLog.any(
            (cmd) =>
                cmd.command == 'chroot' &&
                cmd.args.contains('/etc/sudoers.d/normaluser'),
          ),
          false,
          reason: 'Normal kullanıcı için sudoers dosyası yazılmamalı',
        );
      },
    );

    test(
      'secilen locale timezone ve grafik klavye ayarlari hedef sisteme yazilir',
      () async {
        final fake = FakeCommandRunner();
        final state = {
          'username': 'jpuser',
          'password': '1234',
          'isAdministrator': false,
          'selectedLanguage': 'ja',
          'selectedLocale': 'ja_JP.UTF-8',
          'selectedTimezone': 'Asia/Tokyo',
          'selectedKeyboard': 'uk',
        };
        final ctx = makeContext(state, fake);

        final stage = const ChrootConfigStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
        expect(
          fake.wasCalledWith('chroot', [
            '/mnt',
            'dnf',
            'install',
            '-y',
            'glibc-langpack-ja',
            'langpacks-ja',
          ]),
          true,
          reason: 'Seçilen dil için gerekli paketler kurulmadı',
        );
        expect(
          fake.wasCalledWith('chroot', [
            '/mnt',
            'ln',
            '-sf',
            '/usr/share/zoneinfo/Asia/Tokyo',
            '/etc/localtime',
          ]),
          true,
          reason: 'Timezone ayarı hedef sisteme yazılmadı',
        );
        expect(
          fake.wasCalledWith('chroot', [
            '/mnt',
            'sh',
            '-c',
            'echo "KEYMAP=uk" > /etc/vconsole.conf',
          ]),
          true,
          reason: 'Console klavye düzeni yazılmadı',
        );
        expect(
          fake.commandLog.any(
            (cmd) =>
                cmd.command == 'chroot' &&
                cmd.args
                    .join(' ')
                    .contains('/etc/X11/xorg.conf.d/00-keyboard.conf') &&
                cmd.args.join(' ').contains('Option "XkbLayout" "gb"'),
          ),
          true,
          reason: 'Grafik oturum klavye düzeni yazılmadı',
        );
      },
    );

    test('dil destek paketleri kurulamazsa stage hata ile durur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'chroot',
        ['/mnt', 'dnf', 'install', '-y', 'glibc-langpack-ja', 'langpacks-ja'],
        exitCode: 1,
        stderr: 'dnf failed',
      );

      final ctx = makeContext(const {
        'selectedLanguage': 'ja',
        'selectedLocale': 'ja_JP.UTF-8',
      }, fake);
      final stage = const ChrootConfigStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        result.message,
        'Secilen dil destek paketleri kurulamadı: glibc-langpack-ja, langpacks-ja',
      );
    });

    test('bind mount başarısız olursa stage hata ile durur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'mount',
        ['--rbind', '/dev', '/mnt/dev'],
        exitCode: 32,
        stderr: 'mount failed',
      );

      final ctx = makeContext(const {}, fake);
      final stage = const ChrootConfigStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, '/dev bağı hedef sisteme aktarılamadı.');
    });

    test('useradd başarısız olursa stage hata ile durur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'chroot',
        ['/mnt', 'useradd', '-m', '-s', '/bin/bash', '-G', 'wheel', 'testuser'],
        exitCode: 1,
        stderr: 'useradd failed',
      );

      final state = {
        'username': 'testuser',
        'password': 'testpassword',
        'isAdministrator': true,
      };
      final ctx = makeContext(state, fake);

      final stage = const ChrootConfigStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, 'Kullanıcı hesabı oluşturulamadı: testuser');
    });

    test('fstab üretimi başarısız olursa stage hata ile durur', () async {
      final fake = FakeCommandRunner();
      fake.addResponseForCommand('sh', exitCode: 1, stderr: 'fstab failed');

      final ctx = makeContext(const {}, fake);
      final stage = const ChrootConfigStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, '/etc/fstab üretilemedi.');
    });

    test(
      'tam disk btrfs kurulumda fstab sadece hedef girdilerini üretir',
      () async {
        final fake = FakeCommandRunner();
        final ctx = makeContext({
          'selectedDisk': '/dev/vda',
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
        }, fake);

        final stage = const ChrootConfigStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final fstabWrite = fake.commandLog.firstWhere(
          (cmd) =>
              cmd.command == 'sh' &&
              cmd.args.join(' ').contains("cat > /mnt/etc/fstab << 'EOF'"),
        );
        final fstabScript = fstabWrite.args.join(' ');

        expect(
          fstabScript,
          contains(
            'UUID=MOCK-VDA2 / btrfs defaults,compress=zstd:1,subvol=@ 0 0',
          ),
        );
        expect(
          fstabScript,
          contains(
            'UUID=MOCK-VDA2 /home btrfs defaults,compress=zstd:1,subvol=@home 0 0',
          ),
        );
        expect(
          fstabScript,
          contains(
            'UUID=MOCK-VDA1 /boot/efi vfat umask=0077,shortname=winnt 0 2',
          ),
        );
        expect(fstabScript, isNot(contains('/run/initramfs/live')));
        expect(fstabScript, isNot(contains('/dev/sr0')));
        expect(fstabScript, isNot(contains('zram')));
      },
    );

    test(
      'manuel btrfs root icin ayri /home yoksa @home fstab girdisi olusur',
      () async {
        final fake = FakeCommandRunner();
        final ctx = makeContext({
          'partitionMethod': 'manual',
          'manualPartitions': [
            {
              'name': '/dev/vda2',
              'type': 'btrfs',
              'mount': '/',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': true,
            },
            {
              'name': '/dev/vda1',
              'type': 'fat32',
              'mount': '/boot/efi',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': false,
            },
            {
              'name': '/dev/vda3',
              'type': 'linux-swap',
              'mount': '[SWAP]',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': false,
            },
          ],
        }, fake);

        final stage = const ChrootConfigStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final fstabWrite = fake.commandLog.firstWhere(
          (cmd) =>
              cmd.command == 'sh' &&
              cmd.args.join(' ').contains("cat > /mnt/etc/fstab << 'EOF'"),
        );
        final fstabScript = fstabWrite.args.join(' ');

        expect(
          fstabScript,
          contains(
            'UUID=MOCK-VDA2 / btrfs defaults,compress=zstd:1,subvol=@ 0 0',
          ),
        );
        expect(
          fstabScript,
          contains(
            'UUID=MOCK-VDA2 /home btrfs defaults,compress=zstd:1,subvol=@home 0 0',
          ),
        );
        expect(
          fstabScript,
          contains(
            'UUID=MOCK-VDA1 /boot/efi vfat umask=0077,shortname=winnt 0 2',
          ),
        );
        expect(fstabScript, contains('UUID=MOCK-VDA3 none swap defaults 0 0'));
      },
    );

    test(
      'manuel modda ayri /home varsa root altinda @home girdisi yazilmaz',
      () async {
        final fake = FakeCommandRunner();
        final ctx = makeContext({
          'partitionMethod': 'manual',
          'manualPartitions': [
            {
              'name': '/dev/vda2',
              'type': 'btrfs',
              'mount': '/',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': true,
            },
            {
              'name': '/dev/vda5',
              'type': 'ext4',
              'mount': '/home',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': true,
            },
            {
              'name': '/dev/vda4',
              'type': 'btrfs',
              'mount': '/boot',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': true,
            },
            {
              'name': '/dev/vda1',
              'type': 'fat32',
              'mount': '/boot/efi',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': false,
            },
            {
              'name': '/dev/vda3',
              'type': 'linux-swap',
              'mount': '[SWAP]',
              'isFreeSpace': false,
              'isPlanned': true,
              'formatOnInstall': false,
            },
          ],
        }, fake);

        final stage = const ChrootConfigStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        final fstabWrite = fake.commandLog.firstWhere(
          (cmd) =>
              cmd.command == 'sh' &&
              cmd.args.join(' ').contains("cat > /mnt/etc/fstab << 'EOF'"),
        );
        final fstabScript = fstabWrite.args.join(' ');

        expect(fstabScript, contains('UUID=MOCK-VDA5 /home ext4 defaults 0 2'));
        expect(
          fstabScript,
          isNot(
            contains(
              'UUID=MOCK-VDA2 /home btrfs defaults,compress=zstd:1,subvol=@home 0 0',
            ),
          ),
        );

        final bootIndex = fstabScript.indexOf(
          'UUID=MOCK-VDA4 /boot btrfs defaults 0 0',
        );
        final efiIndex = fstabScript.indexOf(
          'UUID=MOCK-VDA1 /boot/efi vfat umask=0077,shortname=winnt 0 2',
        );
        expect(bootIndex, greaterThanOrEqualTo(0));
        expect(efiIndex, greaterThanOrEqualTo(0));
        expect(bootIndex, lessThan(efiIndex));
      },
    );

    test(
      'vm test modu aciksa smoke service olusturulur ve etkinlestirilir',
      () async {
        final fake = FakeCommandRunner();
        final ctx = makeContext(const {'vmTestMode': true}, fake);

        final stage = const ChrootConfigStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
        expect(
          fake.commandLog.any(
            (cmd) =>
                cmd.command == 'sh' &&
                cmd.args
                    .join(' ')
                    .contains(
                      '/mnt/etc/systemd/system/ro-installer-vm-smoke.service',
                    ),
          ),
          true,
        );
        expect(
          fake.wasCalledWith('chroot', [
            '/mnt',
            'systemctl',
            'enable',
            'ro-installer-vm-smoke.service',
          ]),
          true,
        );
      },
    );
  });
}
