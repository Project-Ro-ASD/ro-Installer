import '../services/helper_protocol.dart';
import 'approved_full_disk_plan.dart';
import 'gpt_disk_snapshot.dart';
import 'ntfs_shrink_assessment.dart';

/// Reported qualified compatibility, not executable integrity attestation.
final class NtfsResizeToolchain {
  const NtfsResizeToolchain._(
    this.version,
    this.epoch,
    this.release,
    this.arch,
  );
  final String version, release, arch;
  final int epoch;
  factory NtfsResizeToolchain.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {'version', 'epoch', 'release', 'arch'}) ||
        input['version'] is! String ||
        input['release'] is! String ||
        input['arch'] != 'x86_64') {
      throw const FormatException('Invalid NTFS toolchain');
    }
    final version = input['version'] as String,
        release = input['release'] as String;
    final pattern = RegExp(r'^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$');
    if (pattern.stringMatch(version) != version ||
        RegExp(r'^[0-9][A-Za-z0-9._+~^\-]{0,63}$').stringMatch(release) !=
            release) {
      throw const FormatException('Invalid NTFS package version');
    }
    final parts = version.split('.').map(int.parse).toList();
    final date = DateTime.utc(parts[0], parts[1], parts[2]);
    if (date.year != parts[0] ||
        date.month != parts[1] ||
        date.day != parts[2] ||
        date.isBefore(DateTime.utc(2026, 9, 28))) {
      throw const FormatException('Unsupported NTFS resize version');
    }
    return NtfsResizeToolchain._(
      version,
      snapshotInteger(input['epoch'], 0, 99999999),
      release,
      'x86_64',
    );
  }
  Map<String, dynamic> get json => {
    'version': version,
    'epoch': epoch,
    'release': release,
    'arch': arch,
  };
}

/// Exact-target read-only evidence. It never authorizes filesystem mutation.
final class PreparedNtfsShrink {
  const PreparedNtfsShrink._(
    this.assessment,
    this.toolchain,
    this.preparationFingerprint,
  );
  final NtfsShrinkAssessment assessment;
  final NtfsResizeToolchain toolchain;
  final String preparationFingerprint;
  int get targetBytes => assessment.plan.retainedSourceBytes;

  factory PreparedNtfsShrink.fromJson(
    Object? input, {
    required NtfsShrinkAssessment expected,
  }) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {'plan', 'inspection', 'preparation'})) {
      throw const FormatException('Invalid NTFS preparation result');
    }
    final observed = NtfsShrinkAssessment.fromJson(
      {'plan': input['plan'], 'inspection': input['inspection']},
      snapshot: expected.plan.snapshot,
      sourceNumber: expected.plan.source.number,
      espNumber: expected.plan.esp.number,
      rootBytes: expected.plan.rootBytes,
    );
    if (!samePlanValue(observed.json, expected.json)) {
      throw const FormatException('NTFS assessment changed during preparation');
    }
    final value = input['preparation'];
    if (value is! Map<String, dynamic> ||
        !exactFields(value, {
          'schemaVersion',
          'deviceBytes',
          'targetBytes',
          'inspectionFingerprint',
          'toolchain',
          'preparationFingerprint',
        }) ||
        value['schemaVersion'] is! int ||
        value['schemaVersion'] != 1 ||
        value['deviceBytes'] is! int ||
        value['deviceBytes'] != observed.deviceBytes ||
        value['targetBytes'] is! int ||
        value['targetBytes'] != observed.plan.retainedSourceBytes ||
        value['inspectionFingerprint'] != observed.inspectionFingerprint ||
        value['preparationFingerprint'] is! String ||
        RegExp(
              r'^[0-9a-f]{64}$',
            ).stringMatch(value['preparationFingerprint']) !=
            value['preparationFingerprint']) {
      throw const FormatException(
        'NTFS preparation differs from exact source/target',
      );
    }
    return PreparedNtfsShrink._(
      observed,
      NtfsResizeToolchain.fromJson(value['toolchain']),
      value['preparationFingerprint'] as String,
    );
  }

  /// Public confirmation only; root-side checks must regenerate observed intent
  /// and the worker must reproduce preparation before any filesystem mutation.
  Map<String, dynamic> get confirmation => {
    'selection': {
      'sourceNumber': assessment.plan.source.number,
      'espNumber': assessment.plan.esp.number,
      'rootBytes': assessment.plan.rootBytes,
    },
    'intent': assessment.plan.intentJson,
    'inspectionFingerprint': assessment.inspectionFingerprint,
    'preparationFingerprint': preparationFingerprint,
  };

  bool matchesConfirmation(Object? value) => samePlanValue(confirmation, value);

  Map<String, dynamic> get json => {
    ...assessment.json,
    'preparation': {
      'schemaVersion': 1,
      'deviceBytes': assessment.deviceBytes,
      'targetBytes': targetBytes,
      'inspectionFingerprint': assessment.inspectionFingerprint,
      'toolchain': toolchain.json,
      'preparationFingerprint': preparationFingerprint,
    },
  };
}
