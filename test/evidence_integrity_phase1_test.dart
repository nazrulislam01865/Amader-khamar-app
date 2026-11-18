import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bashir_agro_app_2/services/evidence_integrity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 evidence integrity', () {
    test('E01 real decodable image with acceptable dimensions passes unchanged', () async {
      final file = File('test/fixtures/valid_evidence.png');
      final raw = await file.readAsBytes();
      final validated = await EvidenceIntegrityService.readValidPhoto(file);
      expect(validated, orderedEquals(raw));
    });

    test('E02 missing file fails rather than inventing evidence', () async {
      await expectLater(
        EvidenceIntegrityService.readValidPhoto(File('test/fixtures/not-present.jpg')),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('E03 blank and corrupt bytes fail', () async {
      await expectLater(
        EvidenceIntegrityService.validatePhotoBytes(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        EvidenceIntegrityService.validatePhotoBytes(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });

    test('E04 one-pixel synthetic image fails', () async {
      await expectLater(
        EvidenceIntegrityService.readValidPhoto(File('test/fixtures/one_pixel.png')),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
