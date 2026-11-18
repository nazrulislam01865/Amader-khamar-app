import 'package:flutter_test/flutter_test.dart';
import 'package:bashir_agro_app_2/services/gps_service.dart';

void main() {
  group('Phase 1 verified GPS quality', () {
    final now = DateTime.utc(2026, 11, 18, 12);
    GpsCoordinate fix({
      DateTime? at, double accuracy = 8, double lat = 23.78, double lng = 90.41,
    }) => GpsCoordinate(
      latitude: lat, longitude: lng, accuracy: accuracy,
      timestamp: at ?? now.subtract(const Duration(seconds: 10)),
    );

    test('G01 fresh/accurate hardware-like fix is valid', () {
      expect(GpsService.isVerifiedFix(fix(), now: now), isTrue);
    });
    test('G02 stale and inaccurate fixes are rejected', () {
      expect(GpsService.isVerifiedFix(fix(at: now.subtract(const Duration(minutes: 5))), now: now), isFalse);
      expect(GpsService.isVerifiedFix(fix(accuracy: 500), now: now), isFalse);
      expect(GpsService.isVerifiedFix(null, now: now), isFalse);
    });
    test('G03 invalid coordinates and unproven timestamp are rejected', () {
      expect(GpsService.isVerifiedFix(fix(lat: 95), now: now), isFalse);
      expect(GpsService.isVerifiedFix(fix(lng: 185), now: now), isFalse);
      expect(GpsService.isVerifiedFix(GpsCoordinate(latitude: 23.78,longitude: 90.41), now: now), isFalse);
    });
  });
}
