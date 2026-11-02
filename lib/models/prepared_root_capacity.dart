import 'dart:convert';
import 'standard_storage_layout.dart';

/// Conservative deployment budget, not a product minimum or an FS guarantee.
final class PreparedRootCapacity {
  PreparedRootCapacity._(this.sourceBytes, this.entryCount);
  static const maximumSourceBytes = 8 * 1024 * 1024 * 1024 * 1024;
  static const maximumEntries = 2000000;
  static const entryReserveBytes = 16 * 1024;
  static const operationalReserveBytes = 2 * 1024 * 1024 * 1024;
  final int sourceBytes, entryCount;

  int get requiredRootBytes {
    final measured =
        sourceBytes +
        (sourceBytes + 4) ~/ 5 +
        entryCount * entryReserveBytes +
        operationalReserveBytes;
    const mib = 1048576;
    final rounded = (measured + mib - 1) ~/ mib * mib;
    return rounded < StandardStorageLayout.temporaryMinimumRootBytes
        ? StandardStorageLayout.temporaryMinimumRootBytes
        : rounded;
  }

  factory PreparedRootCapacity.fromRsyncStats(String raw) {
    if (utf8.encode(raw).length > 16384 || raw.contains('\u0000')) {
      throw const FormatException('Invalid source inventory output');
    }
    final lines = const LineSplitter().convert(raw);
    String only(String prefix) {
      final rows = lines.where((line) => line.startsWith(prefix));
      if (rows.length != 1) {
        throw const FormatException('Ambiguous source inventory');
      }
      return rows.single;
    }

    final bytes = RegExp(
      r'^Total file size: ([0-9]{1,16}) bytes$',
    ).firstMatch(only('Total file size:'));
    final files = RegExp(
      r'^Number of files: ([0-9]{1,16}) \(([a-z0-9:, ]+)\)$',
    ).firstMatch(only('Number of files:'));
    if (bytes == null || files == null) {
      throw const FormatException('Unsupported source inventory');
    }
    final size = int.tryParse(bytes[1]!), count = int.tryParse(files[1]!);
    if (size == null ||
        size <= 0 ||
        size > maximumSourceBytes ||
        count == null ||
        count <= 0 ||
        count > maximumEntries) {
      throw const FormatException('Source inventory exceeds safety bounds');
    }
    var sum = 0;
    final seen = <String>{};
    for (final item in files[2]!.split(', ')) {
      final part = RegExp(
        r'^(reg|dir|link|dev|special): ([0-9]{1,16})$',
      ).firstMatch(item);
      if (part == null || !seen.add(part[1]!)) {
        throw const FormatException('Invalid source inventory count');
      }
      final value = int.tryParse(part[2]!);
      if (value == null || value > count) {
        throw const FormatException('Invalid source inventory count');
      }
      sum += value;
    }
    if (sum != count) {
      throw const FormatException('Source inventory count mismatch');
    }
    return PreparedRootCapacity._(size, count);
  }
}
