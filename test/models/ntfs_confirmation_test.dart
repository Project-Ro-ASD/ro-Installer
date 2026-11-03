import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/ntfs_shrink_assessment.dart';
import 'package:ro_installer/models/prepared_ntfs_shrink.dart';
import 'approved_ntfs_shrink_plan_test.dart' show clone, mutate;

void main() {
  final vectors =
      jsonDecode(
            File('test/fixtures/ntfs_confirmations_v1.json').readAsStringSync(),
          )
          as Map;
  final bases =
      (jsonDecode(
                File(
                  'test/fixtures/ntfs_preparations_v1.json',
                ).readAsStringSync(),
              )
              as Map)['bases']
          as List;
  PreparedNtfsShrink prepared(int index) {
    final base = bases[index] as Map;
    final p = base['proposal'];
    final response = base['response'];
    final assessment = NtfsShrinkAssessment.fromJson(
      {'plan': response['plan'], 'inspection': response['inspection']},
      snapshot: GptDiskSnapshot.fromJson(p['snapshot']),
      sourceNumber: p['sourceNumber'] as int,
      espNumber: p['espNumber'] as int,
      rootBytes: p['rootBytes'] as int,
    );
    return PreparedNtfsShrink.fromJson(response, expected: assessment);
  }

  for (var index = 0; index < bases.length; index++) {
    test(
      'public confirmation ${bases[index]['name']} is exact and defensive',
      () {
        final p = prepared(index);
        final expected = vectors['valid'][index]['confirmation'];
        expect(p.confirmation, expected);
        expect(p.matchesConfirmation(expected), isTrue);
        expect(p.confirmation.keys.toSet(), {
          'selection',
          'intent',
          'inspectionFingerprint',
          'preparationFingerprint',
        });
        final exported = p.confirmation;
        exported['selection']['rootBytes'] = 1;
        exported['intent']['source']['newEndSector'] = 0;
        exported['intent']['subvolumes']['home'] = '/other';
        exported['intent']['device']['diskSequence'] = 999;
        exported['preparationFingerprint'] = 'f' * 64;
        expect(p.confirmation, expected);
        expect(p.matchesConfirmation(exported), isFalse);
      },
    );
  }
  for (final row in vectors['invalid'] as List) {
    test('public confirmation rejects ${row['name']}', () {
      expect(
        prepared(0).matchesConfirmation(
          mutate(
            vectors['valid'][0]['confirmation'],
            row as Map<String, dynamic>,
          ),
        ),
        isFalse,
      );
    });
  }
  test('another prepared target or fingerprint cannot reuse confirmation', () {
    final p = prepared(0);
    expect(p.matchesConfirmation(prepared(1).confirmation), isFalse);
    final changed = clone(p.confirmation)
      ..['preparationFingerprint'] = 'f' * 64;
    expect(p.matchesConfirmation(changed), isFalse);
    for (final malformed in [
      null,
      [],
      true,
      1,
      'confirmation',
      {1: 'not a JSON field'},
    ]) {
      expect(p.matchesConfirmation(malformed), isFalse);
    }
  });
}
