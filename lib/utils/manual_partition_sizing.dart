const int kManualPartitionAlignmentBytes = 1024 * 1024;
const int kManualTrailingFreeSpaceReserveBytes = 2 * 1024 * 1024;

int manualMaxNewPartitionBytes(
  int freeSpaceBytes, {
  required bool reserveTrailingSafetyGap,
}) {
  if (freeSpaceBytes <= 0) {
    return 0;
  }

  final reservedBytes = reserveTrailingSafetyGap
      ? kManualTrailingFreeSpaceReserveBytes
      : 0;
  final usableBytes = freeSpaceBytes - reservedBytes;
  if (usableBytes <= 0) {
    return 0;
  }

  return (usableBytes ~/ kManualPartitionAlignmentBytes) *
      kManualPartitionAlignmentBytes;
}

int? fitManualPartitionBytesToAvailable(
  int requestedBytes,
  int availableBytes, {
  int toleranceBytes = kManualTrailingFreeSpaceReserveBytes,
}) {
  if (requestedBytes <= 0 || availableBytes <= 0) {
    return null;
  }

  if (requestedBytes <= availableBytes) {
    return requestedBytes;
  }

  final overflowBytes = requestedBytes - availableBytes;
  if (overflowBytes <= toleranceBytes) {
    return availableBytes;
  }

  return null;
}
