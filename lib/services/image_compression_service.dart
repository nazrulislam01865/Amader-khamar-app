import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageCompressionResult {
  final Uint8List compressedBytes;
  final int originalSize;
  final int compressedSize;
  final double compressionRatio;

  const ImageCompressionResult({
    required this.compressedBytes,
    required this.originalSize,
    required this.compressedSize,
    required this.compressionRatio,
  });

  String get originalSizeFormatted => '${(originalSize / 1024).toStringAsFixed(1)} KB';
  String get compressedSizeFormatted => '${(compressedSize / 1024).toStringAsFixed(1)} KB';
}

/// Decode/resize/encode in a worker isolate to avoid blocking the capture UI.
/// Never replace a genuine original in the durable queue with an encoded copy.
class ImageCompressionService {
  static final ImageCompressionService _instance = ImageCompressionService._();
  factory ImageCompressionService() => _instance;
  ImageCompressionService._();

  Future<ImageCompressionResult> compressImage(Uint8List rawBytes, {int targetMaxKb = 4096}) async {
    if (targetMaxKb <= 0 || rawBytes.isEmpty) {
      throw const FormatException('Invalid photo or compression limit.');
    }
    final originalSize = rawBytes.length;
    final encoded = await Isolate.run(() => _compressEvidence(rawBytes, targetMaxKb * 1024));
    return ImageCompressionResult(
      compressedBytes: encoded,
      originalSize: originalSize,
      compressedSize: encoded.length,
      compressionRatio: encoded.length / originalSize,
    );
  }
}

Uint8List _compressEvidence(Uint8List bytes, int targetBytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null || decoded.width < 64 || decoded.height < 64) {
    throw const FormatException('Cannot decode evidence photo.');
  }
  // Photos already below the cap do not need lossy recompression.
  if (bytes.length <= targetBytes) return bytes;
  final png = bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
  var image = img.bakeOrientation(decoded);
  // Preserve PNG transparency and format. Most camera captures are JPEG.
  Uint8List best = bytes;
  for (final maxEdge in [2048, 1600, 1280, 1024]) {
    if (image.width > maxEdge || image.height > maxEdge) {
      final ratio = maxEdge / (image.width > image.height ? image.width : image.height);
      image = img.copyResize(image,
          width: (image.width * ratio).round(),
          height: (image.height * ratio).round(),
          interpolation: img.Interpolation.average);
    }
    if (image.width < 64 || image.height < 64) break;
    if (png) {
      final out = Uint8List.fromList(img.encodePng(image, level: 6));
      if (out.length < best.length) best = out;
    } else {
      for (final quality in [88, 80, 72]) {
        final out = Uint8List.fromList(img.encodeJpg(image, quality: quality));
        if (out.length < best.length) best = out;
        if (best.length <= targetBytes) break;
      }
    }
    if (best.length <= targetBytes) break;
  }
  // Some photographs are incompressible without destroying useful detail.
  // Return the smallest valid result, preserving the original if safer.
  return best;
}
