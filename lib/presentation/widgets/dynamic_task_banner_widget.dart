import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/utils/date_formatter.dart';
import '../../data/models/task_model.dart';
import '../../models/field_boundary_model.dart';
import '../../models/task_assignment_model.dart';
import 'submitted_photos_grid.dart';

/// Dynamic Task Banner Widget that replaces the static default image:
/// - Before photos are submitted: Completely empty/collapsed (SizedBox.shrink).
/// - After photos are submitted: Prominently displays the 1st submitted photo as the hero banner
///   with support for both local and network images and tap-to-view lightbox.
class DynamicTaskBannerWidget extends StatelessWidget {
  final TaskModel? task;
  final TaskAssignmentModel? activeAssignment;
  final List<SubmittedPhotoDetail>? photos;
  final double height;
  final BorderRadius? borderRadius;

  const DynamicTaskBannerWidget({
    super.key,
    this.task,
    this.activeAssignment,
    this.photos,
    this.height = 185,
    this.borderRadius,
  });

  List<SubmittedPhotoDetail> _getEffectivePhotos() {
    if (photos != null && photos!.isNotEmpty) {
      return photos!;
    }
    if (task != null && task!.submittedPhotos.isNotEmpty) {
      return task!.submittedPhotos;
    }
    if (activeAssignment?.submission?.photosDetailed.isNotEmpty == true) {
      return activeAssignment!.submission!.photosDetailed;
    }
    if (task != null && task!.evidencePhotoUrls.isNotEmpty) {
      return task!.evidencePhotoUrls.asMap().entries.map((e) {
        return SubmittedPhotoDetail(
          id: e.key + 1,
          url: e.value,
          latitude: task!.latitude,
          longitude: task!.longitude,
          capturedAt: task!.submittedAt ?? task!.completedAt,
          insideGeofence: task!.geofencePassed ?? true,
          isLate: task!.isLate,
        );
      }).toList();
    }
    if (task != null && task!.photos.isNotEmpty) {
      return task!.photos.asMap().entries.map((e) {
        return SubmittedPhotoDetail(
          id: int.tryParse(e.value.id) ?? (e.key + 1),
          url: e.value.localPath,
          latitude: e.value.latitude,
          longitude: e.value.longitude,
          capturedAt: e.value.capturedAt.toIso8601String(),
          insideGeofence: e.value.insideGeofence,
          isLate: task!.isLate,
        );
      }).toList();
    }
    return const [];
  }

  void _openLightbox(BuildContext context, List<SubmittedPhotoDetail> allPhotos) {
    final effectiveBoundary = task?.fieldBoundary ??
        activeAssignment?.location?.fieldBoundary ??
        const FieldBoundaryModel(coordinates: []);

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (ctx) => PhotoLightboxDialog(
        photos: allPhotos,
        initialIndex: 0,
        boundary: effectiveBoundary,
        taskIsLate: task?.isLate ?? false,
      ),
    );
  }

  Widget _buildPhotoWidget(String url) {
    if (url.isEmpty) {
      return Container(
        color: const Color(0xFFF1F5F9),
        child: const Center(
          child: Icon(Icons.image_not_supported_outlined, color: Color(0xFF94A3B8), size: 36),
        ),
      );
    }

    // Network image (absolute URL)
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildFallback(),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            color: const Color(0xFFF1F5F9),
            child: const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
          );
        },
      );
    }

    // Local file on device storage
    try {
      final file = File(url);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildFallback(),
        );
      }
    } catch (_) {}

    // Relative backend URL
    final resolved = SubmittedPhotosGrid.resolveUrl(url);
    if (resolved.startsWith('http')) {
      return Image.network(
        resolved,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildFallback(),
      );
    }

    return _buildFallback();
  }

  Widget _buildFallback() {
    return Container(
      color: const Color(0xFFE2E8F0),
      child: const Center(
        child: Icon(Icons.image_outlined, color: Color(0xFF94A3B8), size: 36),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectivePhotos = _getEffectivePhotos();

    // 1. Primarily Empty State: If no photos submitted yet, collapse completely!
    if (effectivePhotos.isEmpty) {
      return const SizedBox.shrink();
    }

    // 2. Dynamic Banner: Render the 1st submitted photo
    final firstPhoto = effectivePhotos.first;
    final totalCount = effectivePhotos.length;
    final radius = borderRadius ?? BorderRadius.circular(16);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: () => _openLightbox(context, effectivePhotos),
          borderRadius: radius,
          child: Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: const Color(0xFFCBD5E1)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // First Evidence Photo
                  _buildPhotoWidget(firstPhoto.url),

                  // Top Gradient for badge readability
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.55),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Top-Left Badge: 1st Photo indicator
                  Positioned(
                    top: 10,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24, width: 0.8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.camera_alt_rounded, size: 13, color: Colors.white),
                          const SizedBox(width: 5),
                          Text(
                            totalCount > 1
                                ? '১ম প্রামাণ্য ছবি (${DateFormatter.toBanglaDigits(1)}/${DateFormatter.toBanglaDigits(totalCount)})'
                                : 'প্রামাণ্য ছবি',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bottom-Right Tap to Expand Indicator
                  Positioned(
                    bottom: 10,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24, width: 0.8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fullscreen_rounded, size: 15, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'বড় করে দেখুন',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
