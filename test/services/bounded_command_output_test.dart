import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/services/command_runner.dart';

void main() {
  test(
    'parsed command output drains and fails closed on real child overflow',
    () async {
      final result = await RealCommandRunner().run('/usr/bin/python3', [
        '-c',
        'import sys;sys.stdout.write("x" * 3000000);sys.stderr.write("e" * 200000)',
      ], timeout: const Duration(seconds: 10));
      expect(result.started, isTrue);
      expect(result.exitCode, -126);
      expect(result.stdout, isEmpty);
      expect(result.stderr, 'COMMAND_OUTPUT_LIMIT');
    },
  );
  test('rsync retention cap preserves copy exit semantics', () {
    final captured = BoundedCommandOutput(rsync: true);
    for (var i = 0; i < 200; i++) {
      captured.add('stdout', 'x' * 16384, (_, _) {});
      captured.add('stderr', 'e' * 16384, (_, _) {});
    }
    expect(captured.overflow, isFalse);
    expect(captured.value('stdout').length, 65536);
    expect(captured.value('stderr').length, 65536);
  });
  test('fragmented oversized line cannot leak a secret prefix to logs', () {
    final captured = BoundedCommandOutput();
    final lines = <String>[];
    void log(String _, String line) => lines.add(line);
    captured.add('stdout', 'password=SECRET_SENTINEL ', log);
    captured.add('stdout', 'x' * 9000, log);
    captured.add('stdout', '\nordinary', log);
    captured.finish(log);
    expect(lines, ['ordinary']);
  });
  test('stderr retention does not change functional stdout', () {
    final captured = BoundedCommandOutput();
    captured.add('stderr', 'e' * 100000, (_, _) {});
    captured.add('stdout', 'valid\n', (_, _) {});
    expect(captured.overflow, isFalse);
    expect(captured.value('stdout'), 'valid');
    expect(captured.value('stderr').length, 65536);
  });
}
