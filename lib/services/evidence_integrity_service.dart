import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Client-side evidence quality gate. Server policy remains authoritative.
/// Limits must be aligned with the Laravel upload contract before release.
class EvidenceIntegrityService {
  static const int minimumDimension = 64;
  static const int maximumBytes = 10 * 1024 * 1024;

  static Future<Uint8List> readValidPhoto(File file) async {
    final length = await file.length();
    if (length == 0 || length > maximumBytes) {
      throw const FormatException('ছবির আকার গ্রহণযোগ্য নয়। আবার ছবি তুলুন।');
    }
    return validatePhotoBytes(await file.readAsBytes());
  }

  static Future<Uint8List> validatePhotoBytes(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maximumBytes) {
      throw const FormatException('ছবির আকার গ্রহণযোগ্য নয়। আবার ছবি তুলুন।');
    }

    // Only upload formats supported by the multipart API's MIME handling.
    final isPng = bytes.length >= 8 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47;
    final isJpeg = bytes.length >= 3 &&
        bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
    if (!isPng && !isJpeg) {
      throw const FormatException('শুধু PNG বা JPEG ছবি গ্রহণযোগ্য।');
    }

    // Decode actual image data; a filename or magic-byte prefix is not proof.
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (_) {
      throw const FormatException('ছবিটি পড়া যাচ্ছে না। আবার ছবি তুলুন।');
    }
    try {
      final frame = await codec.getNextFrame();
      try {
        if (frame.image.width < minimumDimension ||
            frame.image.height < minimumDimension) {
          throw const FormatException('ছবিটির রেজল্যুশন খুব কম। আবার ছবি তুলুন।');
        }
      } finally {
        frame.image.dispose();
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('ছবিটি পড়া যাচ্ছে না। আবার ছবি তুলুন।');
    } finally {
      codec.dispose();
    }
    return bytes;
  }
}
