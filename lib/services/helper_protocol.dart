import 'dart:convert';

const helperErrorCodes = {
  'INVALID_REQUEST',
  'REQUEST_TOO_LARGE',
  'REQUEST_TIMEOUT',
  'ROOT_REQUIRED',
  'DEVICE_NOT_FOUND',
  'NOT_BLOCK_DEVICE',
  'UNSAFE_DEVICE',
  'AMBIGUOUS_TOPOLOGY',
  'DEVICE_CHANGED',
  'UNSUPPORTED_PLATFORM',
  'BUSY',
  'UNSAFE_LOCK',
  'SYSTEM_ERROR',
  'INSTALL_FAILED',
  'BACKEND_ERROR',
};
const helperLineLimit = 8192;
const helperOutputLimit = 4 * 1024 * 1024;
const helperStageKeys = [
  'install_progress_initial',
  'install_stage_disk_preparation',
  'install_stage_partitioning',
  'install_stage_formatting',
  'install_stage_mounting',
  'install_stage_file_copy',
  'install_stage_target_finalization',
  'install_stage_bootloader',
  'install_stage_post_validation',
  'install_stage_cleanup',
];

bool exactFields(Map<String, dynamic> value, Set<String> keys) =>
    value.length == keys.length && value.keys.every(keys.contains);

Map<String, dynamic> decodeProtocolObject(
  String text, {
  int limit = helperLineLimit,
}) {
  if (utf8.encode(text).length > limit) {
    throw const FormatException('Protocol size');
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Protocol object');
  }
  // jsonDecode accepts duplicate keys; reject them in every object scope.
  final scopes = <Set<String>?>[];
  for (final token in RegExp(r'"(?:[^"\\]|\\.)*"|[{}\[\]]').allMatches(text)) {
    final value = token.group(0)!;
    if (value == '{') {
      scopes.add(<String>{});
    } else if (value == '[') {
      scopes.add(null);
    } else if (value == '}' || value == ']') {
      scopes.removeLast();
    } else if (text.substring(token.end).trimLeft().startsWith(':')) {
      if (!scopes.last!.add(jsonDecode(value) as String)) {
        throw const FormatException('Duplicate protocol field');
      }
    }
  }
  return decoded;
}

class DeviceIdentity {
  DeviceIdentity({
    required this.path,
    required this.majorMinor,
    required this.size,
    required this.diskSequence,
  });
  final String path;
  final String majorMinor;
  final int size;
  final int diskSequence;
  static final pathPattern = RegExp(r'^/dev/[A-Za-z0-9_-]{1,128}$');
  factory DeviceIdentity.fromJson(Map<String, dynamic> data) {
    if (!exactFields(data, {'path', 'majorMinor', 'size', 'diskSequence'}) ||
        data['path'] is! String ||
        !pathPattern.hasMatch(data['path']) ||
        data['majorMinor'] is! String ||
        !RegExp(
          r'^(0|[1-9][0-9]*):(0|[1-9][0-9]*)$',
        ).hasMatch(data['majorMinor']) ||
        data['size'] is! int ||
        data['size'] <= 0 ||
        data['diskSequence'] is! int ||
        data['diskSequence'] <= 0) {
      throw const FormatException('Invalid device identity');
    }
    final numbers = (data['majorMinor'] as String)
        .split(':')
        .map(int.tryParse)
        .toList();
    if (numbers[0] == null ||
        numbers[0]! > 4095 ||
        numbers[1] == null ||
        numbers[1]! > 1048575) {
      throw const FormatException('Invalid device number');
    }
    return DeviceIdentity(
      path: data['path'],
      majorMinor: data['majorMinor'],
      size: data['size'],
      diskSequence: data['diskSequence'],
    );
  }
  Map<String, dynamic> get expected => {
    'majorMinor': majorMinor,
    'size': size,
    'diskSequence': diskSequence,
  };
  Map<String, dynamic> get json => {'path': path, ...expected};
  Map<String, dynamic> get installRequest => {
    'protocolVersion': 1,
    'operation': 'install-full-disk',
    'disk': path,
    'partitionMethod': 'full',
    'fileSystem': 'btrfs',
    'confirmDestructive': true,
    'expectedDevice': expected,
  };
}

void validateProgress(Map<String, dynamic> data) {
  if (!exactFields(data, {
        'protocolVersion',
        'type',
        'stage',
        'progress',
        'messageKey',
      }) ||
      data['protocolVersion'] is! int ||
      data['protocolVersion'] != 1 ||
      data['type'] != 'progress' ||
      data['stage'] is! int ||
      data['stage'] < 0 ||
      data['stage'] > 9 ||
      data['progress'] is! num ||
      !data['progress'].isFinite ||
      data['progress'] < 0 ||
      data['progress'] > 1 ||
      data['messageKey'] != helperStageKeys[data['stage']]) {
    throw const FormatException('Invalid progress');
  }
}
