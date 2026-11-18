import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bashir_agro_app_2/core/storage/local_storage_service.dart';
import 'package:bashir_agro_app_2/core/storage/secure_token_store.dart';
import 'package:bashir_agro_app_2/presentation/screens/dashboard/farmer_dashboard_screen.dart';
import 'package:bashir_agro_app_2/data/models/task_model.dart';
import 'package:bashir_agro_app_2/data/repositories/task_repository.dart';
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

  group('Dashboard Date Navigation & Strict "বাকি কাজ" Filtering Tests', () {
    testWidgets('Date navigation (< >), All Tasks mode toggle, and non-leaking "বাকি কাজ" tab', (tester) async {
      await tester.binding.setSurfaceSize(const Size(450, 1100));

      final now = DateTime.now();
      final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayStr = "${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}";

      final mockTasks = [
        // 1. Task today (overdue)
        TaskModel(
          id: '1',
          title: 'আজকের অসমাপ্ত কাজ',
          subTitle: 'সবজি চাষ',
          ownerId: '1',
          ownerName: 'মালিক',
          farmName: 'ফার্ম ১',
          locationId: 'loc1',
          locationName: 'উত্তর মাঠ',
          fullAddress: 'ঢাকা',
          timeRange: 'রাত ১২:০১ – রাত ০১:০০',
          startTime: '00:01:00',
          endTime: '01:00:00',
          date: todayStr,
          description: 'আজকের কাজ',
          instructions: '',
          status: TaskStatus.scheduled,
          badgeText: 'বাকি আছে',
          thumbnailType: 'vegetable',
        ),
        // 2. Task yesterday (past overdue)
        TaskModel(
          id: '2',
          title: 'গতকালের ফেলে রাখা কাজ',
          subTitle: 'ধান চাষ',
          ownerId: '1',
          ownerName: 'মালিক',
          farmName: 'ফার্ম ১',
          locationId: 'loc2',
          locationName: 'দক্ষিণ মাঠ',
          fullAddress: 'ঢাকা',
          timeRange: 'সকাল ১০:০০ – সকাল ১১:০০',
          startTime: '10:00:00',
          endTime: '11:00:00',
          date: yesterdayStr,
          description: 'গতকালের কাজ',
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

      // 1. Initial State: Today is selected
      expect(find.text('আজকের কাজ'), findsOneWidget);
      expect(find.text('আজকের'), findsOneWidget); // Tab 1 title is "আজকের"
      expect(find.text('সমস্ত কাজ'), findsOneWidget);

      // 2. Select "বাকি কাজ" tab
      await tester.tap(find.text('বাকি কাজ'));
      await tester.pumpAndSettle();

      // STRICT DATE CHECK: Only today's overdue task (id: 1) must be shown!
      // Yesterday's task (id: 2) MUST NOT leak into today's "বাকি কাজ" tab!
      expect(find.text('আজকের অসমাপ্ত কাজ'), findsOneWidget);
      expect(find.text('গতকালের ফেলে রাখা কাজ'), findsNothing);

      // 3. Navigate back 1 day using left arrow (<)
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();

      // Now yesterday is selected
      expect(find.text('নির্ধারিত দিনের কাজ'), findsOneWidget);
      expect(find.text('ঐ দিনের'), findsOneWidget); // Tab 1 title dynamically changed to "ঐ দিনের"
      expect(find.text('আজকের দিন'), findsOneWidget); // "আজকের দিন" button appeared!

      // In yesterday's "বাকি কাজ" tab: only yesterday's task (id: 2) must be shown!
      expect(find.text('গতকালের ফেলে রাখা কাজ'), findsOneWidget);
      expect(find.text('আজকের অসমাপ্ত কাজ'), findsNothing);

      // 4. Tap "সমস্ত কাজ" button
      await tester.tap(find.text('সমস্ত কাজ'));
      await tester.pumpAndSettle();

      // All Tasks mode active
      expect(find.text('সমস্ত কাজ'), findsWidgets);
      expect(find.text('সকল তারিখের কাজ'), findsOneWidget);
      expect(find.text('সকল কাজ'), findsOneWidget); // Tab 1 title changed to "সকল কাজ"

      // In "সমস্ত কাজ" mode under "বাকি কাজ": BOTH tasks from all dates appear!
      expect(find.text('আজকের অসমাপ্ত কাজ'), findsOneWidget);
      expect(find.text('গতকালের ফেলে রাখা কাজ'), findsOneWidget);

      // 5. Tap "আজকের দিন" button to snap back to today
      await tester.tap(find.text('আজকের দিন'));
      await tester.pumpAndSettle();

      // Back to Today
      expect(find.text('আজকের কাজ'), findsOneWidget);
      expect(find.text('আজকের'), findsOneWidget);
      // In today's "বাকি কাজ": only today's task again, no past task leakage!
      expect(find.text('আজকের অসমাপ্ত কাজ'), findsOneWidget);
      expect(find.text('গতকালের ফেলে রাখা কাজ'), findsNothing);
    });
  });
}
