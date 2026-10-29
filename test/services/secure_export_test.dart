import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/install_log_export_service.dart';
import 'helper_v2_test.dart' show fixture;

const sentinel = 'ALPHA_SENTINEL';
void main() {
  final cases = <String, String>{
    'single': 'password $sentinel',
    'multi': 'password $sentinel BETA_SENTINEL',
    'quoted': 'password="$sentinel BETA_SENTINEL"',
    'argv': '--password $sentinel BETA_SENTINEL',
    'json':
        '{"password":"$sentinel BETA_SENTINEL","nested":[{"apiKey":"$sentinel"}]}',
    'url':
        'https://user:$sentinel@invalid.example/?access_token=$sentinel&key=$sentinel',
    'encoded': 'https://invalid.example/?access%5Ftoken=%41LPHA_SENTINEL',
    'escaped': r'{"\u0070assword":"ALPHA_SENTINEL"}',
    'exception': 'FileSystemException: passphrase=$sentinel BETA_SENTINEL',
    'stdout-stderr': '[STDERR] Authorization: Bearer $sentinel BETA_SENTINEL',
  };
  for (final entry in cases.entries) {
    test('redaction removes all known sentinels: ${entry.key}', () {
      final text = SecretRedactor.redactText(entry.value);
      expect(text, isNot(contains(sentinel)));
      expect(text, isNot(contains('BETA_SENTINEL')));
    });
  }
  test('separate argv removes entire multi-word value', () {
    final text = SecretRedactor.redactCommandLine('nmcli', [
      'connect',
      'test',
      'password',
      '$sentinel BETA_SENTINEL',
    ]);
    expect(text, isNot(contains(sentinel)));
    expect(text, isNot(contains('BETA_SENTINEL')));
  });
  late Directory temp;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('p0-04-user-export-');
    // CI is root: the test-only child drops to nobody before calling the real
    // exporter. The writable sticky fixture is never a production target.
    final uid = await Process.run('/usr/bin/id', ['-u']);
    if (uid.stdout.toString().trim() == '0') {
      await Process.run('/usr/bin/chmod', ['1777', temp.path]);
    }
  });
  tearDown(() => temp.deleteSync(recursive: true));
  Future<InstallLogExportResult> export({String? executable}) =>
      InstallLogExportService(
        targetDirectory: '${temp.path}/logs',
        exportExecutable:
            executable ??
            '${Directory.current.path}/test/fixtures/export_as_user.py',
      ).exportSession(
        startedAt: DateTime(2026, 10, 29),
        finishedAt: DateTime(2026, 10, 29, 0, 0, 1),
        success: false,
        finalStatus: 'password $sentinel BETA_SENTINEL',
        statusHistory: cases.values.toList(),
        technicalLogs: cases.values.toList(),
        installContext: {
          'password': sentinel,
          'nested': {
            'apiKey': sentinel,
            'deep': [
              {
                'access_token': sentinel,
                'note': 'password $sentinel BETA_SENTINEL',
              },
            ],
          },
          'sessionReport': fixture(),
        },
      );
  test(
    'atomic real user export sanitizes FinalStatus nested context and every artifact',
    () async {
      final result = await export();
      expect(result.success, isTrue, reason: result.error);
      for (final path in [
        result.logPath!,
        result.summaryPath!,
        result.manifestPath!,
      ]) {
        final text = await File(path).readAsString();
        expect(text, isNot(contains(sentinel)));
        expect(text, isNot(contains('BETA_SENTINEL')));
      }
      final summary = jsonDecode(
        await File(result.summaryPath!).readAsString(),
      );
      expect(summary['context']['sessionReport']['schemaVersion'], 1);
      final manifest = jsonDecode(
        await File(result.manifestPath!).readAsString(),
      );
      expect(manifest['complete'], isTrue);
      expect(manifest['files'].keys.toSet(), {'install.log', 'summary.json'});
    },
  );
  test('same timestamp exports publish different complete bundles', () async {
    final first = await export();
    final before = await File(first.logPath!).readAsBytes();
    final second = await export();
    expect(second.success, isTrue);
    expect(first.logPath, isNot(second.logPath));
    expect(await File(first.logPath!).readAsBytes(), before);
  });
  test(
    'export launch exception has fixed error and no raw path/exception',
    () async {
      final result = await export(
        executable: '/nonexistent/password=$sentinel',
      );
      expect(result.success, isFalse);
      expect(result.error, 'EXPORT_FAILED');
    },
  );
  test(
    'malicious session-report data is not treated as safe structured context',
    () async {
      final result =
          await InstallLogExportService(
            targetDirectory: '${temp.path}/logs',
            exportExecutable:
                '${Directory.current.path}/test/fixtures/export_as_user.py',
          ).exportSession(
            startedAt: DateTime.now(),
            finishedAt: DateTime.now(),
            success: true,
            finalStatus: 'ok',
            statusHistory: [],
            technicalLogs: [],
            installContext: {
              'sessionReport': {...fixture(), 'stdout': sentinel},
            },
          );
      expect(result.success, isTrue);
      expect(
        await File(result.summaryPath!).readAsString(),
        isNot(contains(sentinel)),
      );
    },
  );
}
