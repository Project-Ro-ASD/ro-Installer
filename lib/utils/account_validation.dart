final RegExp _linuxUsernamePattern = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');

String normalizeLinuxUsername(String value) {
  return value.trim().toLowerCase();
}

bool isValidLinuxUsername(String value) {
  return _linuxUsernamePattern.hasMatch(normalizeLinuxUsername(value));
}
