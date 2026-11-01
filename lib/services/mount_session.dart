import 'dart:convert';
import 'helper_protocol.dart';
import '../models/approved_full_disk_plan.dart';
import 'dart:io';
import '../models/approved_free_space_plan.dart';
import '../models/approved_manual_plan.dart';
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
    this.source, [
    Iterable<String> options = const ['rw'],
  ]) : options = Set.unmodifiable(options);
  final Set<String> options;
  final int id, parent;
  final String device, root, target, type, source;
  bool sameIdentity(MountRecord other) =>
      id == other.id &&
      parent == other.parent &&
      device == other.device &&
      root == other.root &&
      target == other.target &&
      type == other.type &&
      source == other.source;
  bool same(MountRecord other) =>
      sameIdentity(other) &&
      options.length == other.options.length &&
      options.containsAll(other.options);
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
      final options = fields[5].split(',');
      if (options.toSet().length != options.length ||
          options.any((o) => o.isEmpty) ||
          options.contains('ro') == options.contains('rw')) {
        throw const FormatException('Invalid mount options');
      }
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
          fields[5].split(','),
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
  void bindCreatedManualLayout(CreatedManualLayout layout);
  Future<bool> mountReadOnlyEspProbe(ApprovedManualPlan plan);
  Future<bool> inspectEspReuse(ApprovedManualPlan plan);
  Future<bool> finishEspProbe();
  Future<bool> mountProtectedEsp();
  Future<bool> verifyProtectedEsp();
  void bindCreatedFreeSpaceLayout(CreatedFreeSpaceLayout layout);
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
  CreatedFreeSpaceLayout? _freeLayout;
  CreatedManualLayout? _manualLayout;
  ApprovedManualPlan? _espProbe, _espInspected;
  bool _espProtected = false, _preparingEsp = false;
  static const espProbeTarget = '/mnt/.ro-installer-esp-probe';
  static const espStageTarget = '/mnt/.ro-installer-esp-stage';
  static const espTarget = '/mnt/boot/efi';
  static const espOwnedTarget = '/mnt/boot/efi/EFI/fedora';
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

  String _part(int n) => _manualLayout != null
      ? (n == 1 ? _manualLayout!.espPath : _manualLayout!.rootPath)
      : _freeLayout != null
      ? (n == 1 ? _freeLayout!.espPath : _freeLayout!.rootPath)
      : '${_disk!}${_disk!.contains('nvme') || _disk!.contains('mmcblk') || _disk!.contains('loop') ? 'p' : ''}$n';
  @override
  void bindCreatedFreeSpaceLayout(CreatedFreeSpaceLayout layout) {
    if (!_verified ||
        _attempted ||
        _unsafe ||
        _owned.isNotEmpty ||
        _disk != layout.snapshot.device.path ||
        _freeLayout != null ||
        _manualLayout != null ||
        _espProbe != null ||
        _espInspected != null) {
      throw StateError('Cannot bind an unverified storage layout');
    }
    _freeLayout = layout;
  }

  @override
  void bindCreatedManualLayout(CreatedManualLayout layout) {
    if (!_verified ||
        _attempted ||
        _unsafe ||
        _owned.isNotEmpty ||
        _disk != layout.snapshot.device.path ||
        _freeLayout != null ||
        _manualLayout != null ||
        _espProbe != null) {
      throw StateError('Cannot bind an unverified manual layout');
    }
    if ((layout.reusesEsp && _espInspected == null) ||
        (_espInspected != null &&
            !samePlanValue(_espInspected!.json, layout.approved.json))) {
      throw StateError('Reusable ESP preflight is missing or stale');
    }
    _manualLayout = layout;
  }

  Future<bool> _checked(String command, List<String> args) async {
    final result = await runner.run(command, args);
    return result.started && result.exitCode == 0;
  }

  @override
  Future<bool> mountReadOnlyEspProbe(ApprovedManualPlan plan) async {
    if (!_verified ||
        _attempted ||
        _unsafe ||
        _owned.isNotEmpty ||
        _espProbe != null ||
        _manualLayout != null ||
        _freeLayout != null ||
        _disk != plan.plan.snapshot.device.path ||
        plan.plan.esp.formatOnInstall ||
        plan.plan.esp.existingPartition == null) {
      return false;
    }
    _espProbe = plan;
    try {
      if (!await _checked('mkdir', ['-p', espProbeTarget])) return false;
      return await mount([
        '-t',
        'vfat',
        '-o',
        'ro,nosuid,nodev,noexec',
        plan.plan.esp.target,
        espProbeTarget,
      ]);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> finishEspProbe() async {
    if (_espProbe == null || !await unmount(espProbeTarget)) return false;
    _espProbe = null;
    return true;
  }

  Future<bool> _hasEspSpace(String target, String device) async {
    final result = await runner.run('/usr/bin/python3', [
      '-I',
      '/usr/libexec/ro_installer_manual.py',
      '--efi-budget',
      target,
      device,
    ], timeout: const Duration(seconds: 10));
    if (result.started &&
        result.exitCode == 0 &&
        utf8.encode(result.stdout).length <= 4096) {
      final value = decodeProtocolObject(result.stdout);
      return exactFields(value, {
            'requiredBytes',
            'availableBytes',
            'sourceBytes',
            'fileCount',
            'clusterBytes',
            'sufficient',
          }) &&
          value['requiredBytes'] is int &&
          value['requiredBytes'] >= 16 * 1024 * 1024 &&
          value['requiredBytes'] <= 9007199254740991 &&
          value['availableBytes'] is int &&
          value['availableBytes'] >= value['requiredBytes'] &&
          value['availableBytes'] <= 9007199254740991 &&
          value['sourceBytes'] is int &&
          value['sourceBytes'] > 0 &&
          value['sourceBytes'] <= 1024 * 1024 * 1024 &&
          value['requiredBytes'] >= value['sourceBytes'] + 16 * 1024 * 1024 &&
          value['fileCount'] is int &&
          value['fileCount'] >= 2 &&
          value['fileCount'] <= 4096 &&
          value['clusterBytes'] is int &&
          value['clusterBytes'] >= 512 &&
          value['clusterBytes'] <= 1024 * 1024 &&
          (value['clusterBytes'] & (value['clusterBytes'] - 1)) == 0 &&
          value['sufficient'] == true;
    }
    return false;
  }

  @override
  Future<bool> inspectEspReuse(ApprovedManualPlan plan) async {
    if (_espInspected != null) return false;
    var valid = false;
    try {
      if (await mountReadOnlyEspProbe(plan)) {
        final rows = await _read();
        if (!_known(rows)) throw StateError('ESP probe ownership changed');
        final mounted = rows.singleWhere((m) => m.target == espProbeTarget);
        if (!await _exists('-e', '$espProbeTarget/EFI/fedora') &&
            !await _exists('-L', '$espProbeTarget/EFI/fedora') &&
            (!await _exists('-e', '$espProbeTarget/EFI') ||
                await _exists('-d', '$espProbeTarget/EFI'))) {
          valid = await _hasEspSpace(espProbeTarget, mounted.device);
        }
      }
    } catch (_) {
      valid = false;
    }
    final closed = _espProbe != null && await finishEspProbe();
    if (valid && closed) _espInspected = plan;
    return valid && closed;
  }

  Future<bool> _exists(String flag, String path) async {
    final result = await runner.run('test', [flag, path]);
    if (!result.started || !const [0, 1].contains(result.exitCode)) {
      throw StateError('ESP inspection failed');
    }
    return result.exitCode == 0;
  }

  Future<bool> _remountEspReadOnly() async {
    final before = await _read();
    if (!_known(before)) return false;
    final original = _owned.values.singleWhere((m) => m.target == espTarget);
    var ok = false;
    try {
      ok = await _checked('mount', [
        '-o',
        'remount,bind,ro,nosuid,nodev,noexec',
        espTarget,
      ]);
    } catch (_) {
      /* Reconcile partial remount before cleanup. */
    }
    final after = await _read();
    final rows = after.where((m) => m.id == original.id).toList();
    if (rows.length != 1 ||
        !rows.single.sameIdentity(original) ||
        _targets(after).length != _owned.length ||
        _owned.values
            .where((m) => m.id != original.id)
            .any((m) => !after.any((n) => n.same(m)))) {
      _unsafe = true;
      return false;
    }
    final current = rows.single;
    _owned[current.id] = current;
    return ok &&
        current.options.containsAll({'ro', 'nosuid', 'nodev', 'noexec'}) &&
        !current.options.contains('rw');
  }

  @override
  Future<bool> mountProtectedEsp() async {
    if (!_verified ||
        _attempted ||
        _unsafe ||
        _espProtected ||
        _espProbe != null ||
        _manualLayout?.reusesEsp != true ||
        !_owned.values.any((m) => m.target == '/mnt' && m.type == 'btrfs') ||
        _owned.values.any(
          (m) => const [
            espTarget,
            espOwnedTarget,
            espStageTarget,
            espProbeTarget,
          ].contains(m.target),
        )) {
      return false;
    }
    _preparingEsp = true;
    try {
      if (!await _checked('mkdir', ['-p', espStageTarget, espTarget])) {
        return false;
      }
      if (!await mount([
        '-t',
        'vfat',
        '-o',
        'rw,nosuid,nodev,noexec,umask=0077',
        _part(1),
        espStageTarget,
      ])) {
        return false;
      }
      final rows = await _read();
      if (!_known(rows)) return false;
      final staged = rows.singleWhere((m) => m.target == espStageTarget);
      if (!await _hasEspSpace(espStageTarget, staged.device)) return false;
      // FAT lookup is case insensitive. Never take over an existing namespace.
      if (await _exists('-e', '$espStageTarget/EFI/fedora') ||
          await _exists('-L', '$espStageTarget/EFI/fedora')) {
        return false;
      }
      if (await _exists('-e', '$espStageTarget/EFI') &&
          !await _exists('-d', '$espStageTarget/EFI')) {
        return false;
      }
      if (!_known(await _read())) return false;
      if (!await _checked('mkdir', ['-p', '$espStageTarget/EFI']) ||
          !await _checked('mkdir', ['$espStageTarget/EFI/fedora'])) {
        return false;
      }
      if (!await mount(['--bind', espStageTarget, espTarget]) ||
          !await _remountEspReadOnly()) {
        return false;
      }
      if (!await mount([
        '--bind',
        '$espStageTarget/EFI/fedora',
        espOwnedTarget,
      ])) {
        return false;
      }
      // No full writable view may remain reachable when chroot work begins.
      if (!await unmount(espStageTarget)) return false;
      _espProtected = true;
      return await verifyProtectedEsp();
    } catch (_) {
      return false;
    } finally {
      _preparingEsp = false;
    }
  }

  @override
  Future<bool> verifyProtectedEsp() async {
    if (!_espProtected || _manualLayout?.reusesEsp != true) return false;
    try {
      final rows = await _read();
      if (!_known(rows) ||
          rows.any(
            (m) => m.target == espStageTarget || m.target == espProbeTarget,
          )) {
        return false;
      }
      final bases = rows.where((m) => m.target == espTarget).toList();
      final owned = rows.where((m) => m.target == espOwnedTarget).toList();
      if (bases.length != 1 || owned.length != 1) return false;
      final base = bases.single, child = owned.single;
      return base.root == '/' &&
          base.type == 'vfat' &&
          base.options.containsAll({'ro', 'nosuid', 'nodev', 'noexec'}) &&
          !base.options.contains('rw') &&
          child.type == 'vfat' &&
          child.device == base.device &&
          child.source == base.source &&
          child.root.toLowerCase() == '/efi/fedora' &&
          child.options.containsAll({'rw', 'nosuid', 'nodev', 'noexec'}) &&
          !child.options.contains('ro');
    } catch (_) {
      return false;
    }
  }

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
        _manualLayout?.reusesEsp != true &&
        args.length == 2 &&
        args[0] == _part(1) &&
        target == '/mnt/boot/efi';
    final probe =
        _espProbe != null &&
        _owned.isEmpty &&
        args.length == 6 &&
        args.join(' ') ==
            '-t vfat -o ro,nosuid,nodev,noexec ${_espProbe!.plan.esp.target} $espProbeTarget';
    final stage =
        _preparingEsp &&
        _manualLayout?.reusesEsp == true &&
        args.length == 6 &&
        args.join(' ') ==
            '-t vfat -o rw,nosuid,nodev,noexec,umask=0077 ${_part(1)} $espStageTarget';
    final espBind =
        _preparingEsp &&
        _manualLayout?.reusesEsp == true &&
        args.length == 3 &&
        args.first == '--bind' &&
        ((args[1] == espStageTarget && target == espTarget) ||
            (args[1] == '$espStageTarget/EFI/fedora' &&
                target == espOwnedTarget &&
                _owned.values.any(
                  (m) =>
                      m.target == espTarget &&
                      m.options.contains('ro') &&
                      !m.options.contains('rw'),
                ))) &&
        _owned.values.any(
          (m) => m.target == espStageTarget && m.type == 'vfat',
        );
    if (!bind &&
        !tmp &&
        !root &&
        !efi &&
        !private &&
        !probe &&
        !stage &&
        !espBind) {
      return false;
    }
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
    if (root || efi || probe || stage || espBind) {
      final read = await runner.run('lsblk', [
        '-dnro',
        'MAJ:MIN',
        root
            ? _part(2)
            : probe
            ? _espProbe!.plan.esp.target
            : _part(1),
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
            : probe || stage || espBind
            ? m.device == device &&
                  m.target == target &&
                  m.type == 'vfat' &&
                  (target == espOwnedTarget
                      ? m.root.toLowerCase() == '/efi/fedora'
                      : m.root == '/') &&
                  m.options.containsAll({
                    probe ? 'ro' : 'rw',
                    'nosuid',
                    'nodev',
                    'noexec',
                  }) &&
                  !m.options.contains(probe ? 'rw' : 'ro')
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
        return _report = CleanupReport(
          false,
          remaining: _targets(rows).map((m) => m.target).toList(),
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
  @override
  void bindCreatedManualLayout(CreatedManualLayout layout) {}
  @override
  Future<bool> mountReadOnlyEspProbe(ApprovedManualPlan plan) async => false;
  @override
  Future<bool> inspectEspReuse(ApprovedManualPlan plan) async => false;
  @override
  Future<bool> finishEspProbe() async => false;
  @override
  Future<bool> mountProtectedEsp() async => false;
  @override
  Future<bool> verifyProtectedEsp() async => false;
  @override
  void bindCreatedFreeSpaceLayout(CreatedFreeSpaceLayout layout) {}
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
