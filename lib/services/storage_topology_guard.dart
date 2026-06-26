import 'dart:convert';

import 'command_runner.dart';

class UnsupportedStorageTopologyReport {
  const UnsupportedStorageTopologyReport({
    required this.blockers,
    required this.details,
    this.inspectionError = '',
  });

  final Set<String> blockers;
  final List<String> details;
  final String inspectionError;

  bool get hasBlockers => blockers.isNotEmpty;
  bool get inspectionFailed => inspectionError.isNotEmpty;

  List<String> get sortedBlockers => blockers.toList()..sort();
}

UnsupportedStorageTopologyReport collectUnsupportedStorageTopology(
  List<dynamic> nodes,
) {
  final blockers = <String>{};
  final details = <String>[];

  void walk(List<dynamic> currentNodes) {
    for (final rawNode in currentNodes) {
      if (rawNode is! Map<String, dynamic>) {
        continue;
      }
      final name = (rawNode['name'] ?? '').toString();
      final path = name.startsWith('/dev/') ? name : '/dev/$name';
      final type = (rawNode['type'] ?? '').toString().toLowerCase();
      final fsType = (rawNode['fstype'] ?? '').toString().toLowerCase();
      void add(String code) {
        blockers.add(code);
        details.add('$code:$path:type=$type:fs=$fsType');
      }

      if (type == 'crypt' ||
          fsType == 'crypto_luks' ||
          fsType == 'luks' ||
          fsType == 'luks2') {
        add('unsupported_luks');
      }
      if (type == 'lvm' || fsType == 'lvm2_member') {
        add('unsupported_lvm');
      }
      if (type.startsWith('raid') ||
          fsType == 'linux_raid_member' ||
          fsType == 'ddf_raid_member' ||
          fsType == 'isw_raid_member') {
        add('unsupported_raid');
      }
      if (type == 'mpath' || type == 'multipath') {
        add('unsupported_multipath');
      }

      final children = rawNode['children'];
      if (children is List<dynamic> && children.isNotEmpty) {
        if (type == 'part') {
          add('unsupported_nested');
        }
        walk(children);
      }
    }
  }

  walk(nodes);
  return UnsupportedStorageTopologyReport(blockers: blockers, details: details);
}

UnsupportedStorageTopologyReport unsupportedStorageTopologyFromState(
  Map<String, dynamic> state,
) {
  return UnsupportedStorageTopologyReport(
    blockers: _readStringList(state['unsupportedStorageBlockers']).toSet(),
    details: _readStringList(state['unsupportedStorageDetails']),
  );
}

Future<UnsupportedStorageTopologyReport> detectUnsupportedStorageTopologyOnDisk(
  CommandRunner commandRunner,
  String selectedDisk,
) async {
  final result = await commandRunner.run('lsblk', [
    '-J',
    '-o',
    'NAME,TYPE,FSTYPE',
    selectedDisk,
  ]);
  if (!result.started || result.exitCode != 0) {
    final detail = result.stderr.isNotEmpty ? result.stderr : result.stdout;
    return UnsupportedStorageTopologyReport(
      blockers: const <String>{},
      details: const <String>[],
      inspectionError: detail.trim().isEmpty
          ? 'lsblk topoloji sorgusu basarisiz oldu.'
          : detail.trim(),
    );
  }
  if (result.stdout.trim().isEmpty) {
    return const UnsupportedStorageTopologyReport(
      blockers: <String>{},
      details: <String>[],
    );
  }

  try {
    final parsed = jsonDecode(result.stdout) as Map<String, dynamic>;
    final devices = parsed['blockdevices'];
    if (devices is! List<dynamic>) {
      return const UnsupportedStorageTopologyReport(
        blockers: <String>{},
        details: <String>[],
      );
    }
    return collectUnsupportedStorageTopology(devices);
  } catch (e) {
    return UnsupportedStorageTopologyReport(
      blockers: const <String>{},
      details: const <String>[],
      inspectionError: 'lsblk topoloji ciktisi okunamadi: $e',
    );
  }
}

String unsupportedStorageTopologyMessage(
  UnsupportedStorageTopologyReport report,
) {
  final summary = report.sortedBlockers
      .map(unsupportedStorageBlockerLabel)
      .join(', ');
  final detailText = report.details.isEmpty
      ? ''
      : ' Ayrinti: ${report.details.join('; ')}';
  return 'Bu disk duzeni stable kurulumda desteklenmiyor: $summary.$detailText';
}

String unsupportedStorageBlockerLabel(String code) {
  switch (code) {
    case 'unsupported_luks':
      return 'LUKS/crypt';
    case 'unsupported_lvm':
      return 'LVM';
    case 'unsupported_raid':
      return 'RAID/mdraid';
    case 'unsupported_multipath':
      return 'multipath';
    case 'unsupported_nested':
      return 'nested block-device';
    default:
      return code;
  }
}

List<String> _readStringList(Object? rawValue) {
  if (rawValue is Iterable) {
    return rawValue.map((value) => value.toString()).toList();
  }
  if (rawValue is String && rawValue.isNotEmpty) {
    return <String>[rawValue];
  }
  return const <String>[];
}
