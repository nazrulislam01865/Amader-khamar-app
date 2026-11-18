import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bashir_agro_app_2/core/storage/local_storage_service.dart';
import 'package:bashir_agro_app_2/core/storage/secure_token_store.dart';
import 'package:bashir_agro_app_2/core/utils/task_time_helper.dart';
import 'package:bashir_agro_app_2/presentation/screens/dashboard/farmer_dashboard_screen.dart';
import 'package:bashir_agro_app_2/presentation/widgets/completed_task_card.dart';
import 'package:bashir_agro_app_2/presentation/widgets/task_card.dart';
import 'package:bashir_agro_app_2/services/task_service.dart';
import 'package:bashir_agro_app_2/data/models/task_model.dart';
import 'package:bashir_agro_app_2/data/repositories/task_repository.dart';
import 'package:bashir_agro_app_2/models/task_assignment_model.dart';
import 'package:bashir_agro_app_2/state/app_state.dart';

class FakeTaskRepository extends MockTaskRepository {
  final List<TaskModel> initialTasks;
  FakeTaskRepository(this.initialTasks);

  @override
  Future<List<TaskModel>> getTodayTasks() async {
    return initialTasks;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LocalStorageService.instance.setSecureStoreForTest(MemorySecureTokenStore());
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService.instance.init();
    await LocalStorageService.instance.resetForTest();
  });

  tearDown(() async {
    await LocalStorageService.instance.resetForTest();
  });

  group('TaskTimeHelper Tests', () {
    test('1. Correctly determines if start_time has passed by even 1 minute', () {
      final now = DateTime(2026, 10, 25, 8, 1); // 08:01 AM

      // Task scheduled for 08:00 AM -> start time HAS passed
      final isOverdue = TaskTimeHelper.isStartTimePassed(
        date: '2026-10-25',
        startTime: '08:00:00',
        now: now,
      );
      expect(isOverdue, isTrue);

      // Task scheduled for 08:02 AM -> start time has NOT passed
      final isUpcoming = TaskTimeHelper.isStartTimePassed(
        date: '2026-10-25',
        startTime: '08:02:00',
        now: now,
      );
      expect(isUpcoming, isFalse);
    });

    test('2. Evaluates task as late if started after start_time or finished after end_time', () {
      // Started 1 minute late
      final lateStart = TaskTimeHelper.isTaskLate(
        date: '2026-10-25',
        startTime: '08:00:00',
        endTime: '10:00:00',
        startedAt: '2026-10-25T08:01:00',
        completedAt: '2026-10-25T09:30:00',
      );
      expect(lateStart, isTrue);

      // Started on time but finished 1 minute late
      final lateFinish = TaskTimeHelper.isTaskLate(
        date: '2026-10-25',
        startTime: '08:00:00',
        endTime: '10:00:00',
        startedAt: '2026-10-25T08:00:00',
        completedAt: '2026-10-25T10:01:00',
      );
      expect(lateFinish, isTrue);

      // Started and finished completely on time
      final onTime = TaskTimeHelper.isTaskLate(
        date: '2026-10-25',
        startTime: '08:00:00',
        endTime: '10:00:00',
        startedAt: '2026-10-25T07:59:00',
        completedAt: '2026-10-25T09:59:00',
      );
      expect(onTime, isFalse);
    });
  });

  group('TaskService 5-Tab Filtering Tests', () {
    test('3. Upcoming tasks only include today incomplete tasks before start_time', () {
      final taskService = TaskService();
      final now = DateTime.now();
      final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      // Future time today
      final futureHour = (now.hour + 2) % 24;
      final futureTime = "${futureHour.toString().padLeft(2, '0')}:00:00";

      // Past time today
      final pastHour = now.hour > 0 ? now.hour - 1 : 0;
      final pastTime = "${pastHour.toString().padLeft(2, '0')}:00:00";

      final assignments = [
        TaskAssignmentModel(
          id: 1,
          scheduledDate: todayStr,
          startTime: futureTime,
          status: 'assigned',
        ),
        TaskAssignmentModel(
          id: 2,
          scheduledDate: todayStr,
          startTime: pastTime,
          status: 'assigned',
        ),
      ];

      final upcoming = taskService.filterUpcomingTasks(assignments);
      if (futureHour > now.hour) {
        expect(upcoming.length, equals(1));
        expect(upcoming.first.id, equals(1));
      }

      final pending = taskService.filterPendingTasks(assignments);
      if (now.hour > 0) {
        expect(pending.any((t) => t.id == 2), isTrue);
      }
    });
  });

  group('Farmer Dashboard Screen UI & Tab Lifecycle Tests', () {
    testWidgets('4. Dashboard displays 5 tabs, separates incomplete/completed in Today, and sorts incomplete first', (tester) async {
      await tester.binding.setSurfaceSize(const Size(450, 1000));

      final now = DateTime.now();
      final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      final mockTasks = [
        // 1. Completed task for today
        TaskModel(
          id: '1',
          title: 'পুকুরে খাবার',
          subTitle: 'মাছ চাষ',
          ownerId: '1',
          ownerName: 'মালিক',
          farmName: 'ফার্ম ১',
          locationId: 'loc1',
          locationName: 'পশ্চিম পুকুর',
          fullAddress: 'ঢাকা',
          timeRange: 'সকাল ৮:০০ – সকাল ৯:০০',
          startTime: '08:00:00',
          endTime: '09:00:00',
          date: todayStr,
          description: 'মাছের খাবার দেওয়া হয়েছে',
          instructions: '',
          status: TaskStatus.completed,
          badgeText: 'সম্পন্ন',
          thumbnailType: 'fish',
          isLate: false,
          geofencePassed: true,
          submittedAt: 'সকাল ৯:১৫',
        ),
        // 2. Upcoming incomplete task (in the future)
        TaskModel(
          id: '2',
          title: 'ফসল পর্যবেক্ষণ',
          subTitle: 'মিশ্র কৃষি',
          ownerId: '1',
          ownerName: 'মালিক',
          farmName: 'ফার্ম ১',
          locationId: 'loc2',
          locationName: 'উত্তর মাঠ',
          fullAddress: 'ঢাকা',
          timeRange: 'রাত ১১:৫৯ – রাত ১২:৩০',
          startTime: '23:59:00',
          endTime: '23:59:59',
          date: todayStr,
          description: 'ফসল দেখতে হবে',
          instructions: '',
          status: TaskStatus.scheduled,
          badgeText: 'আজ করব',
          thumbnailType: 'vegetable',
        ),
        // 3. Ongoing in-progress task
        TaskModel(
          id: '3',
          title: 'ধান রোপণ',
          subTitle: 'কৃষি কাজ',
          ownerId: '1',
          ownerName: 'মালিক',
          farmName: 'ফার্ম ১',
          locationId: 'loc3',
          locationName: 'দক্ষিণ মাঠ',
          fullAddress: 'ঢাকা',
          timeRange: 'সকাল ১০:০০ – দুপুর ১২:০০',
          startTime: '10:00:00',
          endTime: '12:00:00',
          date: todayStr,
          description: 'রোপণ চলছে',
          instructions: '',
          status: TaskStatus.inProgress,
          badgeText: 'চলছে',
          thumbnailType: 'vegetable',
        ),
        // 4. Overdue pending task (start time 00:01 in the past)
        TaskModel(
          id: '4',
          title: 'সার প্রয়োগ',
          subTitle: 'সবজি চাষ',
          ownerId: '1',
          ownerName: 'মালিক',
          farmName: 'ফার্ম ১',
          locationId: 'loc4',
          locationName: 'পূর্ব মাঠ',
          fullAddress: 'ঢাকা',
          timeRange: 'রাত ১২:০১ – রাত ০১:০০',
          startTime: '00:01:00',
          endTime: '01:00:00',
          date: todayStr,
          description: 'সার দেওয়া হয়নি',
          instructions: '',
          status: TaskStatus.scheduled,
          badgeText: 'বাকি আছে',
          thumbnailType: 'fertilizer',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(FakeTaskRepository(mockTasks)),
          ],
          child: const MaterialApp(
            home: FarmerDashboardScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 1. Check all 5 tabs exist
      expect(find.text('আজকের'), findsOneWidget);
      expect(find.text('চলমান কাজ'), findsOneWidget);
      expect(find.text('আসন্ন কাজ'), findsOneWidget);
      expect(find.text('বাকি কাজ'), findsOneWidget);
      expect(find.text('সম্পন্ন').first, findsOneWidget);

      // 2. In "আজকের" tab:
      // It should display both TaskCard and CompletedTaskCard!
      expect(find.byType(CompletedTaskCard), findsOneWidget); // পুকুরে খাবার
      expect(find.byType(TaskCard), findsNWidgets(3)); // फसल, धान, সার

      // Verify incomplete task card appears before completed card in widget tree
      final taskCardTop = tester.getTopLeft(find.byType(TaskCard).first).dy;
      final completedCardTop = tester.getTopLeft(find.byType(CompletedTaskCard).first).dy;
      expect(taskCardTop, lessThan(completedCardTop));

      // 3. Tap on "চলমান কাজ" -> should only show 'ধান রোপণ'
      await tester.tap(find.text('চলমান কাজ'));
      await tester.pumpAndSettle();
      expect(find.text('ধান রোপণ'), findsOneWidget);
      expect(find.text('পুকুরে খাবার'), findsNothing);

      // 4. Tap on "আসন্ন কাজ" -> should only show upcoming 'ফসল পর্যবেক্ষণ'
      await tester.tap(find.text('আসন্ন কাজ'));
      await tester.pumpAndSettle();
      expect(find.text('ফসল পর্যবেক্ষণ'), findsOneWidget);
      expect(find.text('সার প্রয়োগ'), findsNothing); // Overdue task is not here!

      // 5. Tap on "বাকি কাজ" -> should show overdue 'সার প্রয়োগ'
      await tester.tap(find.text('বাকি কাজ'));
      await tester.pumpAndSettle();
      expect(find.text('সার প্রয়োগ'), findsOneWidget);
      expect(find.text('ফসল পর্যবেক্ষণ'), findsNothing);

      // 6. Tap on "সম্পন্ন" tab -> should show completed 'পুকুরে খাবার' using CompletedTaskCard
      await tester.tap(find.text('সম্পন্ন').first);
      await tester.pumpAndSettle();
      expect(find.byType(CompletedTaskCard), findsOneWidget);
      expect(find.text('পুকুরে খাবার'), findsOneWidget);
    });
  });
}
