final RegExp _linuxUsernamePattern = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');

String normalizeLinuxUsername(String value) {
  return value.trim().toLowerCase();
}

bool isValidLinuxUsername(String value) {
  return _linuxUsernamePattern.hasMatch(normalizeLinuxUsername(value));
}

bool isWeakInstallerPassword({
  required String password,
  required String username,
  required String fullName,
}) {
  final normalizedPassword = password.trim().toLowerCase();
  final normalizedUsername = normalizeLinuxUsername(username);
  final normalizedFullName = fullName.trim().toLowerCase().replaceAll(
    RegExp(r'\s+'),
    '',
  );

  if (normalizedPassword.length < 8) {
    return true;
  }
  if (RegExp(r'^\d+$').hasMatch(normalizedPassword)) {
    return true;
  }
  if (RegExp(r'^(.)\1+$').hasMatch(normalizedPassword)) {
    return true;
  }
  if (normalizedUsername.isNotEmpty &&
      normalizedPassword == normalizedUsername) {
    return true;
  }
  if (normalizedFullName.isNotEmpty &&
      normalizedPassword == normalizedFullName) {
    return true;
  }
  return const {
    '1234',
    '12345',
    '123456',
    '12345678',
    'password',
    'admin',
    'administrator',
    'qwerty',
    'roasd',
    'ro-asd',
    'root',
  }.contains(normalizedPassword);
}
