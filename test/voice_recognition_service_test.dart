import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bashir_agro_app_2/services/voice_recognition_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceRecognitionService Tests', () {
    test('1. Service provider registers and exposes initial properties', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(voiceRecognitionServiceProvider);
      expect(service, isNotNull);
      expect(service.isListening, isFalse);
      expect(service.isAvailable, isFalse);
    });

    test('2. Disposing container properly cleans up service', () {
      final container = ProviderContainer();
      final service = container.read(voiceRecognitionServiceProvider);
      expect(service, isNotNull);

      // Clean disposal
      expect(() => container.dispose(), returnsNormally);
    });
  });
}
