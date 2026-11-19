import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_formatter.dart';
import '../../../models/field_boundary_model.dart';
import '../../../models/task_assignment_model.dart';
import '../../../services/camera_service.dart';
import '../../../services/gps_service.dart';
import '../../../services/evidence_integrity_service.dart';
import '../../../services/location_resolution_service.dart';
import '../../../services/task_service.dart';
import '../../../services/voice_recognition_service.dart';
import '../../../state/app_state.dart';
import '../../../state/farmer_app_state.dart';
import '../../widgets/farmer_bottom_nav_bar.dart';
import '../../widgets/field_boundary_map_widget.dart';

class NewTaskScreen extends ConsumerStatefulWidget {
  const NewTaskScreen({super.key});

  @override
  ConsumerState<NewTaskScreen> createState() => _NewTaskScreenState();
}

class _NewTaskScreenState extends ConsumerState<NewTaskScreen> {
  final TextEditingController _descriptionController = TextEditingController(
    text: 'আজ সবজি ক্ষেতে সেচের পাইপ মেরামত করেছি।',
  );

  bool _isListening = false;
  double _soundLevel = 0.0;
  bool _isSubmitting = false;
  File? _selectedPhotoFile;
  Position? _currentPosition;
  String _locationName = 'লোকেশন খোঁজা হচ্ছে...';
  String _locationBadgeText = 'খোঁজা হচ্ছে...';
  bool _isLoadingLocation = true;
  bool _isInsideFarm = false;
  int? _matchedFarmLocationId;
  Timer? _timeTimer;
  DateTime _currentDateTime = DateTime.now();

  // Assigned Plot Selection & Dynamic Geofence Verification
  List<FarmLocationDetail> _assignedLocations = [];
  FarmLocationDetail? _selectedLocation;
  bool _isLoadingLocations = true;
  bool _locationsLoadFailed = false;
  bool _isInsideSelectedPlot = false;
  double _distanceToSelectedPlot = 0.0;
  String _geofenceStatusText = 'যাচাই করা হচ্ছে...';

  @override
  void initState() {
    super.initState();
    _loadAssignedLocations();
    _fetchCurrentLocation();

    // Update live clock every 30 seconds
    _timeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {
          _currentDateTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _timeTimer?.cancel();
    try {
      ref.read(voiceRecognitionServiceProvider).stopListening();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadAssignedLocations() async {
    if (!mounted) return;
    setState(() {
      _isLoadingLocations = true;
      _locationsLoadFailed = false;
    });
    List<FarmLocationDetail> farms = [];
    var apiFailed = false;
    try {
      farms = await ref.read(apiServiceProvider).getFarms();
    } catch (error) {
      apiFailed = true;
      debugPrint('Could not load authorized farms: $error');
    }

    // An unaudited assignment cache cannot prove current-account ownership.
    // Phase 2 can introduce an owner-scoped, versioned verified offline cache.
    if (!mounted) return;
    setState(() {
      _assignedLocations = farms;
      _selectedLocation = farms.isEmpty
          ? null
          : farms.firstWhere(
              (farm) => farm.id == _selectedLocation?.id,
              orElse: () => farms.first,
            );
      _isLoadingLocations = false;
      _locationsLoadFailed = apiFailed && farms.isEmpty;
    });
    _evaluateGeofence();
  }

  void _evaluateGeofence() {
    if (_selectedLocation == null) {
      setState(() {
        _isInsideSelectedPlot = false;
        _distanceToSelectedPlot = 0.0;
        _geofenceStatusText = 'প্লট নির্বাচন করুন';
      });
      return;
    }

    if (_currentPosition == null) {
      setState(() {
        _isInsideSelectedPlot = false;
        _distanceToSelectedPlot = 0.0;
        _geofenceStatusText = _isLoadingLocation
            ? 'জিপিএস খোঁজা হচ্ছে...'
            : 'জিপিএস বন্ধ (লোকেশন যাচাই সম্ভব হয়নি)';
      });
      return;
    }

    final lat = _currentPosition!.latitude;
    final lng = _currentPosition!.longitude;
    final boundary = _selectedLocation!.fieldBoundary;

    bool inside = false;
    double dist = 0.0;

    if (boundary != null && boundary.isNotEmpty) {
      inside = boundary.isPointInside(lat, lng, 10.0);
      dist = boundary.distanceToBoundaryMeters(lat, lng);
    } else if (_selectedLocation!.latitude != null && _selectedLocation!.longitude != null) {
      final rawDist = Geolocator.distanceBetween(
        lat,
        lng,
        _selectedLocation!.latitude!,
        _selectedLocation!.longitude!,
      );
      final radius = _selectedLocation!.geofenceRadiusMeters > 0
          ? _selectedLocation!.geofenceRadiusMeters.toDouble()
          : 40.0;
      inside = rawDist <= radius;
      dist = rawDist;
    }

    if (mounted) {
      setState(() {
        _isInsideSelectedPlot = inside;
        _distanceToSelectedPlot = dist;
        if (inside) {
          _geofenceStatusText = 'প্লটের ভেতরে আছেন';
        } else {
          final distBn = DateFormatter.toBanglaDigits(
            dist >= 1000 ? (dist / 1000).toStringAsFixed(1) : dist.toStringAsFixed(0),
          );
          final unit = dist >= 1000 ? 'কিমি' : 'মিটার';
          _geofenceStatusText = 'প্লটের বাইরে ($distBn $unit দূরে)';
        }
      });
    }
  }

  Future<void> _fetchCurrentLocation() async {
    setState(() => _isLoadingLocation = true);
    try {
      final gpsService = ref.read(gpsServiceProvider);
      final coord = await gpsService.getCurrentLocation().timeout(const Duration(seconds: 12));
      if (coord != null && GpsService.isVerifiedFix(coord)) {
        final lat = coord.latitude;
        final lng = coord.longitude;
        final acc = coord.accuracy;
        _currentPosition = Position(
          latitude: lat,
          longitude: lng,
          timestamp: coord.timestamp!,
          accuracy: acc,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );

        final resolver = ref.read(locationResolutionServiceProvider);
        final resolved = await resolver.resolveLocation(
          latitude: lat,
          longitude: lng,
          accuracy: acc,
        );

        if (mounted) {
          setState(() {
            _locationName = resolved.displayName;
            _locationBadgeText = resolved.badgeText;
            _isInsideFarm = resolved.isInsideFarm;
            _matchedFarmLocationId = resolved.farmLocationId;
            _isLoadingLocation = false;
          });
          _evaluateGeofence();
        }
        return;
      }
    } catch (_) {
      // GPS unavailable, timed out, or permission denied
    }

    if (mounted) {
      setState(() {
        _locationName = 'লোকেশন পাওয়া যায়নি (ঐচ্ছিক)';
        _locationBadgeText = 'লোকেশন বন্ধ';
        _isInsideFarm = false;
        _matchedFarmLocationId = null;
        _isLoadingLocation = false;
      });
      _evaluateGeofence();
    }
  }

  Future<void> _toggleVoiceRecording() async {
    final voiceService = ref.read(voiceRecognitionServiceProvider);

    if (_isListening) {
      await voiceService.stopListening();
      if (mounted) {
        setState(() {
          _isListening = false;
          _soundLevel = 0.0;
        });
      }
      return;
    }

    // Clear default placeholder text if user hasn't edited it yet
    if (_descriptionController.text.trim() == 'আজ সবজি ক্ষেতে সেচের পাইপ মেরামত করেছি।') {
      _descriptionController.clear();
    }

    setState(() {
      _isListening = true;
      _soundLevel = 0.0;
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.mic_rounded, color: Colors.white, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'স্পষ্ট বাংলায় বলুন, আপনার কথা লেখা হচ্ছে...',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF006837),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    final started = await voiceService.startListening(
      onResult: (words, isFinal) {
        if (mounted) {
          setState(() {
            _descriptionController.text = words;
            _descriptionController.selection = TextSelection.fromPosition(
              TextPosition(offset: _descriptionController.text.length),
            );
            if (isFinal) {
              _isListening = false;
              _soundLevel = 0.0;
            }
          });
        }
      },
      onSoundLevel: (level) {
        if (mounted && _isListening) {
          setState(() {
            _soundLevel = level;
          });
        }
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _isListening = false;
            _soundLevel = 0.0;
          });
        }
      },
      onError: (errorMsg) {
        if (mounted) {
          setState(() {
            _isListening = false;
            _soundLevel = 0.0;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: Colors.red.shade700,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
    );

    if (!started && mounted) {
      setState(() {
        _isListening = false;
        _soundLevel = 0.0;
      });
    }
  }

  void _showAudioGuideDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.volume_up_rounded, color: Color(0xFF006837), size: 24),
              SizedBox(width: 10),
              Text(
                'কীভাবে বলবেন শুনুন',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'মাইক্রোফোন বাটনে চাপ দিয়ে স্পষ্ট বাংলায় বলুন আপনি আজ খামারে কী কাজ সম্পন্ন করেছেন।',
                style: TextStyle(fontSize: 13.5, color: Color(0xFF475569), height: 1.4),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFDCFCE7)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'উদাহরণসমূহ:',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF15803D)),
                    ),
                    SizedBox(height: 6),
                    Text('• "আজ সবজি ক্ষেতে সেচের পাইপ মেরামত করেছি।"', style: TextStyle(fontSize: 12.5, color: Color(0xFF334155))),
                    SizedBox(height: 4),
                    Text('• "পুকুরে মাছের খাবার দেওয়া শেষ করেছি।"', style: TextStyle(fontSize: 12.5, color: Color(0xFF334155))),
                    SizedBox(height: 4),
                    Text('• "গরুর শেড পরিষ্কার করেছি ও ঘাস দিয়েছি।"', style: TextStyle(fontSize: 12.5, color: Color(0xFF334155))),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('বুঝেছি', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF006837))),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openLiveCamera() async {
    final result = await Navigator.push<File?>(
      context,
      MaterialPageRoute(
        builder: (ctx) => const _NewTaskLiveCameraScreen(),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _selectedPhotoFile = result;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('মাঠের ছবি সফলভাবে সংযুক্ত করা হয়েছে'),
            ],
          ),
          backgroundColor: Color(0xFF006837),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _submitTask() async {
    final text = _descriptionController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('অনুগ্রহ করে কাজের বিবরণ লিখুন বা মুখে বলুন।'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Assigned Plot Validation
    if (_selectedLocation == null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('অনুগ্রহ করে কোন প্লটে কাজ করেছেন তা নির্বাচন করুন।'),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Mandatory Photo Validation
    if (_selectedPhotoFile == null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.camera_alt_rounded, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('কাজের ছবি তোলা বাধ্যতামূলক! লাইভ ক্যামেরা দিয়ে মাঠের ছবি তুলুন।'),
              ),
            ],
          ),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // No missing/invalid evidence or unverifiable GPS reaches the API.
    try {
      await EvidenceIntegrityService.readValidPhoto(_selectedPhotoFile!);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ছবিটি পাওয়া যায়নি বা নষ্ট হয়েছে। আবার ছবি তুলুন।'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (_currentPosition == null ||
        !GpsService.isVerifiedFix(GpsCoordinate(
          latitude: _currentPosition!.latitude,
          longitude: _currentPosition!.longitude,
          accuracy: _currentPosition!.accuracy,
          timestamp: _currentPosition!.timestamp,
        ))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('সঠিক জিপিএস অবস্থান পাওয়া যায়নি। আবার চেষ্টা করুন।'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    // Outside Plot Confirmation Dialog (User requirement: সতর্কবার্তা ডায়ালগ দিয়ে জমা দেওয়ার অনুমতি দেওয়া)
    if (_currentPosition != null && !_isInsideSelectedPlot) {
      final distBn = DateFormatter.toBanglaDigits(
        _distanceToSelectedPlot >= 1000
            ? (_distanceToSelectedPlot / 1000).toStringAsFixed(1)
            : _distanceToSelectedPlot.toStringAsFixed(0),
      );
      final unit = _distanceToSelectedPlot >= 1000 ? 'কিমি' : 'মিটার';

      final proceedOutside = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 26),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'প্লটের বাইরে অবস্থান',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'আপনি নির্বাচিত প্লট "${_selectedLocation!.name}" এর নির্ধারিত সীমানা হতে আনুমানিক $distBn $unit বাইরে অবস্থান করছেন।',
                style: const TextStyle(fontSize: 13.5, height: 1.45, color: Color(0xFF334155)),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: Color(0xFFB45309), size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'এই কাজটি জমা দিলে অ্যাডমিন প্যানেলে "প্লটের বাইরে" ফ্ল্যাগ প্রদর্শিত হবে।',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF92400E)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'আপনি কি নিশ্চিত যে বাইরে থেকেই কাজটি জমা দিতে চান?',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('বাতিল করুন', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD97706),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('হ্যাঁ, জমা দিন', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (proceedOutside != true) {
        return;
      }
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await ref.read(taskListProvider.notifier).submitSelfReportedTask(
        description: text,
        latitude: _currentPosition?.latitude,
        longitude: _currentPosition?.longitude,
        accuracy: _currentPosition?.accuracy,
        locationName: _selectedLocation?.name ?? _locationName,
        farmLocationId: _selectedLocation?.id ?? _matchedFarmLocationId,
        photoPath: _selectedPhotoFile?.path,
      );

      // Refresh tasks
      ref.read(farmerTasksProvider.notifier).refresh();

      if (!mounted) return;

      // Show success modal celebration
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 60,
                  height: 60,
                  decoration: const BoxDecoration(
                    color: Color(0xFFDCFCE7),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(Icons.check_rounded, color: Color(0xFF15803D), size: 36),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'কাজ সফলভাবে জমা হয়েছে!',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'আপনার নতুন কাজটি "সম্পন্ন কাজ" তালিকায় যুক্ত করা হয়েছে।',
                  style: TextStyle(fontSize: 13.5, color: Color(0xFF64748B)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      // Switch to Completed filter and navigate to dashboard
                      ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.completed);
                      context.go('/dashboard');
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF006837),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('সম্পন্ন কাজের তালিকা দেখুন', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              ],
            ),
          );
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('কাজ জমা দিতে সমস্যা হয়েছে: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final formattedDate = DateFormatter.formatFullDateWithDay();
    final formattedTime = DateFormatter.formatDateTimeToBanglaTime(_currentDateTime.toIso8601String());

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Column(
        children: [
          // Gradient Green Header
          _buildHeader(context),

          // Main Scrollable Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. "কী কাজ করেছেন?" Section
                  _buildSectionTitle('কী কাজ করেছেন?'),
                  const SizedBox(height: 8),
                  _buildVoiceInputCard(),

                  const SizedBox(height: 16),

                  // 2. "কাজের বিবরণ" Section
                  _buildSectionTitle('কাজের বিবরণ'),
                  const SizedBox(height: 8),
                  _buildDescriptionCard(),

                  const SizedBox(height: 16),

                  // 3. "কাজের ছবি" (বাধ্যতামূলক) Section
                  _buildPhotoSectionHeader(),
                  const SizedBox(height: 8),
                  _buildPhotoPickerCard(),
                  const SizedBox(height: 4),
                  const Text(
                    'মাঠে উপস্থিত থেকে সরাসরি ক্যামেরা দিয়ে কাজের বাস্তব ছবি তোলা বাধ্যতামূলক।',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),

                  const SizedBox(height: 16),

                  // 4. "কাজের স্থান ও সময়" Section
                  _buildSectionTitle('কাজের স্থান ও সময়'),
                  const SizedBox(height: 8),
                  _buildLocationCard(formattedDate, formattedTime),

                  const SizedBox(height: 16),

                  // 5. Completion Guarantee Banner
                  _buildGuaranteeBanner(),

                  const SizedBox(height: 16),

                  // 6. Submit Button
                  _buildSubmitButton(),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const FarmerBottomNavBar(
        currentIndex: 1,
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF006837), Color(0xFF0E8A4A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 10,
        left: 16,
        right: 16,
        bottom: 16,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                context.go('/dashboard');
              }
            },
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 26),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'নতুন কাজ যোগ করুন',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'যে কাজ করেছেন, তা বলুন বা লিখুন',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }

  Widget _buildVoiceInputCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3FAF5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDCFCE7), width: 1.2),
      ),
      child: Column(
        children: [
          // Audio Guide Button
          Align(
            alignment: Alignment.topRight,
            child: InkWell(
              onTap: () => _showAudioGuideDialog(context),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFD1FAE5), width: 1.1),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.volume_up_outlined, size: 16, color: Color(0xFF006837)),
                    SizedBox(width: 4),
                    Text(
                      'কীভাবে বলবেন শুনুন',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF006837),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Big Mic Button with Dynamic Pulsing Wave Effect
          GestureDetector(
            onTap: _toggleVoiceRecording,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _isListening ? 92 : 88,
              height: _isListening ? 92 : 88,
              decoration: BoxDecoration(
                color: _isListening ? const Color(0xFFBBF7D0) : const Color(0xFFDCFCE7),
                shape: BoxShape.circle,
                boxShadow: _isListening
                    ? [
                        BoxShadow(
                          color: const Color(0xFF10B981).withValues(alpha: 0.5),
                          blurRadius: 18 + (_soundLevel.clamp(0.0, 10.0) * 1.5),
                          spreadRadius: 4 + (_soundLevel.clamp(0.0, 10.0) * 1.2),
                        ),
                      ]
                    : [],
              ),
              child: Center(
                child: Container(
                  width: 66,
                  height: 66,
                  decoration: BoxDecoration(
                    color: _isListening ? const Color(0xFFDC2626) : const Color(0xFF006837),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Mic label
          Text(
            _isListening ? 'শুনছি... বলুন' : 'চাপ দিয়ে বলুন',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: _isListening ? const Color(0xFFDC2626) : const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _isListening
                ? 'কথা বলা শেষ হলে আবার বাটনে চাপুন বা থামুন'
                : 'আপনার কথা বাংলায় লেখা হবে',
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _descriptionController,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textPrimary,
                    height: 1.35,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'এখানে কাজের বিবরণ লিখুন বা মুখে বলুন...',
                    hintStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                  ),
                ),
              ),
              const Icon(
                Icons.edit_rounded,
                size: 20,
                color: Color(0xFF64748B),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'ভুল হলে ঠিক করুন বা আবার বলুন',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _toggleVoiceRecording,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic_none_rounded, size: 14, color: Color(0xFF006837)),
                      SizedBox(width: 3.5),
                      Text(
                        'আবার বলুন',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF006837),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSectionHeader() {
    return Row(
      children: [
        const Text(
          'কাজের ছবি',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFFEE2E2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            'বাধ্যতামূলক *',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Color(0xFFDC2626),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoPickerCard() {
    if (_selectedPhotoFile != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF86EFAC), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 72,
                height: 72,
                child: Image.file(
                  _selectedPhotoFile!,
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, _, __) => Container(
                    color: const Color(0xFFDCFCE7),
                    child: const Icon(Icons.broken_image_rounded, color: Color(0xFF006837)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.check_circle_rounded, color: Color(0xFF15803D), size: 18),
                      SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'মাঠের লাইভ ছবি যুক্ত হয়েছে',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF15803D),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      InkWell(
                        onTap: _openLiveCamera,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFCBD5E1)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.camera_alt_rounded, size: 14, color: Color(0xFF334155)),
                              SizedBox(width: 4),
                              Text(
                                'নতুন ছবি তুলুন',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _selectedPhotoFile = null;
                          });
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEE2E2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFFECACA)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.delete_outline_rounded, size: 14, color: Color(0xFFDC2626)),
                              SizedBox(width: 4),
                              Text(
                                'মুছুন',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFFDC2626)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: _openLiveCamera,
      borderRadius: BorderRadius.circular(14),
      child: CustomPaint(
        painter: _DashedRectPainter(
          color: const Color(0xFFFCA5A5),
          strokeWidth: 1.5,
          gap: 5.0,
          radius: 14,
        ),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.camera_alt_rounded, color: Color(0xFFDC2626), size: 30),
                SizedBox(height: 6),
                Text(
                  '📷 সরাসরি ক্যামেরা দিয়ে ছবি তুলুন *',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFDC2626),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'মাঠে লাইভ উপস্থিত থেকে ছবি তোলা বাধ্যতামূলক (গ্যালারি প্রযোজ্য নয়)',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF7F1D1D)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPlotPickerBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            top: 20,
            left: 20,
            right: 20,
            bottom: MediaQuery.of(ctx).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top notch handle
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title Header
              const Row(
                children: [
                  Icon(Icons.landscape_rounded, color: Color(0xFF006837), size: 26),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'কোন প্লটে কাজ করেছেন?',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'আপনার নির্ধারিত প্লট সমূহের তালিকা',
                          style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1, color: Color(0xFFF1F5F9)),
              const SizedBox(height: 12),

              // List of Plots
              if (_isLoadingLocations)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: CircularProgressIndicator(color: Color(0xFF006837)),
                  ),
                )
              else if (_assignedLocations.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _locationsLoadFailed
                            ? 'প্লটের তথ্য লোড করা যায়নি। ইন্টারনেট সংযোগ পরীক্ষা করুন।'
                            : 'কোনো নির্ধারিত প্লট পাওয়া যায়নি',
                        style: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _loadAssignedLocations();
                        },
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('আবার চেষ্টা করুন'),
                      ),
                    ],
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _assignedLocations.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final plot = _assignedLocations[index];
                      final isSelected = _selectedLocation?.id == plot.id;

                      final areaText = (plot.area != null && plot.area! > 0)
                          ? '${DateFormatter.toBanglaDigits(plot.area!.toStringAsFixed(2))} ${plot.areaUnit}'
                          : null;

                      return InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() {
                            _selectedLocation = plot;
                          });
                          _evaluateGeofence();
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF16A34A) : const Color(0xFFE2E8F0),
                              width: isSelected ? 1.8 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFE2E8F0),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isSelected ? Icons.check_circle_rounded : Icons.location_on_outlined,
                                  color: isSelected ? const Color(0xFF15803D) : const Color(0xFF64748B),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      plot.name,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: isSelected ? const Color(0xFF15803D) : const Color(0xFF1E293B),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Row(
                                      children: [
                                        if (plot.type.isNotEmpty) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: const Color(0xFFCBD5E1), width: 0.8),
                                            ),
                                            child: Text(
                                              plot.type,
                                              style: const TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                        ],
                                        if (areaText != null) ...[
                                          Text(
                                            areaText,
                                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                                          ),
                                          const SizedBox(width: 6),
                                        ],
                                        Text(
                                          plot.locationCode,
                                          style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check_rounded, color: Color(0xFF16A34A), size: 22),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocationCard(String formattedDate, String formattedTime) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Plot selection row
          InkWell(
            onTap: () => _showPlotPickerBottomSheet(context),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
              ),
              child: Row(
                children: [
                  const Icon(Icons.landscape_rounded, color: Color(0xFF006837), size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'কোন প্লটে কাজ করেছেন?',
                          style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _selectedLocation != null
                              ? '${_selectedLocation!.name}${_selectedLocation!.type.isNotEmpty ? ' • ${_selectedLocation!.type}' : ''}'
                              : 'প্লট নির্বাচন করতে ট্যাপ করুন',
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'পরিবর্তন',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF15803D),
                          ),
                        ),
                        SizedBox(width: 2),
                        Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: Color(0xFF15803D)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Live Geofence Status Row
          Row(
            children: [
              const Icon(Icons.my_location_rounded, color: Color(0xFF475569), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('আপনার অবস্থান যাচাই', style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B))),
                    const SizedBox(height: 2),
                    Text(
                      _geofenceStatusText,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _isInsideSelectedPlot
                            ? const Color(0xFF15803D)
                            : (_currentPosition != null
                                ? const Color(0xFFB45309)
                                : const Color(0xFF475569)),
                      ),
                    ),
                  ],
                ),
              ),
              // Flag Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                decoration: BoxDecoration(
                  color: _isInsideSelectedPlot
                      ? const Color(0xFFDCFCE7)
                      : (_currentPosition != null
                          ? const Color(0xFFFEF3C7)
                          : const Color(0xFFF1F5F9)),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _isInsideSelectedPlot
                        ? const Color(0xFF86EFAC)
                        : (_currentPosition != null
                            ? const Color(0xFFFDE68A)
                            : const Color(0xFFCBD5E1)),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isLoadingLocation)
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.8, color: Color(0xFF64748B)),
                      )
                    else
                      Icon(
                        _isInsideSelectedPlot
                            ? Icons.check_circle_rounded
                            : (_currentPosition != null
                                ? Icons.warning_amber_rounded
                                : Icons.location_off_rounded),
                        size: 13,
                        color: _isInsideSelectedPlot
                            ? const Color(0xFF15803D)
                            : (_currentPosition != null
                                ? const Color(0xFFB45309)
                                : const Color(0xFF64748B)),
                      ),
                    const SizedBox(width: 4),
                    Text(
                      _isInsideSelectedPlot
                          ? 'ভেতরে আছেন'
                          : (_currentPosition != null ? 'বাইরে আছেন' : 'জিপিএস বন্ধ'),
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: _isInsideSelectedPlot
                            ? const Color(0xFF15803D)
                            : (_currentPosition != null
                                ? const Color(0xFFB45309)
                                : const Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // GPS Refresh Button
              InkWell(
                onTap: () {
                  _fetchCurrentLocation();
                },
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF475569)),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Interactive Map showing Selected Plot Boundary & Farmer's Live GPS Location
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0D000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FieldBoundaryMapWidget(
                boundary: _selectedLocation?.fieldBoundary ?? const FieldBoundaryModel(coordinates: []),
                farmName: _selectedLocation?.name ?? 'কৃষি জমি',
                locationCode: _selectedLocation?.locationCode ?? '',
                farmType: _selectedLocation?.type ?? '',
                formattedArea: _selectedLocation?.formattedArea ?? '',
                farmerLat: _currentPosition?.latitude,
                farmerLng: _currentPosition?.longitude,
                targetLat: _selectedLocation?.effectiveLatitude,
                targetLng: _selectedLocation?.effectiveLongitude,
                gpsAccuracy: _currentPosition?.accuracy ?? 5.0,
                isInteractive: true,
                height: 230,
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Map legend wraps rather than overflowing on compact/text-scaled screens.
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E676),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF00C853), width: 1.2),
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'নির্বাচিত প্লট সীমানা',
                    style: TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF00B0FF), width: 1.2),
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'আমার অবস্থান (লাইভ জিপিএস)',
                    style: TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),

          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1, color: Color(0xFFF1F5F9)),
          ),

          // Submission Time Row
          Row(
            children: [
              const Icon(Icons.access_time_rounded, color: Color(0xFF475569), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('জমা দেওয়ার সময়', style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B))),
                    const SizedBox(height: 2),
                    Text(
                      '$formattedDate • $formattedTime',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF64748B)),
              SizedBox(width: 5),
              Expanded(
                child: Text(
                  'সিলেক্টেড প্লটের সাপেক্ষে জিপিএস উপস্থিতি রেকর্ড করা হবে',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGuaranteeBanner() {
    final bool isOutside = _currentPosition != null && !_isInsideSelectedPlot;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isOutside ? const Color(0xFFFEF3C7) : const Color(0xFFE6F4EA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isOutside ? const Color(0xFFFDE68A) : const Color(0xFFBBF7D0),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isOutside ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
            color: isOutside ? const Color(0xFFB45309) : const Color(0xFF15803D),
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isOutside
                  ? 'প্লটের বাইরে থেকে জমা দিলে "বাইরে সম্পন্ন" হিসেবে ফ্ল্যাগ থাকবে'
                  : 'জমা দিলে কাজটি সফলভাবে "সম্পন্ন" হিসেবে যুক্ত হবে',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isOutside ? const Color(0xFF92400E) : const Color(0xFF15803D),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: _isSubmitting ? null : _submitTask,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF006837),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF006837).withValues(alpha: 0.6),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: _isSubmitting
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_rounded, size: 21, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'কাজ জমা দিন',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
      ),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;
  final double radius;

  _DashedRectPainter({
    required this.color,
    this.strokeWidth = 1.0,
    this.gap = 5.0,
    this.radius = 12.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(radius),
    );

    final Path path = Path()..addRRect(rrect);
    final Path dashedPath = Path();

    double distance = 0.0;
    for (final PathMetric metric in path.computeMetrics()) {
      while (distance < metric.length) {
        final double len = distance + gap > metric.length ? metric.length - distance : gap;
        dashedPath.addPath(metric.extractPath(distance, distance + len), Offset.zero);
        distance += len * 2;
      }
      distance = 0.0;
    }

    canvas.drawPath(dashedPath, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.gap != gap ||
        oldDelegate.radius != radius;
  }
}

class _NewTaskLiveCameraScreen extends StatefulWidget {
  const _NewTaskLiveCameraScreen();

  @override
  State<_NewTaskLiveCameraScreen> createState() => _NewTaskLiveCameraScreenState();
}

class _NewTaskLiveCameraScreenState extends State<_NewTaskLiveCameraScreen> {
  final CameraService _cameraService = CameraService.instance;
  bool _isInitializing = true;
  bool _isCapturing = false;
  FlashMode _flashMode = FlashMode.auto;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    setState(() => _isInitializing = true);
    await _cameraService.initialize();
    if (mounted) {
      setState(() {
        _isInitializing = false;
        _flashMode = _cameraService.flashMode;
      });
    }
  }

  @override
  void dispose() {
    _cameraService.dispose();
    super.dispose();
  }

  Future<void> _handleFlashToggle() async {
    final newMode = await _cameraService.cycleFlashMode();
    if (mounted) {
      setState(() => _flashMode = newMode);
    }
  }

  Future<void> _handleCameraSwitch() async {
    setState(() => _isInitializing = true);
    await _cameraService.switchCamera();
    if (mounted) {
      setState(() => _isInitializing = false);
    }
  }

  Future<void> _takePhoto() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      if (!_cameraService.isInitialized) {
        throw StateError(_cameraService.errorMessage ?? 'ক্যামেরা চালু করা সম্ভব হয়নি।');
      }
      final captured = await _cameraService.takePicture();
      if (captured == null) throw StateError('ক্যামেরা ছবি তুলতে পারেনি।');
      await EvidenceIntegrityService.readValidPhoto(File(captured.path));
      final photoPath = captured.path;

      if (photoPath.isNotEmpty && mounted) {
        Navigator.pop(context, File(photoPath));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ছবি সংরক্ষণ করতে সমস্যা হয়েছে। আবার চেষ্টা করুন।'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ছবি তুলতে ত্রুটি: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  IconData _getFlashIcon(FlashMode mode) {
    switch (mode) {
      case FlashMode.always:
        return Icons.flash_on_rounded;
      case FlashMode.off:
        return Icons.flash_off_rounded;
      case FlashMode.auto:
      default:
        return Icons.flash_auto_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraService.controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Camera Preview or Fallback View
            Center(
              child: _isInitializing
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF10B981)),
                        SizedBox(height: 16),
                        Text(
                          'ক্যামেরা চালু করা হচ্ছে...',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ],
                    )
                  : (_cameraService.isInitialized && controller != null)
                      ? AspectRatio(
                          aspectRatio: 1 / controller.value.aspectRatio,
                          child: CameraPreview(controller),
                        )
                      : Container(
                          padding: const EdgeInsets.all(24),
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.videocam_off_rounded, color: Colors.amber, size: 48),
                              const SizedBox(height: 14),
                              const Text(
                                'ক্যামেরা সেন্সর পাওয়া যায়নি',
                                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'ডিভাইসে ক্যামেরা চালু করা সম্ভব হয়নি। অনুমতি দিয়ে আবার চেষ্টা করুন।',
                                style: TextStyle(color: Colors.white70, fontSize: 13),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 18),
                              ElevatedButton.icon(
                                onPressed: _initCamera,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('আবার চেষ্টা করুন'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF006837),
                                  foregroundColor: Colors.white,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => permissions.openAppSettings(),
                                icon: const Icon(Icons.settings_rounded),
                                label: const Text('ক্যামেরার অনুমতি দিন'),
                              ),
                            ],
                          ),
                        ),
            ),

            // Top Bar
            Positioned(
              top: 10,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                    style: IconButton.styleFrom(backgroundColor: Colors.black45),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fiber_manual_record_rounded, color: Color(0xFFDC2626), size: 12),
                        SizedBox(width: 6),
                        Text(
                          'মাঠের লাইভ ক্যামেরা',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _handleFlashToggle,
                    icon: Icon(_getFlashIcon(_flashMode), color: Colors.white, size: 24),
                    style: IconButton.styleFrom(backgroundColor: Colors.black45),
                  ),
                ],
              ),
            ),

            // Bottom Shutter Controls
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Switch Camera
                  if (_cameraService.hasMultipleCameras)
                    IconButton(
                      onPressed: _handleCameraSwitch,
                      icon: const Icon(Icons.cameraswitch_rounded, color: Colors.white, size: 28),
                      style: IconButton.styleFrom(backgroundColor: Colors.white24, padding: const EdgeInsets.all(12)),
                    )
                  else
                    const SizedBox(width: 52),

                  // Shutter Button
                  GestureDetector(
                    onTap: _isCapturing ? null : _takePhoto,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                        color: Colors.transparent,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isCapturing ? const Color(0xFFDC2626) : Colors.white,
                        ),
                        child: _isCapturing
                            ? const Center(
                                child: SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),

                  // Spacer to balance
                  const SizedBox(width: 52),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
