import 'dart:convert';
import 'dart:io';
import 'package:ro_installer/services/privileged_backend.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single != '--privileged-backend-v1') {
    exitCode = 9;
    return;
  }
  exitCode = await runPrivilegedBackend(
    stdin,
    (message) => stdout.writeln(jsonEncode(message)),
  );
}
