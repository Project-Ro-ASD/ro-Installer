import 'mount_session.dart';

/// Internal terminal state; raw errors never cross the helper boundary.
class InstallOutcome {
  InstallOutcome({this.primaryFailure, required this.cleanup});
  final String? primaryFailure;
  final CleanupReport cleanup;
  bool get success => primaryFailure == null && cleanup.success;
}
