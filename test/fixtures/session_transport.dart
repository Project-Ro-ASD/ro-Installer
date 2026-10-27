import 'dart:convert';
import 'dart:io';
import 'package:ro_installer/services/session_command_runner.dart';

Future<void> main() async {
  final runner = SessionCommandRunner(Platform.environment['FIXTURE_SOCKET']!);
  final logs = <String>[];
  final result = await runner.run(
    '/usr/bin/python3',
    [
      '-c',
      r'''
import fcntl,os,sys,time
path=sys.argv[1]
assert any(os.path.realpath('/proc/self/fd/'+n)==path for n in os.listdir('/proc/self/fd'))
fd=os.open(path,os.O_RDWR)
try:
 try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:pass
 else:raise AssertionError('missing lease')
finally:os.close(fd)
if len(sys.argv)>2:
 open(sys.argv[2],'w').write(str(os.getpid()))
 time.sleep(30)
print('lease-held:'+str(len(sys.stdin.read())))
''',
      Platform.environment['LOCK_FILE']!,
      if (Platform.environment.containsKey('COMMAND_PID'))
        Platform.environment['COMMAND_PID']!,
    ],
    stdinText: 'stdin-private-test',
    onLog: (event) => logs.add(event.displayMessage),
  );
  File(Platform.environment['RESULT_FILE']!).writeAsStringSync(
    jsonEncode({
      'started': result.started,
      'exit': result.exitCode,
      'stdout': result.stdout,
      'logs': logs,
      'namespace_test': false,
    }),
  );
  exitCode = result.exitCode;
}
