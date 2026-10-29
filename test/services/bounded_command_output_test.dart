import 'dart:convert';
import 'dart:io';
import 'package:ro_installer/services/session_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/services/command_runner.dart';

void main() {
  test('overflow observation timeout cannot hold the command result', () async {
    final temp = Directory.systemTemp.createTempSync('p0-04-output-ipc-');
    final path = '${temp.path}/socket';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final clients = <Socket>[];
    var observed = false;
    final subscription = server.listen((socket) {
      clients.add(socket);
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) async {
            final request = jsonDecode(line) as Map;
            if (request['op'] == 'command') {
              for (var i = 0; i < 70; i++) {
                socket.writeln(
                  jsonEncode({'stream': 'stdout', 'data': 'x' * 16384}),
                );
              }
              socket.writeln(jsonEncode({'started': true, 'exitCode': 0}));
              await socket.flush();
              await socket.close();
            } else {
              // Deliberately withhold the logging ACK, without changing the command.
              observed = true;
            }
          });
    });
    try {
      final result = await SessionCommandRunner(
        path,
      ).run('readonly-fixture', []).timeout(const Duration(seconds: 3));
      expect(observed, isTrue);
      expect(result.started, isTrue);
      expect(result.exitCode, -126);
      expect(result.stdout, isEmpty);
      expect(result.stderr, 'COMMAND_OUTPUT_LIMIT');
    } finally {
      for (final socket in clients) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
      temp.deleteSync(recursive: true);
    }
  });
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
