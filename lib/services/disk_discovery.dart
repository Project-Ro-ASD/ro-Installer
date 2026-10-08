import 'dart:convert';
import 'dart:async';
import 'command_runner.dart';

enum DiskDiscoveryError {
  startFailed,
  commandFailed,
  timeout,
  incompatibleJson,
  topology,
}

class DiskDiscoveryException implements Exception {
  const DiskDiscoveryException(this.error);
  final DiskDiscoveryError error;
}

class DiskDiscoveryResult {
  const DiskDiscoveryResult({
    this.disks = const [],
    this.error,
    this.rejectedEntries = 0,
  });
  final List<Map<String, dynamic>> disks;
  final DiskDiscoveryError? error;
  final int rejectedEntries;
  bool get succeeded => error == null;
}

Future<DiskDiscoveryResult> discoverDisks(CommandRunner runner) async {
  CommandResult result;
  try {
    result = await runner.run('lsblk', [
      '-J',
      '-b',
      '-o',
      'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS',
    ], timeout: const Duration(seconds: 10));
  } on TimeoutException {
    return const DiskDiscoveryResult(error: DiskDiscoveryError.timeout);
  } catch (_) {
    return const DiskDiscoveryResult(error: DiskDiscoveryError.startFailed);
  }
  if (!result.started) {
    return const DiskDiscoveryResult(error: DiskDiscoveryError.startFailed);
  }
  if (result.exitCode == -124) {
    return const DiskDiscoveryResult(error: DiskDiscoveryError.timeout);
  }
  if (result.exitCode != 0) {
    return const DiskDiscoveryResult(error: DiskDiscoveryError.commandFailed);
  }
  dynamic parsed;
  try {
    if (utf8.encode(result.stdout).length > 4 * 1024 * 1024) {
      throw const FormatException();
    }
    parsed = jsonDecode(result.stdout);
    if (parsed is! Map<String, dynamic> || parsed['blockdevices'] is! List) {
      throw const FormatException();
    }
  } catch (_) {
    return const DiskDiscoveryResult(
      error: DiskDiscoveryError.incompatibleJson,
    );
  }
  final disks = <Map<String, dynamic>>[];
  var rejected = 0;
  final names = <String>{};
  for (final raw in parsed['blockdevices']) {
    try {
      if (raw is! Map<String, dynamic> || raw['type'] is! String) {
        throw const FormatException();
      }
      if (raw['type'] != 'disk') continue;
      final name = raw['name'];
      if (name is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(name)) {
        throw const FormatException();
      }
      if (name.startsWith('loop') ||
          name.startsWith('zram') ||
          name.startsWith('sr')) {
        continue;
      }
      if (!names.add(name)) {
        return const DiskDiscoveryResult(error: DiskDiscoveryError.topology);
      }
      if (raw['size'] is! int ||
          raw['size'] <= 0 ||
          (raw['model'] != null && raw['model'] is! String) ||
          !(raw['rm'] is bool || raw['rm'] == 0 || raw['rm'] == 1)) {
        throw const FormatException();
      }
      var live = raw['rm'] == true || raw['rm'] == 1;
      var host = false;
      var count = 0;
      void walk(Map<String, dynamic> node, int depth) {
        if (depth > 32 || ++count > 4096) throw const FormatException();
        final mountpoints = node['mountpoints'];
        if (mountpoints != null && mountpoints is! List) {
          throw const FormatException();
        }
        for (final point in mountpoints ?? const []) {
          if (point != null && point is! String) throw const FormatException();
          if (point == '/' || point == '/boot' || point == '/boot/efi') {
            host = true;
          }
          if (point is String &&
              (point.contains('/run/initramfs') || point.contains('/live'))) {
            live = true;
          }
        }
        final children = node.containsKey('children')
            ? node['children']
            : const [];
        // Null children is not silently interpreted as a proven blank disk.
        if (children is! List) throw const FormatException();
        for (final child in children) {
          if (child is! Map<String, dynamic> ||
              child['name'] is! String ||
              child['type'] is! String) {
            throw const FormatException();
          }
          walk(child, depth + 1);
        }
      }

      walk(raw, 0);
      final model = (raw['model'] as String?)?.trim() ?? '';
      disks.add({
        'name': '/dev/$name',
        'model': model.isEmpty ? name : model,
        'size': raw['size'],
        'type': 'disk',
        'isLive': live,
        'isHostOS': host,
        'isSafe': false,
      });
    } catch (_) {
      rejected++;
    }
  }
  return DiskDiscoveryResult(
    disks: List.unmodifiable(disks),
    rejectedEntries: rejected,
    error: disks.isEmpty && rejected > 0 ? DiskDiscoveryError.topology : null,
  );
}
