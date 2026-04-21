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
