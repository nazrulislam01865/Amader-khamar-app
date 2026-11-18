import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

final voiceRecognitionServiceProvider = Provider<VoiceRecognitionService>((ref) {
  final service = VoiceRecognitionService();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});

class VoiceRecognitionService {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;
  String? _bengaliLocaleId;

  bool get isListening => _speech.isListening;
  bool get isAvailable => _speech.isAvailable;
  String? get currentLocaleId => _bengaliLocaleId;

  /// Initializes speech recognition engine and requests microphone permission
  Future<bool> initialize() async {
    if (_isInitialized && _speech.isAvailable) return true;

    // Check & request microphone permission
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      debugPrint('[VoiceService] Microphone permission denied: $micStatus');
      return false;
    }

    try {
      final available = await _speech.initialize(
        onError: (val) {
          debugPrint('[VoiceService] Speech error: ${val.errorMsg} (permanent: ${val.permanent})');
        },
        onStatus: (val) {
          debugPrint('[VoiceService] Speech status: $val');
        },
        debugLogging: kDebugMode,
      );

      if (available) {
        _isInitialized = true;
        await _resolveBengaliLocale();
      }

      return available;
    } catch (e) {
      debugPrint('[VoiceService] Speech initialization exception: $e');
      return false;
    }
  }

  /// Finds and selects Bangladeshi Bengali (bn_BD) or regional Bengali locale
  Future<void> _resolveBengaliLocale() async {
    try {
      final locales = await _speech.locales();
      debugPrint('[VoiceService] Found ${locales.length} available locales');

      // 1. Prefer bn_BD
      for (final loc in locales) {
        if (loc.localeId == 'bn_BD' || loc.localeId == 'bn-BD') {
          _bengaliLocaleId = loc.localeId;
          break;
        }
      }

      // 2. Fallback to any Bengali dialect (e.g. bn_IN or bn)
      if (_bengaliLocaleId == null) {
        for (final loc in locales) {
          if (loc.localeId.toLowerCase().startsWith('bn')) {
            _bengaliLocaleId = loc.localeId;
            break;
          }
        }
      }

      // 3. Fallback to default bn_BD if not explicitly listed
      _bengaliLocaleId ??= 'bn_BD';
      debugPrint('[VoiceService] Selected Bengali locale: $_bengaliLocaleId');
    } catch (e) {
      debugPrint('[VoiceService] Error resolving locales: $e');
      _bengaliLocaleId = 'bn_BD';
    }
  }

  /// Starts live listening and streams transcribed text in Bengali
  Future<bool> startListening({
    required void Function(String recognizedWords, bool isFinal) onResult,
    void Function(double soundLevel)? onSoundLevel,
    void Function(String errorMessage)? onError,
    void Function()? onDone,
  }) async {
    final ready = await initialize();
    if (!ready) {
      onError?.call('মাইক্রোফোন ব্যবহারের অনুমতি বা স্পিচ সার্ভিস চালু নেই।');
      return false;
    }

    if (_speech.isListening) {
      await stopListening();
    }

    try {
      await _speech.listen(
        onResult: (result) {
          onResult(result.recognizedWords, result.finalResult);
          if (result.finalResult) {
            onDone?.call();
          }
        },
        onSoundLevelChange: onSoundLevel,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          localeId: _bengaliLocaleId,
          listenFor: const Duration(seconds: 40),
          pauseFor: const Duration(seconds: 4),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[VoiceService] Exception in startListening: $e');
      onError?.call('ভয়েস শুনতে সমস্যা হয়েছে: $e');
      return false;
    }
  }

  /// Stops listening and completes recognition
  Future<void> stopListening() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
  }

  /// Cancels listening and discards current recognition
  Future<void> cancelListening() async {
    if (_speech.isListening) {
      await _speech.cancel();
    }
  }

  void dispose() {
    _speech.stop();
  }
}
