import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bashir_agro_app_2/models/task_assignment_model.dart';
import 'package:bashir_agro_app_2/presentation/screens/new_task/new_task_screen.dart';
import 'package:bashir_agro_app_2/services/api_service.dart';
import 'package:bashir_agro_app_2/state/farmer_app_state.dart';

class EmptyFarmsApi extends ApiService {
  @override
  Future<List<FarmLocationDetail>> getFarms() async => [];
}

void main() {
  testWidgets('F01 empty farms API does not create selectable LOC-001 or LOC-002', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(EmptyFarmsApi())],
      child: const MaterialApp(home: NewTaskScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final picker = find.text('প্লট নির্বাচন করতে ট্যাপ করুন');
    expect(picker, findsOneWidget);
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pump();
    expect(find.text('কোনো নির্ধারিত প্লট পাওয়া যায়নি'), findsOneWidget);
    expect(find.text('LOC-001'), findsNothing);
    expect(find.text('LOC-002'), findsNothing);
    expect(find.text('আবার চেষ্টা করুন'), findsWidgets);
  });
}
