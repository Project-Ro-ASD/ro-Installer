import '../models/approved_manual_plan.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'helper_protocol.dart';
import 'install_service.dart';
import '../models/approved_full_disk_plan.dart';
import '../models/approved_free_space_plan.dart';

/// A strict, non-GUI adapter around the existing nine-stage Dart engine.
/// Only helper-generated values enter the engine state; no profile/path/env API.
Future<int> runPrivilegedBackend(
  Stream<List<int>> input,
  void Function(Map<String, dynamic>) emit, {
  InstallService? service,
  Future<bool> Function()? rootCheck,
  bool isMock = false,
}) async {
  var stage = 0;
  var progress = 0.0;
  Timer? heartbeat;
  StreamIterator<String>? lines;
  var authorized = false;
  void publish() => emit({
    'protocolVersion': 1,
    'type': 'progress',
    'stage': stage,
    'progress': progress,
    'messageKey': helperStageKeys[stage],
  });
  try {
    if (!await (rootCheck ?? _isRoot)()) {
      throw const FormatException('Root required');
    }
    var bytes = 0;
    final bounded = input.map((chunk) {
      bytes += chunk.length;
      if (bytes > 32768) throw const FormatException('Input limit');
      return chunk;
    });
    lines = StreamIterator(
      bounded.transform(utf8.decoder).transform(const LineSplitter()),
    );
    if (!await lines.moveNext().timeout(const Duration(seconds: 5))) {
      throw const FormatException('Missing request');
    }
    final request = decodeProtocolObject(lines.current);
    final isFree = request['operation'] == 'install-free-space';
    final isManual = request['operation'] == 'install-manual';
    if (!exactFields(request, {
          'protocolVersion',
          'operation',
          'disk',
          'expectedDevice',
          if (request.containsKey('uiLanguage')) 'uiLanguage',
          if (request.containsKey('includeCopyProgress')) 'includeCopyProgress',
          if (request.containsKey('confirmedPlan')) 'confirmedPlan',
          if (isFree || isManual) 'sourceSnapshot',
        }) ||
        request['protocolVersion'] is! int ||
        request['protocolVersion'] != 1 ||
        !const [
          'install-full-disk',
          'install-free-space',
          'install-manual',
        ].contains(request['operation']) ||
        (request.containsKey('includeCopyProgress') &&
            request['includeCopyProgress'] != true) ||
        (request.containsKey('uiLanguage') &&
            !installerUiLanguages.contains(request['uiLanguage'])) ||
        request['expectedDevice'] is! Map<String, dynamic> ||
        !exactFields(request['expectedDevice'], {
          'majorMinor',
          'size',
          'diskSequence',
        })) {
      throw const FormatException('Request');
    }
    final identity = DeviceIdentity.fromJson({
      'path': request['disk'],
      ...request['expectedDevice'] as Map<String, dynamic>,
    });
    final freePlan = isFree
        ? ApprovedFreeSpacePlan.fromJson({
            'snapshot': request['sourceSnapshot'],
            'approval': request['confirmedPlan'],
          })
        : null;
    if (freePlan != null &&
        !samePlanValue(freePlan.plan.snapshot.device.json, identity.json)) {
      throw const FormatException('Free-space identity mismatch');
    }
    final manualPlan = isManual
        ? ApprovedManualPlan.fromJson({
            'snapshot': request['sourceSnapshot'],
            'approval': request['confirmedPlan'],
          })
        : null;
    if (manualPlan != null &&
        !samePlanValue(manualPlan.plan.snapshot.device.json, identity.json)) {
      throw const FormatException('Manual identity mismatch');
    }
    final plan = !isFree && !isManual && request.containsKey('confirmedPlan')
        ? ApprovedFullDiskPlan.fromJson(request['confirmedPlan'])
        : null;
    if (plan != null && !samePlanValue(plan.device.json, identity.json)) {
      throw const FormatException('Plan identity mismatch');
    }
    // Fixed full/Btrfs configuration. No GUI state, sources, targets, test flags,
    // chroots, boot arguments or environment overrides cross this boundary.
    final state = <String, dynamic>{
      'selectedDisk': identity.path,
      'partitionMethod': isManual
          ? 'manual'
          : isFree
          ? 'free_space'
          : 'full',
      'fileSystem': 'btrfs',
      'selectedLanguage': request['uiLanguage'] ?? 'en',
      if (plan != null) '_approvedFullDiskPlan': plan.json,
      if (freePlan != null) '_approvedFreeSpacePlan': freePlan.json,
      if (manualPlan != null) '_approvedManualPlan': manualPlan.json,
    };
    publish();
    heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => publish());
    final success = await (service ?? InstallService()).runInstall(
      state,
      (value, _) {
        if (value >= 0) progress = value.clamp(0.0, 1.0);
        publish();
      },
      (
        _,
      ) {}, // Never forward arbitrary command output across the trust boundary.
      isMock: isMock,
      onCopyProgress: request['includeCopyProgress'] == true
          ? (value) {
              try {
                emit(value.toJson());
              } catch (_) {}
            }
          : null,
      onStage: (value) {
        stage = value;
        publish();
      },
      beforeFirstMutation: () async {
        if (authorized) throw const FormatException('Repeated mutation gate');
        if (!matchesApprovedPlan(state, expected: plan) ||
            (freePlan != null && !freePlan.matchesState(state)) ||
            (manualPlan != null && !manualPlan.matchesState(state))) {
          throw const FormatException('Stale plan');
        }
        final authorizationLines = lines!;
        emit({
          'protocolVersion': 1,
          'type': 'ready',
          if (plan != null || freePlan != null || manualPlan != null)
            'confirmedPlan':
                manualPlan?.approval ?? freePlan?.approval ?? plan!.json,
        });
        if (!await authorizationLines.moveNext().timeout(
          Duration(seconds: isManual ? 45 : 15),
        )) {
          throw const FormatException('Missing authorization');
        }
        final gate = decodeProtocolObject(authorizationLines.current);
        if (!exactFields(gate, {
              'protocolVersion',
              'type',
              'device',
              if (plan != null || freePlan != null || manualPlan != null)
                'confirmedPlan',
            }) ||
            (plan != null &&
                !samePlanValue(gate['confirmedPlan'], plan.json)) ||
            (freePlan != null &&
                !samePlanValue(gate['confirmedPlan'], freePlan.approval)) ||
            (manualPlan != null &&
                !samePlanValue(gate['confirmedPlan'], manualPlan.approval)) ||
            gate['protocolVersion'] is! int ||
            gate['protocolVersion'] != 1 ||
            gate['type'] != 'continue' ||
            gate['device'] is! Map<String, dynamic> ||
            jsonEncode(DeviceIdentity.fromJson(gate['device']).json) !=
                jsonEncode(identity.json)) {
          throw const FormatException('Identity authorization mismatch');
        }
        if (await authorizationLines.moveNext().timeout(
          const Duration(seconds: 1),
        )) {
          throw const FormatException('Unexpected backend input after gate');
        }
        authorized = true;
      },
    );
    heartbeat.cancel();
    emit({
      'protocolVersion': 1,
      'type': 'result',
      'ok': success && authorized,
      'code': success && authorized ? 'OK' : 'INSTALL_FAILED',
    });
    return success && authorized ? 0 : 8;
  } catch (_) {
    emit({
      'protocolVersion': 1,
      'type': 'result',
      'ok': false,
      'code': 'BACKEND_ERROR',
    });
    return 9;
  } finally {
    heartbeat?.cancel();
    await lines?.cancel();
  }
}

Future<bool> _isRoot() async {
  final result = await Process.run(
    '/usr/bin/id',
    ['-u'],
    environment: const {
      'PATH': '/usr/sbin:/usr/bin',
      'LC_ALL': 'C',
      'HOME': '/root',
    },
    includeParentEnvironment: false,
  );
  return result.exitCode == 0 && result.stdout.toString().trim() == '0';
}
