import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:test/test.dart';

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

const _manualCreateLayout = '''
{
  "blockdevices": [
    {
      "name": "sda",
      "path": "/dev/sda",
      "type": "disk",
      "size": 68719476736,
      "children": [
        {
          "name": "sda1",
          "path": "/dev/sda1",
          "type": "part",
          "size": 536870912,
          "start": 2048,
          "fstype": "vfat"
        }
      ]
    }
  ]
}''';

const _manualTrimLayout = '''
{
  "blockdevices": [
    {
      "name": "sda",
      "path": "/dev/sda",
      "type": "disk",
      "size": 44023414784,
      "children": [
        {
          "name": "sda1",
          "path": "/dev/sda1",
          "type": "part",
          "size": 32531021824,
          "start": 2048,
          "fstype": "ntfs"
        }
      ]
    }
  ]
}''';

void main() {
  group('PartitioningStage - Manual Mode', () {
    test('eski bolumler silinir, yeniler sektor bazli eklenir', () async {
      final fake = FakeCommandRunner();

      fake.addResponse(
        'lsblk',
        ['-rn', '-o', 'NAME,TYPE', '/dev/sda'],
        stdout: '''
sda disk
sda1 part
sda2 part
''',
      );
      fake.addResponse('blockdev', ['--getss', '/dev/sda'], stdout: '512');
      fake.addResponse('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,PATH,TYPE,SIZE,START,FSTYPE',
        '/dev/sda',
      ], stdout: _manualCreateLayout);
      fake.addResponse(
        'lsblk',
        ['-rn', '-o', 'NAME,TYPE', '/dev/sda'],
        stdout: '''
sda disk
sda1 part
sda3 part
''',
      );

      final manualParts = [
        {
          'name': '/dev/sda1',
          'type': 'fat32',
          'mount': '/boot/efi',
          'isFreeSpace': false,
          'isPlanned': false,
          'formatOnInstall': false,
          'sizeBytes': 536870912,
        },
        {
          'name': 'New Partition 1',
          'type': 'ext4',
          'mount': '/',
          'isFreeSpace': false,
          'isPlanned': true,
          'formatOnInstall': true,
          'sizeBytes': 50000000000,
        },
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

      expect(
        fake.wasCalledWith('sgdisk', ['-d', '1', '/dev/sda']),
        false,
        reason: 'sda1 korundugu halde silindi',
      );
      expect(
        fake.wasCalledWith('sgdisk', ['-d', '2', '/dev/sda']),
        true,
        reason: 'sda2 plandan cikarildigi halde silinmedi',
      );
      expect(
        fake.wasCalledWith('sgdisk', [
          '-n',
          '0:1050624:98706873',
          '-t',
          '0:8300',
          '/dev/sda',
        ]),
        true,
        reason: 'Yeni bolum sektor bazli planla olusturulmadi',
      );
      expect(
        manualParts[1]['name'],
        '/dev/sda3',
        reason: 'Yeni bolumun referans adi guncellenmedi',
      );
    });

    test(
      'son bos alanda tasan istek guvenli sinira otomatik kisilir',
      () async {
        final fake = FakeCommandRunner();

        fake.addResponse(
          'lsblk',
          ['-rn', '-o', 'NAME,TYPE', '/dev/sda'],
          stdout: '''
sda disk
sda1 part
''',
        );
        fake.addResponse('blockdev', ['--getss', '/dev/sda'], stdout: '512');
        fake.addResponse('lsblk', [
          '-J',
          '-b',
          '-o',
          'NAME,PATH,TYPE,SIZE,START,FSTYPE',
          '/dev/sda',
        ], stdout: _manualTrimLayout);
        fake.addResponse(
          'lsblk',
          ['-rn', '-o', 'NAME,TYPE', '/dev/sda'],
          stdout: '''
sda disk
sda1 part
sda2 part
''',
        );

        final manualParts = [
          {
            'name': '/dev/sda1',
            'type': 'ntfs',
            'mount': 'unmounted',
            'isFreeSpace': false,
            'isPlanned': false,
            'formatOnInstall': false,
            'sizeBytes': 32531021824,
          },
          {
            'name': 'New Partition',
            'type': 'linux-swap',
            'mount': '[SWAP]',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': true,
            'sizeBytes': 10960 * 1024 * 1024,
          },
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
        expect(
          fake.wasCalledWith('sgdisk', [
            '-n',
            '0:63539200:85983198',
            '-t',
            '0:8200',
            '/dev/sda',
          ]),
          true,
        );
        expect(
          manualParts[1]['sizeBytes'],
          (85983198 - 63539200 + 1) * 512,
          reason: 'Gercek olusan boyut state icinde saklanmali',
        );
      },
    );
  });
}
