import 'dart:convert';
import 'observability_schema.g.dart';

/// Strict, bounded, data-only report. It grants no access to a root file.
class SessionReport {
  SessionReport._(this._data);
  final Map<String, dynamic> _data;
  Map<String, dynamic> get json =>
      jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;
  String get logStatus => _data['logStatus'] as String;
  String get terminalStatus => _data['terminalStatus'] as String;
  static SessionReport? parse(dynamic value) {
    try {
      if (!validSchema(value, ['object', 'report']) ||
          utf8.encode(jsonEncode(value)).length + 1 > 4096)
        return null;
      final stages = value['stages'] as List;
      final spans = value['spans'] as List;
      const names = [
        'preflight',
        'copy.main',
        'copy.efi',
        'diagnostics',
        'cleanup',
        'engine',
      ];
      if (stages.length != 9 || spans.length != names.length) return null;
      for (var i = 0; i < 9; i++) {
        if (stages[i]['stageId'] != i + 1) return null;
      }
      for (var i = 0; i < names.length; i++) {
        if (spans[i]['operationId'] != names[i]) return null;
      }
      for (final row in [...stages, ...spans]) {
        if ((row['status'] == 'notStarted') != (row['durationMs'] == null))
          return null;
      }
      return SessionReport._(
        jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}

bool validSchema(dynamic value, List<dynamic> rule) {
  switch (rule[0]) {
    case 'nullable':
      return value == null || validSchema(value, rule[1] as List);
    case 'literal':
      return value == rule[1] && (value is num ? value is int : true);
    case 'int':
      return value is int && value >= rule[1] && value <= rule[2];
    case 'enum':
      return value is String && (rule[1] as List).contains(value);
    case 'hex':
      return value is String &&
          RegExp('^[0-9a-f]{${rule[1]}}\$').hasMatch(value);
    case 'utc':
      return value is String &&
          RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$').hasMatch(value) &&
          DateTime.tryParse(value) != null;
    case 'array':
      return value is List &&
          value.length <= rule[1] &&
          value.every((v) => validSchema(v, rule[2] as List));
    case 'object':
      final fields = observabilitySchema['objects'][rule[1]] as Map;
      return value is Map<String, dynamic> &&
          value.length == fields.length &&
          fields.entries.every(
            (e) =>
                value.containsKey(e.key) &&
                validSchema(value[e.key], e.value as List),
          );
    default:
      return false;
  }
}
