import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/mount_session.dart';

/// Synthetic kernel mount graph; no mount syscall or physical device IO.
class MountGraph extends FakeCommandRunner {
  final rows = <MountRecord>[
    MountRecord(1, 0, '0:1', '/', '/', 'overlay', 'LiveOS_rootfs'),
    MountRecord(2, 1, '0:2', '/', '/dev', 'devtmpfs', 'devtmpfs'),
    MountRecord(3, 2, '0:3', '/', '/dev/pts', 'devpts', 'devpts'),
  ];
  int next = 20;
  String ns = 'mnt:[2]';
  final failedMountTargets = <String>{};
  bool targetSafe = true,
      lease = true,
      idle = true,
      partialBind = false,
      throwAfterMount = false,
      failInventory = false;
  final busy = <String>{};
  int unmounts = 0;
  String text() => rows
      .map(
        (m) =>
            '${m.id} ${m.parent} ${m.device} ${m.root} ${m.target} rw - ${m.type} ${m.source} rw',
      )
      .join('\n');
  Future<String> inventory() async {
    if (failInventory) throw StateError('synthetic inventory failure');
    return text();
  }

  Future<Map<String, dynamic>> control(Map<String, dynamic> request) async {
    if (request['op'] == 'describe') {
      return {
        'namespace': 'mnt:[2]',
        'parentNamespace': 'mnt:[1]',
        'lease': lease,
        'targetSafe': targetSafe,
      };
    }
    if (request['op'] == 'idle') return {'idle': idle};
    return {
      'device': {'path': request['disk']},
    };
  }

  VerifiedMountSession session() => VerifiedMountSession(
    this,
    inventory: inventory,
    namespace: () async => ns,
    control: control,
  );
  void add(
    String target, {
    String device = '8:2',
    String root = '/root',
    String type = 'btrfs',
    String source = '/dev/fixture2',
  }) {
    final parents =
        rows
            .where(
              (r) => target.startsWith('${r.target == '/' ? '' : r.target}/'),
            )
            .toList()
          ..sort((a, b) => b.target.length.compareTo(a.target.length));
    rows.add(
      MountRecord(next++, parents.first.id, device, root, target, type, source),
    );
  }

  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    if (command != 'mount' &&
        command != 'umount' &&
        !(command == 'lsblk' && args.first == '-dnro')) {
      return super.run(
        command,
        args,
        isMock: isMock,
        onLog: onLog,
        timeout: timeout,
        stdinText: stdinText,
      );
    }
    commandLog.add(RecordedCommand(command: command, args: args));
    var status = 0, output = '';
    if (command == 'lsblk') {
      output = args.last.endsWith('1') ? '8:1' : '8:2';
    } else if (command == 'mount') {
      if (failedMountTargets.contains(args.last)) {
        return CommandResult(
          command: command,
          args: args,
          exitCode: 1,
          stdout: '',
          stderr: '',
          started: true,
        );
      }
      if (args.first == '--rbind') {
        final original = rows
            .where(
              (r) => r.target == args[1] || r.target.startsWith('${args[1]}/'),
            )
            .toList();
        for (final row in original) {
          add(
            '${args.last}${row.target.substring(args[1].length)}',
            device: row.device,
            root: row.root,
            type: row.type,
            source: row.source,
          );
        }
        if (partialBind) status = 23;
      } else if (!args.first.startsWith('--make-')) {
        add(
          args.last,
          device: args.first == '-t'
              ? '0:77'
              : args.last == '/mnt/boot/efi'
              ? '8:1'
              : '8:2',
          root: args.contains('subvolid=5')
              ? '/'
              : args.last == '/mnt/boot/efi' || args.first == '-t'
              ? '/'
              : '/${args[1].split('subvol=').last}',
          type: args.first == '-t'
              ? 'tmpfs'
              : args.last == '/mnt/boot/efi'
              ? 'vfat'
              : 'btrfs',
          source: args.first == '-t'
              ? 'tmpfs'
              : args.last == '/mnt/boot/efi'
              ? '/dev/fixture1'
              : '/dev/fixture2',
        );
      }
      if (throwAfterMount) {
        throw StateError('synthetic mount transport exception');
      }
    } else if (command == 'umount') {
      unmounts++;
      if (busy.contains(args.single)) {
        status = 1;
      } else {
        rows.removeWhere((r) => r.target == args.single);
      }
    } else {
      throw StateError('Unexpected command $command');
    }
    return CommandResult(
      command: command,
      args: args,
      exitCode: status,
      stdout: output,
      stderr: '',
      started: true,
    );
  }
}
