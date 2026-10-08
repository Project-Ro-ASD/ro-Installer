// Verify the native Dart runtime retains the helper's inherited kernel lease.
import 'dart:io';

Future<void> main() async {
  await Process.run('/usr/bin/true', const []);
  stdout.writeln('ready');
  await for (final _ in stdin) {}
}
