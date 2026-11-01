import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/services/copy_progress.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'helper_client_test.dart' as f;
import 'helper_v2_test.dart' as v2;

String line(
  int bytes, {
  int percent = 20,
  String scan = 'to-chk',
  String time = '0:00:12',
}) => '  $bytes $percent% 1.00MB/s $time (xfr#1, $scan=3/10)';
Map<String, dynamic> stage(int n) => {
  'protocolVersion': 2,
  'type': 'progress',
  'stage': n,
  'progress': 0.42,
  'messageKey': n == 5
      ? 'install_stage_file_copy'
      : 'install_stage_target_finalization',
};
const sample = CopyProgress(
  phase: 'main',
  bytesProcessed: 4096,
  bytesPerSecond: 1024,
  etaSeconds: 12,
);

void main() {
  test(
    'exact byte counter, monotonic rate, warm-up, scan and completion ETA',
    () {
      var clock = 0;
      final parser = RsyncProgressParser('main', milliseconds: () => clock);
      expect(parser.add(line(1024))!.bytesPerSecond, isNull);
      clock = 999;
      expect(parser.add(line(2048)), isNull);
      clock = 1000;
      expect(parser.add(line(2048))!.etaSeconds, isNull);
      clock = 2000;
      final value = parser.add(line(4096))!;
      expect(value.bytesPerSecond, 2048);
      expect(value.etaSeconds, 12);
      clock = 3000;
      expect(parser.add(line(8192, scan: 'ir-chk'))!.etaSeconds, isNull);
      clock = 4000;
      expect(parser.add(line(8192))!.etaSeconds, isNull);
      clock = 5000;
      expect(parser.add(line(16384, percent: 100))!.etaSeconds, isNull);
      clock = 6000;
      expect(parser.add(line(1)), isNull);
      clock = 3000;
      expect(parser.add(line(32768)), isNull);
    },
  );
  test(
    'only anchored bounded numeric progress; no filenames, locale guesses or stderr',
    () {
      for (final raw in [
        'secret ${line(1024)}',
        '[STDERR] ${line(1024)}',
        '${line(1024)} /home/secret',
        line(1024, percent: 101),
        line(1024, time: '999:00:00').replaceFirst('1024', '9007199254740992'),
        line(1024).replaceFirst('1024', '1.02M'),
        'x' * 10000,
      ]) {
        expect(RsyncProgressParser('main').add(raw), isNull);
      }
      expect(
        RsyncProgressParser(
          'main',
        ).add(line(1024).replaceFirst('1024', '1,024'))!.bytesProcessed,
        1024,
      );
    },
  );
  test(
    'CR and chunk boundaries do not lose measurements or leak raw output',
    () {
      final captured = BoundedCommandOutput(rsync: true);
      final parser = RsyncProgressParser('main');
      final values = <CopyProgress>[];
      void log(String stream, String text) {
        final v = parser.add(text);
        if (v != null) values.add(v);
      }

      final data = 'secret filename\r${line(4096)}\r';
      for (final byte in data.split('')) {
        captured.add('stdout', byte, log);
      }
      captured.finish(log);
      expect(values.single.bytesProcessed, 4096);
      expect(jsonEncode(values.single.toJson()), isNot(contains('secret')));
    },
  );
  test(
    'real rsync in temporary dirs emits parseable integer progress',
    () async {
      final root = Directory.systemTemp.createTempSync('copy-progress-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/from').createSync();
      Directory('${root.path}/to').createSync();
      File('${root.path}/from/data').writeAsBytesSync(List.filled(131072, 42));
      final run = await Process.run(
        'rsync',
        [
          '-a',
          '--info=progress2,stats2',
          '--no-human-readable',
          '${root.path}/from/',
          '${root.path}/to/',
        ],
        environment: {'LC_ALL': 'C'},
      );
      expect(run.exitCode, 0);
      final samples = <CopyProgress>[];
      for (final text in run.stdout.toString().split(RegExp(r'[\r\n]'))) {
        final v = RsyncProgressParser('main').add(text);
        if (v != null) samples.add(v);
      }
      expect(samples, isNotEmpty);
      expect(samples.last.bytesProcessed, 131072);
      expect(
        File('${root.path}/to/data').readAsBytesSync(),
        List.filled(131072, 42),
      );
    },
  );
  test(
    'typed frame rejects unknown fields, wrong numeric types and unbounded ETA',
    () {
      final frame = sample.toJson(version: 2);
      expect(CopyProgress.fromJson(frame).bytesProcessed, 4096);
      for (final mutation in [
        {'bytesProcessed': true},
        {'bytesProcessed': -1},
        {'bytesProcessed': 1.0},
        {'bytesProcessed': CopyProgress.maxBytes + 1},
        {'bytesPerSecond': 'fast'},
        {'etaSeconds': 86401},
        {'etaSeconds': -1},
        {'bytesPerSecond': null},
        {'phase': '/mnt'},
        {'protocolVersion': 1},
        {'type': 'exec'},
        {'path': 'secret'},
      ]) {
        expect(
          () => CopyProgress.fromJson({...frame, ...mutation}),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'v2 opts in explicitly; callback failure does not change success',
    () async {
      final process = f.FakeHelperProcess(
        f.messages([stage(5), sample.toJson(version: 2), v2.terminal()]),
      );
      final client = HelperClient(
        protocolVersion: 2,
        start: (_, _) async => process,
      );
      var calls = 0;
      await client.installWithReport(
        f.identity,
        (_, _) {},
        onCopyProgress: (value) {
          calls++;
          expect(value.bytesProcessed, 4096);
          throw StateError('UI');
        },
      );
      expect(calls, 1);
      expect(jsonDecode(process.sent)['includeCopyProgress'], true);
    },
  );
  test(
    'unexpected, malformed, backward and out-of-stage frames fail closed',
    () async {
      final frame = sample.toJson(version: 2);
      for (final events in <List<Map<String, dynamic>>>[
        [frame],
        [stage(6), frame],
        [
          stage(5),
          {...frame, 'bytesProcessed': true},
        ],
        [
          stage(5),
          frame,
          {...frame, 'bytesProcessed': 1},
        ],
        [
          stage(5),
          {...frame, 'phase': 'efi'},
          frame,
        ],
        [stage(5), v2.report(v2.fixture()), frame],
      ]) {
        final process = f.FakeHelperProcess(
          f.messages([...events, v2.terminal()]),
        );
        await expectLater(
          HelperClient(
            protocolVersion: 2,
            start: (_, _) async => process,
          ).installWithReport(f.identity, (_, _) {}, onCopyProgress: (_) {}),
          throwsA(f.helperError('PROTOCOL_ERROR')),
        );
      }
      final process = f.FakeHelperProcess(
        f.messages([stage(5), frame, v2.terminal()]),
      );
      await expectLater(
        HelperClient(
          protocolVersion: 2,
          start: (_, _) async => process,
        ).installWithReport(f.identity, (_, _) {}),
        throwsA(f.helperError('PROTOCOL_ERROR')),
      );
    },
  );
}
