import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_formatter.dart';
import '../../../data/models/task_model.dart';
import '../../../services/task_service.dart';
import '../../../models/submission_model.dart';
import '../../../state/app_state.dart';
import '../../../state/farmer_app_state.dart';
import '../../widgets/farm_graphics.dart';
import '../../widgets/farmer_avatar_badge.dart';
import '../../../state/app_appearance.dart';
import '../../widgets/task_card.dart';
import '../../widgets/completed_task_card.dart';
import '../../widgets/farmer_bottom_nav_bar.dart';


class FarmerDashboardScreen extends ConsumerStatefulWidget {
  const FarmerDashboardScreen({super.key});

  @override
  ConsumerState<FarmerDashboardScreen> createState() => _FarmerDashboardScreenState();
}

class _FarmerDashboardScreenState extends ConsumerState<FarmerDashboardScreen>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  bool _isSyncing = false;
  Set<String> _knownTaskIds = {};
  bool _isInitialSyncDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncTasks(isInitial: true);
      _startPolling();

      final syncState = ref.read(offlineSyncProvider);
      if (syncState.isOnline && syncState.pendingCount > 0 && !syncState.isSyncing) {
        ref.read(offlineSyncProvider.notifier).syncNow();
      }
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) {
        _syncTasks();
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App resumed from background/lockscreen -> refresh immediately and resume polling
      _syncTasks();
      _startPolling();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Screen locked or app minimized -> pause polling to prevent server overload
      _pollTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _syncTasks({bool isInitial = false}) async {
    if (_isSyncing || !mounted) return;
    _isSyncing = true;

    try {
      final prevTasks = ref.read(taskListProvider).asData?.value ?? [];
      if (_knownTaskIds.isEmpty && prevTasks.isNotEmpty) {
        _knownTaskIds = prevTasks.map((t) => t.id).toSet();
      }

      await Future.wait([
        ref.read(taskListProvider.notifier).refresh(),
        ref.read(farmerTasksProvider.notifier).refresh(),
        ref.read(notificationStateProvider.notifier).loadNotifications(forceRefresh: true),
      ]);

      final syncState = ref.read(offlineSyncProvider);
      if (syncState.isOnline && syncState.pendingCount > 0 && !syncState.isSyncing) {
        ref.read(offlineSyncProvider.notifier).syncNow();
      }

      if (!mounted) return;

      final updatedTasks = ref.read(taskListProvider).asData?.value ?? [];

      if (!_isInitialSyncDone && isInitial) {
        _knownTaskIds = updatedTasks.map((t) => t.id).toSet();
        _isInitialSyncDone = true;
      } else if (_knownTaskIds.isNotEmpty) {
        final currentTaskIds = updatedTasks.map((t) => t.id).toSet();
        final newTasks = updatedTasks
            .where((t) => !_knownTaskIds.contains(t.id) && t.status != TaskStatus.completed)
            .toList();
        final removedTaskIds = _knownTaskIds.difference(currentTaskIds);

        _knownTaskIds = currentTaskIds;

        if (newTasks.isNotEmpty) {
          _showNewTaskNotification(newTasks.first);
        } else if (removedTaskIds.isNotEmpty) {
          _showTaskRemovedNotification();
        }
      } else {
        _knownTaskIds = updatedTasks.map((t) => t.id).toSet();
      }
    } catch (_) {
      // Silent error during background poll
    } finally {
      if (mounted) {
        _isSyncing = false;
      }
    }
  }

  void _showNewTaskNotification(TaskModel newTask) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.assignment_turned_in_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'নতুন কাজ বরাদ্দ হয়েছে!',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    newTask.title,
                    style: const TextStyle(fontSize: 12.5, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.primaryGreen,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        action: SnackBarAction(
          label: 'দেখুন',
          textColor: Colors.white,
          onPressed: () {
            final now = DateTime.now();
            final todayStr =
                "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
            if (newTask.date.isNotEmpty && newTask.date != 'আজ' && newTask.date.compareTo(todayStr) > 0) {
              ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.upcoming);
            } else {
              ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.today);
            }

            ref.read(selectedTaskIdProvider.notifier).setTaskId(newTask.id);
            final assignments = ref.read(farmerTasksProvider).asData?.value;
            if (assignments != null && assignments.isNotEmpty) {
              try {
                final matching = assignments.firstWhere((a) => a.id.toString() == newTask.id);
                ref.read(selectedAssignmentProvider.notifier).setAssignment(matching);
              } catch (_) {}
            }
            context.push('/task-details');
          },
        ),
      ),
    );
  }

  void _showTaskRemovedNotification() {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.info_outline_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'কাজের তালিকা আপডেট হয়েছে',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'একটি কাজ বরাদ্দ প্রত্যাহার/মুছে ফেলা হয়েছে।',
                    style: TextStyle(fontSize: 12.5, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final currentDate = ref.read(dashboardSelectedDateProvider) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      helpText: 'তারিখ নির্বাচন করুন',
      cancelText: 'বাতিল',
      confirmText: 'বাছাই করুন',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primaryGreen,
              onPrimary: Colors.white,
              onSurface: AppColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      ref.read(dashboardSelectedDateProvider.notifier).setDate(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(taskListProvider);
    final user = ref.watch(currentUserProvider);
    final authState = ref.watch(farmerAuthProvider);
    final headerStyle = ref.watch(appAppearanceProvider).value?.forScreen('farmer_dashboard') ?? const HeaderStyle({});
    final currentFilter = ref.watch(taskTabFilterProvider);
    final selectedDate = ref.watch(dashboardSelectedDateProvider);
    final syncState = ref.watch(offlineSyncProvider);
    final notifications = ref.watch(notificationStateProvider);
    final unreadNotifs = notifications.where((n) => !n.isRead).length;
    ref.watch(farmerTasksProvider);

    final now = DateTime.now();
    final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final isToday = selectedDate != null &&
        selectedDate.year == now.year &&
        selectedDate.month == now.month &&
        selectedDate.day == now.day;
    final isAllTasksMode = selectedDate == null;
    final selectedDateStr = selectedDate != null
        ? "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}"
        : null;

    final String dateDisplayText;
    if (isAllTasksMode) {
      dateDisplayText = 'সকল তারিখের কাজ';
    } else {
      final baseStr = DateFormatter.formatFullDateWithDay(date: selectedDate);
      dateDisplayText = isToday ? '$baseStr (আজ)' : baseStr;
    }

    final String dynamicHeaderTitle;
    if (isAllTasksMode) {
      dynamicHeaderTitle = 'সমস্ত কাজ';
    } else if (isToday) {
      dynamicHeaderTitle = headerStyle.label('title', 'আজকের কাজ');
    } else {
      dynamicHeaderTitle = 'নির্ধারিত দিনের কাজ';
    }

    final String firstTabTitle = isAllTasksMode
        ? 'সকল কাজ'
        : (isToday ? 'আজকের' : 'ঐ দিনের');

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      body: Column(
        children: [
          // Custom Curved Green Header with Village Natural Scenario
          VillageHeaderBackground(
            height: MediaQuery.of(context).padding.top + 225,
            child: Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 14,
                left: 20,
                right: 20,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dynamicHeaderTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: headerStyle.fontSize + 4,
                            fontWeight: FontWeight.bold,
                            color: headerStyle.titleColor,
                            letterSpacing: 0.2,
                            shadows: headerStyle.shadows,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Date Navigator Row: [ < ]  তারিখ  [ > ]
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Previous Day Arrow (<)
                            InkWell(
                              onTap: () {
                                ref.read(dashboardSelectedDateProvider.notifier).previousDay();
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.22),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.chevron_left_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Date Text (tappable to open calendar picker)
                            Flexible(
                              child: InkWell(
                                onTap: () => _pickDate(context),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          dateDisplayText,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            color: Colors.white.withValues(alpha: 0.95),
                                            fontWeight: FontWeight.w600,
                                            shadows: const [
                                              Shadow(
                                                color: Colors.black38,
                                                offset: Offset(0, 1),
                                                blurRadius: 3,
                                              ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Icon(
                                        Icons.calendar_month_rounded,
                                        color: Colors.white70,
                                        size: 14,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Next Day Arrow (>)
                            InkWell(
                              onTap: () {
                                ref.read(dashboardSelectedDateProvider.notifier).nextDay();
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.22),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.chevron_right_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Mode Button: [ সমস্ত কাজ ] & [ আজকের দিন ]
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // "সমস্ত কাজ" Button
                            InkWell(
                              onTap: () {
                                if (isAllTasksMode) {
                                  ref.read(dashboardSelectedDateProvider.notifier).resetToToday();
                                } else {
                                  ref.read(dashboardSelectedDateProvider.notifier).showAllTasks();
                                }
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isAllTasksMode ? Colors.white : Colors.white.withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isAllTasksMode ? Colors.white : Colors.white.withValues(alpha: 0.35),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.list_alt_rounded,
                                      size: 13,
                                      color: isAllTasksMode ? const Color(0xFF004924) : Colors.white,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'সমস্ত কাজ',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: isAllTasksMode ? FontWeight.bold : FontWeight.w600,
                                        color: isAllTasksMode ? const Color(0xFF004924) : Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (!isToday) ...[
                              const SizedBox(width: 8),
                              // "আজকের দিন" Button (to snap back to today)
                              InkWell(
                                onTap: () {
                                  ref.read(dashboardSelectedDateProvider.notifier).resetToToday();
                                },
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.22),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.35),
                                      width: 1,
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.today_rounded,
                                        size: 13,
                                        color: Colors.white,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'আজকের দিন',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (headerStyle.label('subtitle', '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(headerStyle.label('subtitle', ''), maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: headerStyle.titleColor)),
                          ),
                      ],
                    ),
                  ),
                  // Notifications & Profile Action Buttons
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Notification Bell with Unread Count Badge -> Opens Notifications Screen
                      Stack(
                        alignment: Alignment.topRight,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.22),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.notifications_rounded,
                                color: Colors.white,
                                size: 24,
                              ),
                              tooltip: 'বিজ্ঞপ্তি',
                              onPressed: () {
                                context.push('/notifications');
                              },
                            ),
                          ),
                          if (unreadNotifs > 0)
                            Positioned(
                              top: 2,
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 1.5),
                                ),
                                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                                child: Text(
                                  '$unreadNotifs',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      // More / Profile Button
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.more_vert_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                          onPressed: () => _showOptionsDialog(context, ref),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Scrollable Body
          Expanded(
            child: RefreshIndicator(
              color: AppColors.primaryGreen,
              onRefresh: () async {
                ref.invalidate(appAppearanceProvider);
                await ref.read(farmerAuthProvider.notifier).refreshIdentity();
                await _syncTasks();
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                  // Offline Status & Sync Banner (Phase 12B Offline Support)
                  if (!syncState.isOnline || syncState.pendingCount > 0)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: syncState.isOnline ? const Color(0xFFFEF3C7) : const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFFDE68A)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            syncState.isOnline ? Icons.sync_rounded : Icons.wifi_off_rounded,
                            color: Colors.amber.shade800,
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  syncState.isOnline
                                      ? (syncState.isSyncing ? 'সার্ভারে সিঙ্ক হচ্ছে...' : '${syncState.pendingCount}টি রিপোর্ট এখনো সার্ভারে নিশ্চিত হয়নি')
                                      : 'অফলাইন মোড (ইন্টারনেট সংযোগ নেই)',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  syncState.isOnline
                                      ? (syncState.needsAttentionCount > 0 ? '${syncState.needsAttentionCount}টি রিপোর্টে মনোযোগ প্রয়োজন; ছবি ডিভাইসেই সংরক্ষিত আছে।' : 'সার্ভারের রসিদ না পাওয়া পর্যন্ত প্রমাণ ডিভাইসে থাকবে।')
                                      : 'ইন্টারনেট সংযোগ পেলে স্বয়ংক্রিয়ভাবে সার্ভারে জমা হবে।',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.amber.shade800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (syncState.needsAttentionCount > 0)
                            IconButton(
                              tooltip: 'সমস্যাযুক্ত রিপোর্ট দেখুন',
                              icon: const Icon(Icons.info_outline),
                              onPressed: () {
                                final problems = ref.read(offlineSyncServiceProvider)
                                    .getPendingSubmissions()
                                    .where((e) => e.syncStatus == SubmissionSyncStatus.needsAttention)
                                    .toList();
                                showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('যাচাই প্রয়োজন'),
                                    content: SizedBox(
                                      width: 360,
                                      child: ListView.builder(
                                        shrinkWrap: true,
                                        itemCount: problems.length,
                                        itemBuilder: (_, i) => ListTile(
                                          title: Text('কাজ #${problems[i].assignmentId}'),
                                          subtitle: Text(problems[i].errorMessage ??
                                              'প্রমাণ ডিভাইসে রাখা আছে। সহায়তা নিন।'),
                                        ),
                                      ),
                                    ),
                                    actions: [TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text('বন্ধ করুন'),
                                    )],
                                  ),
                                );
                              },
                            ),
                          if (syncState.isOnline && syncState.pendingCount > 0)
                            ElevatedButton(
                              onPressed: syncState.isSyncing
                                  ? null
                                  : () => ref.read(offlineSyncProvider.notifier).syncNow(),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryGreen,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: Size.zero,
                              ),
                              child: syncState.isSyncing
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Text(
                                      'সিঙ্ক করুন',
                                      style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                            ),
                        ],
                      ),
                    ),

                  // Greeting Card (Clickable to view Profile)
                  InkWell(
                    onTap: () => context.push('/profile'),
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF7F1),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFDCEDE0), width: 1.2),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          FarmerAvatarBadge(name: authState.profile?.fullName ?? 'কৃষক', size: 64, imageUrl: authState.profile?.profilePhotoUrl),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'শুভ সকাল,',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  '${authState.profile?.fullName ?? user?.name ?? "কৃষক"}!',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (authState.profile?.farmerCode != null && authState.profile!.farmerCode.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryGreen.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'আইডি: ${authState.profile!.farmerCode}',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.primaryGreen,
                                          ),
                                        ),
                                      ),
                                    tasksAsync.when(
                                      data: (tasks) {
                                        final int count;
                                        final String countLabel;
                                        if (isAllTasksMode) {
                                          count = tasks.where((t) {
                                            final isDone = t.status == TaskStatus.completed || t.status == TaskStatus.submitted;
                                            return !isDone;
                                          }).length;
                                          countLabel = count > 0
                                              ? 'সর্বমোট ${DateFormatter.toBanglaDigits(count)}টি কাজ বাকি আছে'
                                              : 'কোনো কাজ বাকি নেই';
                                        } else if (isToday) {
                                          count = tasks.where((t) {
                                            final isThisDate = t.date == todayStr || t.date == 'আজ';
                                            final isDone = t.status == TaskStatus.completed || t.status == TaskStatus.submitted;
                                            return isThisDate && !isDone;
                                          }).length;
                                          countLabel = count > 0
                                              ? 'আজ ${DateFormatter.toBanglaDigits(count)}টি কাজ বাকি আছে'
                                              : 'আজ কোনো কাজ বাকি নেই';
                                        } else {
                                          count = tasks.where((t) {
                                            final isThisDate = t.date == selectedDateStr;
                                            final isDone = t.status == TaskStatus.completed || t.status == TaskStatus.submitted;
                                            return isThisDate && !isDone;
                                          }).length;
                                          countLabel = count > 0
                                              ? 'ঐ দিনে ${DateFormatter.toBanglaDigits(count)}টি কাজ বাকি'
                                              : 'ঐ দিনে কোনো কাজ বাকি নেই';
                                        }

                                        return Text(
                                          countLabel,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            color: AppColors.textSecondary,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        );
                                      },
                                      loading: () => const Text(
                                        'লোড হচ্ছে...',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: AppColors.textSecondary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      error: (_, _) => Text(
                                        dynamicHeaderTitle,
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          color: AppColors.textSecondary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppColors.textSecondary),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Dashboard Tabs: Smooth Sliding Segmented Control
                  _buildSegmentedFilterTabs(
                    currentFilter: currentFilter,
                    ref: ref,
                    firstTabTitle: firstTabTitle,
                  ),

                  const SizedBox(height: 16),

                  // Tasks List
                  tasksAsync.when(
                    data: (tasks) {
                      final isSelectedDatePast = selectedDate != null && selectedDateStr!.compareTo(todayStr) < 0;
                      final isSelectedDateFuture = selectedDate != null && selectedDateStr!.compareTo(todayStr) > 0;

                      final filteredTasks = tasks.where((task) {
                        final isCompleted = task.status == TaskStatus.completed || task.status == TaskStatus.submitted;
                        final isInProgress = task.status == TaskStatus.inProgress ||
                            task.badgeText == 'চলছে' ||
                            task.badgeText == 'দেরি হয়েছে';
                        final isStartPassed = task.isStartTimePassed;

                        final bool matchesSelectedDate;
                        if (isAllTasksMode) {
                          matchesSelectedDate = true;
                        } else if (isToday) {
                          matchesSelectedDate = task.date == todayStr || task.date == 'আজ';
                        } else {
                          matchesSelectedDate = task.date == selectedDateStr;
                        }

                        // When not in All Tasks mode, only tasks belonging to the selected date are allowed
                        if (!isAllTasksMode && !matchesSelectedDate) {
                          return false;
                        }

                        if (currentFilter == TaskTabFilter.today) {
                          // All tasks for the selected date (or all tasks in All Tasks mode)
                          return true;
                        } else if (currentFilter == TaskTabFilter.inProgress) {
                          // In progress tasks
                          return isInProgress && !isCompleted;
                        } else if (currentFilter == TaskTabFilter.upcoming) {
                          // Upcoming tasks
                          if (isCompleted || isInProgress) return false;
                          if (isAllTasksMode) {
                            final isTaskToday = task.date == todayStr || task.date == 'আজ';
                            final isTaskFuture = task.date.isNotEmpty && task.date != 'আজ' && task.date.compareTo(todayStr) > 0;
                            return (isTaskToday && !isStartPassed) || isTaskFuture;
                          } else if (isToday) {
                            return !isStartPassed;
                          } else if (isSelectedDateFuture) {
                            return true;
                          } else {
                            return false;
                          }
                        } else if (currentFilter == TaskTabFilter.pending) {
                          // Incomplete / pending tasks strictly for this date
                          if (isCompleted || isInProgress) return false;
                          if (isAllTasksMode) {
                            final isTaskToday = task.date == todayStr || task.date == 'আজ';
                            final isTaskPast = task.date.isNotEmpty && task.date != 'আজ' && task.date.compareTo(todayStr) < 0;
                            final isTodayOverdue = isTaskToday && isStartPassed;
                            return isTaskPast || isTodayOverdue;
                          } else if (isToday) {
                            return isStartPassed;
                          } else if (isSelectedDatePast) {
                            return true;
                          } else {
                            return false;
                          }
                        } else {
                          // Completed tasks
                          return isCompleted;
                        }
                      }).toList();

                      // In "আজকের" / "ঐ দিনের" tab: incomplete tasks on top, completed tasks on bottom
                      if (currentFilter == TaskTabFilter.today) {
                        filteredTasks.sort((a, b) {
                          final aDone = a.status == TaskStatus.completed || a.status == TaskStatus.submitted;
                          final bDone = b.status == TaskStatus.completed || b.status == TaskStatus.submitted;
                          if (aDone != bDone) {
                            return aDone ? 1 : -1; // Incomplete first
                          }
                          return 0;
                        });
                      }

                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: KeyedSubtree(
                          key: ValueKey('${currentFilter}_${selectedDateStr ?? "all"}'),
                          child: filteredTasks.isEmpty
                              ? Container(
                                  padding: const EdgeInsets.all(32),
                                  alignment: Alignment.center,
                                  child: Column(
                                    children: [
                                      Icon(Icons.task_alt_rounded, size: 48, color: Colors.grey.shade400),
                                      const SizedBox(height: 12),
                                      Text(
                                        currentFilter == TaskTabFilter.completed
                                            ? 'এখনও কোনো কাজ সম্পন্ন হয়নি।'
                                            : (currentFilter == TaskTabFilter.inProgress
                                                ? 'বর্তমানে কোনো কাজ চলমান নেই।'
                                                : (currentFilter == TaskTabFilter.upcoming
                                                    ? 'কোনো আসন্ন কাজ নির্ধারিত নেই।'
                                                    : (currentFilter == TaskTabFilter.today
                                                        ? (isAllTasksMode
                                                            ? 'কোনো কাজ পাওয়া যায়নি।'
                                                            : (isToday
                                                                ? 'আজকের জন্য কোনো কাজ নির্ধারিত নেই।'
                                                                : 'ঐ দিনের জন্য কোনো কাজ নির্ধারিত নেই।'))
                                                        : 'কোনো বাকি কাজ নেই।'))),
                                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (currentFilter == TaskTabFilter.completed)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 12, top: 4),
                                        child: Row(
                                          children: [
                                            const Text(
                                              'সম্পন্ন কাজ',
                                              style: TextStyle(
                                                fontSize: 16.5,
                                                fontWeight: FontWeight.bold,
                                                color: AppColors.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '${DateFormatter.toBanglaDigits(filteredTasks.length)}টি কাজ',
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF64748B),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ...filteredTasks.map((task) {
                                      final isTaskDone = task.status == TaskStatus.completed || task.status == TaskStatus.submitted;
                                      if (isTaskDone) {
                                        return CompletedTaskCard(
                                          task: task,
                                          onTap: () {
                                            ref.read(selectedTaskIdProvider.notifier).setTaskId(task.id);
                                            final assignments = ref.read(farmerTasksProvider).asData?.value;
                                            if (assignments != null && assignments.isNotEmpty) {
                                              try {
                                                final matching = assignments.firstWhere((a) => a.id.toString() == task.id);
                                                ref.read(selectedAssignmentProvider.notifier).setAssignment(matching);
                                              } catch (_) {}
                                            }
                                            context.push('/task-details');
                                          },
                                        );
                                      }
                                      return TaskCard(
                                        task: task,
                                        onTap: () {
                                          ref.read(selectedTaskIdProvider.notifier).setTaskId(task.id);
                                          final assignments = ref.read(farmerTasksProvider).asData?.value;
                                          if (assignments != null && assignments.isNotEmpty) {
                                            try {
                                              final matching = assignments.firstWhere((a) => a.id.toString() == task.id);
                                              ref.read(selectedAssignmentProvider.notifier).setAssignment(matching);
                                            } catch (_) {}
                                          }
                                          context.push('/task-details');
                                        },
                                      );
                                    }),
                                  ],
                                ),
                        ),
                      );
                    },
                    loading: () => const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: CircularProgressIndicator(color: AppColors.primaryGreen),
                      ),
                    ),
                    error: (err, _) => Center(
                      child: Text('তথ্য লোড করতে সমস্যা হয়েছে: $err'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  ),
),
],
),
bottomNavigationBar: const FarmerBottomNavBar(currentIndex: 0),
);
  }

  Widget _buildSegmentedFilterTabs({
    required TaskTabFilter currentFilter,
    required WidgetRef ref,
    required String firstTabTitle,
  }) {
    final activeIndex = switch (currentFilter) {
      TaskTabFilter.today => 0,
      TaskTabFilter.inProgress => 1,
      TaskTabFilter.upcoming => 2,
      TaskTabFilter.pending => 3,
      TaskTabFilter.completed => 4,
    };

    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF2F6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / 5;
          return Stack(
            children: [
              // Single Smooth Sliding Indicator Pill
              AnimatedPositioned(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeInOutCubic,
                left: activeIndex * tabWidth,
                top: 0,
                bottom: 0,
                width: tabWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 5,
                        offset: const Offset(0, 1.5),
                      ),
                    ],
                  ),
                ),
              ),

              // Tab Item Labels
              Row(
                children: [
                  _buildTabItem(
                    title: firstTabTitle,
                    isSelected: currentFilter == TaskTabFilter.today,
                    onTap: () => ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.today),
                  ),
                  _buildTabItem(
                    title: 'চলমান কাজ',
                    isSelected: currentFilter == TaskTabFilter.inProgress,
                    onTap: () => ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.inProgress),
                  ),
                  _buildTabItem(
                    title: 'আসন্ন কাজ',
                    isSelected: currentFilter == TaskTabFilter.upcoming,
                    onTap: () => ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.upcoming),
                  ),
                  _buildTabItem(
                    title: 'বাকি কাজ',
                    isSelected: currentFilter == TaskTabFilter.pending,
                    onTap: () => ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.pending),
                  ),
                  _buildTabItem(
                    title: 'সম্পন্ন',
                    isSelected: currentFilter == TaskTabFilter.completed,
                    onTap: () => ref.read(taskTabFilterProvider.notifier).setFilter(TaskTabFilter.completed),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabItem({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: AppColors.primaryGreen.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: 11.0,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              color: isSelected ? AppColors.primaryGreen : AppColors.textSecondary,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showOptionsDialog(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'কৃষক মেনু ও সেটিংস (Farmer Menu)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.person_outline_rounded, color: AppColors.primaryGreen),
                  title: const Text('প্রোফাইল দেখুন (Profile)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.push('/profile');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_none_rounded, color: AppColors.primaryGreen),
                  title: const Text('বিজ্ঞপ্তি সমূহ (Notifications)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.push('/notifications');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.logout_rounded, color: AppColors.errorRed),
                  title: const Text('লগআউট (Logout)'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await ref.read(farmerAuthProvider.notifier).logout();
                    if (context.mounted) {
                      context.go('/login');
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
