import 'package:ro_installer/utils/manual_partition_sizing.dart';
import 'package:test/test.dart';

void main() {
  group('manual partition sizing', () {
    test('trailing free space icin GPT ve hizalama payi ayirir', () {
      final result = manualMaxNewPartitionBytes(
        41 * 1024 * 1024 * 1024,
        reserveTrailingSafetyGap: true,
      );

      expect(
        result,
        (41 * 1024 * 1024 * 1024) - kManualTrailingFreeSpaceReserveBytes,
      );
    });

    test('kucuk tasmalarda istegi guvenli boyuta kisar', () {
      final result = fitManualPartitionBytesToAvailable(
        10960 * 1024 * 1024,
        (85983198 - 63539200 + 1) * 512,
      );

      expect(result, (85983198 - 63539200 + 1) * 512);
    });

    test('buyuk tasmalarda null dondurur', () {
      final result = fitManualPartitionBytesToAvailable(
        100 * 1024 * 1024,
        90 * 1024 * 1024,
      );

      expect(result, isNull);
    });
  });
}
