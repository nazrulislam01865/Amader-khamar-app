import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class GpsCoordinate {
  final double latitude;
  final double longitude;
  final double accuracy; // meters
  final DateTime? timestamp;
  final double? heading;
  final double? speed;

  const GpsCoordinate({
    required this.latitude,
    required this.longitude,
    this.accuracy = 5.0,
    this.timestamp,
    this.heading,
    this.speed,
  });

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
    if (heading != null) 'heading': heading,
    if (speed != null) 'speed': speed,
  };
}

class GpsService {
  static final GpsService _instance = GpsService._();
  factory GpsService() => _instance;
  GpsService._();

  // Known field locations for simulation/testing
  static const GpsCoordinate southFieldInside = GpsCoordinate(
    latitude: 23.7808,
    longitude: 90.4152,
    accuracy: 4.5,
  );

  static const GpsCoordinate outsideGeofence = GpsCoordinate(
    latitude: 23.8500,
    longitude: 90.4800,
    accuracy: 12.0,
  );

  bool _simulationMode = false;
  bool _simulateInside = true;

  bool get simulationMode => kDebugMode && _simulationMode;
  bool get simulateInside => _simulateInside;

  void setSimulationMode(bool enabled, [bool inside = true]) {
    _simulationMode = kDebugMode && enabled;
    _simulateInside = inside;
  }

  /// Check if location services (GPS hardware switch) are enabled on the phone
  Future<bool> isLocationServiceEnabled() async {
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return false;
    }
  }

  /// Check current location permission status
  Future<LocationPermission> checkPermission() async {
    try {
      return await Geolocator.checkPermission();
    } catch (_) {
      return LocationPermission.denied;
    }
  }

  /// Open device location settings so user can turn on GPS
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }

  /// Open app settings if permission is denied forever
  Future<bool> openAppSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  /// Request location permissions if needed
  Future<bool> requestPermission() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('GpsService permission check error: $e');
      return false;
    }
  }

  /// Return only fresh, accurate, plausible device coordinates in production.
  /// Thresholds are provisional pending field validation/backend agreement.
  static const double maxAccuracyMeters = 50;
  static const Duration maxFixAge = Duration(seconds: 60);

  static bool isVerifiedFix(GpsCoordinate? coordinate, {DateTime? now}) {
    if (coordinate == null || coordinate.timestamp == null) return false;
    final age = (now ?? DateTime.now()).difference(coordinate.timestamp!);
    return coordinate.latitude.isFinite &&
        coordinate.longitude.isFinite &&
        coordinate.latitude >= -90 && coordinate.latitude <= 90 &&
        coordinate.longitude >= -180 && coordinate.longitude <= 180 &&
        coordinate.accuracy.isFinite && coordinate.accuracy > 0 &&
        coordinate.accuracy <= maxAccuracyMeters &&
        age >= const Duration(seconds: -5) && age <= maxFixAge;
  }

  /// Read verified hardware location; returns null rather than inventing a fix.
  Future<GpsCoordinate?> getCurrentLocation({bool forceHardware = false}) async {
    // Only explicit debug/test tooling can use the legacy simulator.
    if (kDebugMode && _simulationMode && !forceHardware) {
      final sample = _simulateInside ? southFieldInside : outsideGeofence;
      return GpsCoordinate(
        latitude: sample.latitude,
        longitude: sample.longitude,
        accuracy: sample.accuracy,
        timestamp: DateTime.now(),
      );
    }

    try {
      if (!await requestPermission()) return null;
      // A fresh cached fix is acceptable; stale or inaccurate fixes never are.
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        final candidate = _fromPosition(lastKnown);
        if (isVerifiedFix(candidate)) return candidate;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final candidate = _fromPosition(position);
      return isVerifiedFix(candidate) ? candidate : null;
    } catch (error) {
      debugPrint('Hardware GPS unavailable: $error');
      return null;
    }
  }

  static GpsCoordinate _fromPosition(Position pos) => GpsCoordinate(
    latitude: pos.latitude,
    longitude: pos.longitude,
    accuracy: pos.accuracy,
    heading: pos.heading,
    speed: pos.speed,
    timestamp: pos.timestamp,
  );

  /// Stream verified hardware positions; skip stale/inaccurate fixes.
  Stream<GpsCoordinate> getRealTimePositionStream() async* {
    if (!await requestPermission()) return;
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        final candidate = _fromPosition(lastKnown);
        if (isVerifiedFix(candidate)) yield candidate;
      }
    } catch (error) {
      debugPrint('Last known GPS unavailable: $error');
    }
    await for (final position in Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    )) {
      final candidate = _fromPosition(position);
      if (isVerifiedFix(candidate)) yield candidate;
    }
  }

  /// Calculate distance in meters between two coordinates (Haversine formula)
  double calculateDistanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadiusMeters = 6371000.0;
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }
}
