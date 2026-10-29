import 'dart:io';
import '../models/standard_storage_layout.dart';
import 'command_runner.dart';
import 'session_command_runner.dart';

class CleanupReport {
  const CleanupReport(
    this.success, {
    this.remaining = const [],
    this.reason = '',
  });
  final bool success;
  final List<String> remaining;
  final String reason;
}

class MountRecord {
  MountRecord(
    this.id,
    this.parent,
    this.device,
    this.root,
    this.target,
    this.type,
    this.source,
  );
  final int id, parent;
  final String device, root, target, type, source;
  bool same(MountRecord other) =>
      id == other.id &&
      parent == other.parent &&
      device == other.device &&
      root == other.root &&
      target == other.target &&
      type == other.type &&
      source == other.source;
  static String unescape(String value) => value.replaceAllMapped(
    RegExp(r'\\(040|011|012|134)'),
    (match) => String.fromCharCode(int.parse(match[1]!, radix: 8)),
  );
  static bool _canonical(String path) =>
      path == '/' ||
      (path.startsWith('/') &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) &&
          path
              .substring(1)
              .split('/')
              .every((p) => p.isNotEmpty && p != '.' && p != '..'));
  static List<MountRecord> parse(String text) {
    final result = <MountRecord>[];
    final ids = <int>{};
    for (final line in text.trim().split('\n')) {
      final fields = line.split(' ');
      final split = fields.indexOf('-');
      if (split < 6 ||
          fields.length != split + 4 ||
          fields
              .sublist(6, split)
              .any(
                (f) =>
                    f.startsWith('shared:') ||
                    f.startsWith('master:') ||
                    f.startsWith('propagate_from:'),
              )) {
        throw const FormatException('Invalid/private mount inventory');
      }
      final id = int.parse(fields[0]), parent = int.parse(fields[1]);
      final target = unescape(fields[4]);
      if (id <= 0 ||
          parent < 0 ||
          !ids.add(id) ||
          !target.startsWith('/') ||
          !_canonical(target) ||
          !_canonical(unescape(fields[3])) ||
          !RegExp(r'^\d+:\d+$').hasMatch(fields[2])) {
        throw const FormatException('Invalid mount identity');
      }
      result.add(
        MountRecord(
          id,
          parent,
          fields[2],
          unescape(fields[3]),
          target,
          fields[split + 1],
          unescape(fields[split + 2]),
        ),
      );
    }
    if (result.where((m) => m.target == '/').length != 1) {
      throw const FormatException('Missing/stacked root');
    }
    return result;
  }
}

abstract class MountSession {
  Future<void> initialize();
  Future<void> validateTarget(String disk, {bool commit = false});
  Future<void> assertEmpty();
  Future<bool> mount(List<String> args);
  Future<bool> unmount(String target);
  Future<CleanupReport> cleanup();
  static Future<MountSession> open(CommandRunner runner) async {
    if (runner is! SessionCommandRunner) {
      throw StateError('Isolated root session required');
    }
    final session = VerifiedMountSession(
      runner,
      inventory: () => File('/proc/self/mountinfo').readAsString(),
      namespace: () => Link('/proc/self/ns/mnt').target(),
      control: runner.control,
    );
    return session;
  }
}

/// Ownership is established by the isolated, private session, NOT snapshot
/// differences alone. Injected readers are for controlled tests, never GUI input.
class VerifiedMountSession implements MountSession {
  VerifiedMountSession(
    this.runner, {
    required this.inventory,
    required this.namespace,
    required this.control,
  });
  final CommandRunner runner;
  final Future<String> Function() inventory, namespace;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) control;
  final Map<int, MountRecord> _owned = {};
  String? _namespace, _disk;
  bool _unsafe = false, _attempted = false, _verified = false;
  CleanupReport? _report;
  static bool below(String path, String root) =>
      path == root || path.startsWith('$root/');
  Future<List<MountRecord>> _read() async {
    if (_namespace == null || await namespace() != _namespace) {
      throw StateError('Session namespace changed');
    }
    return MountRecord.parse(await inventory());
  }

  List<MountRecord> _targets(List<MountRecord> rows) =>
      rows.where((m) => below(m.target, '/mnt')).toList();
  bool _known(List<MountRecord> rows) {
    final targets = _targets(rows);
    return targets.length == _owned.length &&
        targets.every((m) => _owned[m.id]?.same(m) == true);
  }

  @override
  Future<void> initialize() async {
    final description = await control({'op': 'describe'});
    _namespace = await namespace();
    if (description['namespace'] != _namespace ||
        description['parentNamespace'] == _namespace ||
        description['lease'] != true ||
        description['targetSafe'] != true) {
      throw StateError('Unverified isolated root session');
    }
    await assertEmpty();
    _verified = true;
  }

  @override
  Future<void> assertEmpty() async {
    if (_targets(await _read()).isNotEmpty) {
      throw StateError('Foreign target mounts; no mutation allowed');
    }
  }

  @override
  Future<void> validateTarget(String disk, {bool commit = false}) async {
    await assertEmpty();
    final value = await control({
      'op': 'validate-target',
      'disk': disk,
      'commit': commit,
    });
    if (value['device'] is! Map || value['device']['path'] != disk) {
      throw StateError('Target identity rejected');
    }
    if (commit && disk != _disk) throw StateError('Target identity changed');
    _disk = disk;
  }

  String _part(int n) =>
      '${_disk!}${_disk!.contains('nvme') || _disk!.contains('mmcblk') || _disk!.contains('loop') ? 'p' : ''}$n';

  @override
  Future<bool> mount(List<String> args) async {
    if (!_verified || _attempted || _unsafe || _disk == null) return false;
    final target = args.isEmpty ? '' : args.last;
    final private = args.length == 2 && args.first == '--make-rprivate';
    final bind =
        args.length == 3 &&
        args.first == '--rbind' &&
        const ['/dev', '/proc', '/sys', '/run'].contains(args[1]) &&
        target == '/mnt${args[1]}';
    final tmp = args.join(' ') == '-t tmpfs tmpfs /mnt/tmp';
    final rootOptions = [
      'subvolid=5',
      ...StandardStorageLayout.subvolumes.keys.map(
        StandardStorageLayout.mountOptions,
      ),
    ];
    final root =
        args.length == 4 &&
        args[0] == '-o' &&
        rootOptions.contains(args[1]) &&
        args[2] == _part(2) &&
        const [
          '/mnt',
          '/mnt/home',
          '/mnt/var/log',
          '/mnt/var/cache',
          '/mnt/var/tmp',
        ].contains(target);
    final efi =
        args.length == 2 && args[0] == _part(1) && target == '/mnt/boot/efi';
    if (!bind && !tmp && !root && !efi && !private) return false;
    List<MountRecord> before;
    try {
      before = await _read();
      if (!_known(before) ||
          (private
              ? !_owned.values.any((m) => m.target == target)
              : before.any((m) => m.target == target))) {
        _unsafe = true;
        return false;
      }
    } catch (_) {
      _unsafe = true;
      return false;
    }
    String? device;
    if (root || efi) {
      final read = await runner.run('lsblk', [
        '-dnro',
        'MAJ:MIN',
        root ? _part(2) : _part(1),
      ]);
      device = read.stdout.trim();
      if (!read.started ||
          read.exitCode != 0 ||
          !RegExp(r'^\d+:\d+$').hasMatch(device)) {
        return false;
      }
    }
    var ok = false;
    try {
      final result = await runner.run('mount', args);
      ok = result.started && result.exitCode == 0;
    } catch (_) {
      ok = false;
    }
    try {
      final after = await _read();
      final old = {for (final m in before) m.id: m};
      final fresh = _targets(
        after,
      ).where((m) => !old.containsKey(m.id)).toList();
      if (_targets(
            after,
          ).any((m) => old.containsKey(m.id) && !old[m.id]!.same(m)) ||
          _owned.values.any((m) => !after.any((n) => n.same(m)))) {
        _unsafe = true;
        return false;
      }
      for (final m in fresh) {
        final sourceMatches = bind
            ? before.any(
                (s) =>
                    s.target ==
                        '${args[1]}${m.target.substring(target.length)}' &&
                    s.device == m.device &&
                    s.root == m.root &&
                    s.type == m.type &&
                    s.source == m.source,
              )
            : tmp
            ? m.type == 'tmpfs' && m.target == target
            : m.device == device &&
                  m.target == target &&
                  m.root ==
                      (root && args[1] != 'subvolid=5'
                          ? '/${args[1].split('subvol=').last}'
                          : '/') &&
                  m.type == (root ? 'btrfs' : 'vfat');
        if (!below(m.target, target) || !sourceMatches || private) {
          _unsafe = true;
          return false;
        }
        _owned[m.id] = m; // Includes partial mount/rbind failure resources.
      }
      if (!private && !fresh.any((m) => m.target == target)) return false;
      return ok;
    } catch (_) {
      _unsafe = true;
      return false;
    }
  }

  @override
  Future<bool> unmount(String target) async {
    if (!_verified) return false;
    try {
      if ((await control({'op': 'idle'}))['idle'] != true) return false;
      final rows = await _read();
      final match = _owned.values.where((m) => m.target == target).toList();
      if (_unsafe ||
          !_known(rows) ||
          match.length != 1 ||
          rows.any((m) => m.target != target && below(m.target, target))) {
        return false;
      }
      final result = await runner.run('umount', [target]);
      final after = await _read();
      if (after.any((m) => m.id == match.single.id || m.target == target)) {
        return false;
      }
      _owned.remove(match.single.id);
      return result.started && result.exitCode == 0 && _known(after);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<CleanupReport> cleanup() async {
    if (!_verified) {
      return const CleanupReport(
        false,
        reason: 'Session initialization not verified',
      );
    }
    if (_attempted && _report?.success == false) return _report!;
    try {
      final rows = await _read();
      if (_unsafe || !_known(rows)) {
        _attempted = true;
        return _report = const CleanupReport(
          false,
          reason: 'Unverified mount ownership; no unmount attempted',
        );
      }
      if (_attempted) {
        return _report ??
            const CleanupReport(false, reason: 'Cleanup already attempted');
      }
      _attempted = true;
      if ((await control({'op': 'idle'}))['idle'] != true) {
        return _report = const CleanupReport(
          false,
          reason: 'Session children still active',
        );
      }
      var ok = true;
      final mounts = _owned.values.toList()
        ..sort(
          (a, b) =>
              b.target.split('/').length.compareTo(a.target.split('/').length),
        );
      for (final mount in mounts) {
        if (!await unmount(mount.target)) ok = false;
      }
      final remaining = _targets(await _read()).map((m) => m.target).toList();
      final idle = await control({'op': 'idle'});
      _report = CleanupReport(
        ok && remaining.isEmpty && idle['idle'] == true,
        remaining: remaining,
        reason: ok && remaining.isEmpty ? '' : 'Session cleanup incomplete',
      );
      return _report!;
    } catch (_) {
      return _report = const CleanupReport(
        false,
        reason: 'Session cleanup verification failed',
      );
    }
  }
}

/// Only explicit isMock/injected unit contexts use this implementation.
/// It provides no Linux namespace/ownership evidence and is never GUI-selectable.
class SimulatedMountSession implements MountSession {
  SimulatedMountSession(this.runner);
  final CommandRunner runner;
  final List<String> _targets = [];
  CleanupReport? _cached;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> assertEmpty() async {}
  @override
  Future<void> validateTarget(String disk, {bool commit = false}) async {}
  @override
  Future<bool> mount(List<String> args) async {
    final result = await runner.run('mount', args);
    final ok = result.started && result.exitCode == 0;
    if (ok && !args.first.startsWith('--make-')) _targets.add(args.last);
    return ok;
  }

  @override
  Future<bool> unmount(String target) async {
    final result = await runner.run('umount', [target]);
    if (result.started && result.exitCode == 0) {
      _targets.remove(target);
      return true;
    }
    return false;
  }

  @override
  Future<CleanupReport> cleanup() async {
    if (_cached != null) return _cached!;
    var ok = true;
    for (final target in _targets.reversed.toList()) {
      if (!await unmount(target)) ok = false;
    }
    return _cached = CleanupReport(
      ok && _targets.isEmpty,
      remaining: List.of(_targets),
    );
  }
}
