import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/models/approved_ntfs_shrink_plan.dart';
import 'package:ro_installer/models/ntfs_transaction_result.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/session_command_runner.dart';

void main() {
  final base =
      (jsonDecode(
            File('test/fixtures/ntfs_approvals_v1.json').readAsStringSync(),
          )
          as Map)['bases'][0];
  final approved = ApprovedNtfsShrinkPlan.fromJson(base['input']);
  final success = {
    'schemaVersion': 1,
    'status': 'success',
    'snapshot': base['created'],
    'preservationFingerprint': base['proof'],
  };
  final failure = {
    'schemaVersion': 1,
    'status': 'failed',
    'phase': 'filesystem',
    'progressKnown': true,
    'sourceMayHaveChanged': true,
    'gptWriteStarted': false,
    'verifiedGptCopies': 0,
    'cleanupFailed': false,
  };

  Future<NtfsTransactionResult> exchange(List<String> chunks) async {
    final directory = await Directory.systemTemp.createTemp(
      'ntfs-session-client-',
    );
    final path = '${directory.path}/private.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final done = Completer<void>();
    final clients = <Socket>[];
    final subscription = server.listen((socket) async {
      clients.add(socket);
      final lines = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      try {
        expect(await lines.moveNext(), isTrue);
        expect(jsonDecode(lines.current), {
          'op': 'ntfs-transaction',
          'approvedPlan': approved.json,
        });
        for (final chunk in chunks) {
          socket.add(utf8.encode(chunk));
          await socket.flush();
        }
        await socket.close();
      } on SocketException {
        // Oversized/truncated fixtures intentionally close the private client.
      } finally {
        await lines.cancel();
        socket.destroy();
        if (!done.isCompleted) done.complete();
      }
    });
    try {
      final result = await SessionCommandRunner(
        path,
      ).runNtfsTransaction(approved);
      await done.future;
      return result;
    } finally {
      for (final socket in clients) {
        socket.destroy();
      }
      await server.close();
      await subscription.cancel();
      await directory.delete(recursive: true);
    }
  }

  test('dedicated RPC returns exact owned storage success', () async {
    final result = await exchange([
      '${jsonEncode({'result': success})}\n',
    ]);
    expect(result.succeeded, isTrue);
    expect(result.snapshot!.json, base['created']);
  });
  test(
    'known filesystem failure retains partial state without generic commands',
    () async {
      final result = await exchange([
        '${jsonEncode({'result': failure})}\n',
      ]);
      expect(result.succeeded, isFalse);
      expect(result.progressKnown, isTrue);
      expect(result.sourceMayHaveChanged, isTrue);
      expect(result.gptWriteStarted, isFalse);
      final fake = FakeCommandRunner();
      final refused = await fake.runNtfsTransaction(approved);
      expect(refused.progressKnown, isTrue);
      expect(refused.sourceMayHaveChanged, isFalse);
      expect(fake.commandLog, isEmpty);
    },
  );
  final good = jsonEncode({'result': success});
  final malformed = <String, List<String>>{
    'empty': [],
    'bad-json': ['{\n'],
    'missing-field': ['{}\n'],
    'rpc-error': ['{"error":"SESSION_ERROR"}\n'],
    'no-newline': [good],
    'duplicate-result': [
      '{"result":${jsonEncode(failure)},"result":${jsonEncode(success)}}\n',
    ],
    'multiple-terminal': ['$good\n$good\n'],
    'trailing-partial': ['$good\n{'],
    'wrong-proof': [
      '${jsonEncode({
        'result': {...success, 'preservationFingerprint': 'f' * 64},
      })}\n',
    ],
    'oversized-frame': ['x' * 8192, 'x' * 8192, 'x'],
    'generic-stream': [
      '{"stream":"stderr","data":"PRIVATE_NATIVE_DIAGNOSTIC"}\n',
    ],
  };
  for (final row in malformed.entries) {
    test(
      'uncertain NTFS transport ${row.key} never claims unchanged',
      () async {
        final result = await exchange(row.value);
        expect(result.succeeded, isFalse);
        expect(result.progressKnown, isFalse);
        expect(result.sourceMayHaveChanged, isTrue);
        expect(result.gptWriteStarted, isTrue);
      },
    );
  }
}
