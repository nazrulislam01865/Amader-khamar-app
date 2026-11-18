class TaskPhotoModel {
  final String id;
  final String localPath;
  final DateTime capturedAt;
  final double latitude;
  final double longitude;
  final double gpsAccuracy;
  final DateTime? gpsCapturedAt;
  final bool insideGeofence;
  final String? locationName;

  const TaskPhotoModel({
    required this.id,
    required this.localPath,
    required this.capturedAt,
    required this.latitude,
    required this.longitude,
    required this.gpsAccuracy,
    this.gpsCapturedAt,
    required this.insideGeofence,
    this.locationName,
  });
}
