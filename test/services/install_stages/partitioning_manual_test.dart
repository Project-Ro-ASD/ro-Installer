import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';
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
    runCmd: (cmd, args, onLog, {bool isMock = false, List<int> allowedExitCodes = const [0]}) async {
      final result = await runner.run(cmd, args);
      return allowedExitCodes.contains(result.exitCode);
    },
    isMock: isMock,
  );
}

void main() {
  group('PartitioningStage - Manual Mode', () {
    test('eski bölümler silinir, yeniler eklenir', () async {
      final fake = FakeCommandRunner();
      
      // 1. lsblk mock'u (mevcut bölümler: sda1 ve sda2)
      fake.addResponse('lsblk', ['-rn', '-o', 'NAME,TYPE', '/dev/sda'], stdout: '''
sda disk
sda1 part
sda2 part
''');

      // 2. Yeni bölüm eklendikten sonraki lsblk mock'u (sda1, sda3)
      // sda2 silinmiş, sda3 eklenmiş gibi davranalım
      fake.addResponse('lsblk', ['-rn', '-o', 'NAME,TYPE', '/dev/sda'], stdout: '''
sda disk
sda1 part
sda3 part
''');

      final manualParts = [
        // sda1 korundu (kullanıcı silmedi)
        {'name': '/dev/sda1', 'type': 'fat32', 'mount': '/boot/efi', 'isFreeSpace': false, 'isPlanned': false, 'sizeBytes': 500000000},
        // sda2 silindi, onun yerine yeni bölüm eklendi
        {'name': 'New Partition 1', 'type': 'ext4', 'mount': '/', 'isFreeSpace': false, 'isPlanned': true, 'sizeBytes': 50000000000},
      ];

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'manualPartitions': manualParts,
      };

      final ctx = makeContext(state, fake, isMock: true);
      final stage = const PartitioningStage();
      
      final result = await stage.execute(ctx);
      expect(result.success, true);

      // sda1 korunmalı, sgdisk -d 1 çalışMAMALI
      expect(fake.wasCalledWith('sgdisk', ['-d', '1', '/dev/sda']), false, reason: 'sda1 korunduğu halde silindi');
      
      // sda2 listede yok, sgdisk -d 2 çalışmalı
      expect(fake.wasCalledWith('sgdisk', ['-d', '2', '/dev/sda']), true, reason: 'sda2 plandan çıkarıldığı halde silinmedi');
      
      // New Partition 1 için sgdisk -n çalışmalı (50000000000 bytes ≈ 47684 MB)
      expect(fake.commandLog.any((c) => c.command == 'sgdisk' && c.args.contains('-n') && c.args.contains('0:0:+47684M')), true, reason: 'Yeni bölüm oluşturulmadı');

      // Manuel partition listesinde adı güncellendi mi?
      // Mock modda lsblk sonucu döndüğünde cand '/dev/sda3' aktifPartNames'de yok, bu yüzden atanmalı.
      expect(manualParts[1]['name'], '/dev/sda3', reason: 'Yeni bölümün referans adı güncellenmedi');
    });
  });
}
