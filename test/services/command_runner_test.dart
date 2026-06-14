import 'package:test/test.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

void main() {
  group('SecretRedactor', () {
    test('wifi password arguments are masked in display command lines', () {
      final redacted = SecretRedactor.redactCommandLine('nmcli', [
        'dev',
        'wifi',
        'connect',
        'TestNet',
        'password',
        'secret123',
      ]);

      expect(redacted, contains('password ***'));
      expect(redacted, isNot(contains('secret123')));
    });

    test('chpasswd payloads are masked in exported log lines', () {
      final redacted = SecretRedactor.redactText(
        "chroot /mnt sh -c printf '%s\\n' 'testuser:testpassword' | chpasswd",
      );

      expect(redacted, contains("'***:***'"));
      expect(redacted, isNot(contains('testpassword')));
    });
  });

  group('FakeCommandRunner logging', () {
    test(
      'stdin secrets are not stored in command log or callback messages',
      () async {
        final fake = FakeCommandRunner();
        final messages = <String>[];

        await fake.run(
          'chroot',
          ['/mnt', 'chpasswd'],
          stdinText: 'testuser:testpassword\n',
          onLog: (event) => messages.add(event.displayMessage),
        );

        expect(fake.commandLog.single.stdinTextProvided, true);
        expect(fake.commandLog.single.commandLine, 'chroot /mnt chpasswd');
        expect(messages.join('\n'), isNot(contains('testpassword')));
      },
    );
  });
}
