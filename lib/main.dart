import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'presentation/routes/app_router.dart';
import 'state/app_appearance.dart';
import 'state/farmer_app_state.dart';
import 'state/owner_state.dart';

import 'core/storage/local_storage_service.dart';
import 'core/storage/install_security_service.dart';
import 'services/durable_queue_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStorageService.instance.init();
  // Preserve any legacy pending evidence before installation/session cleanup.
  try {
    await DurableQueueStore.instance.initialize();
  } catch (_) {
    // A damaged journal must not be overwritten or silently reset.
    runApp(const MaterialApp(home: Scaffold(body: Center(
      child: Text('অফলাইন রিপোর্টের তথ্য পড়া যাচ্ছে না। ডেটা মুছে ফেলবেন না; সহায়তা নিন।'),
    ))));
    return;
  }
  await InstallSecurityService.instance.verifyInstallation();
  runApp(
    const ProviderScope(
      child: BashirAgroApp(),
    ),
  );
}


class BashirAgroApp extends ConsumerStatefulWidget {
  const BashirAgroApp({super.key});

  @override
  ConsumerState<BashirAgroApp> createState() => _BashirAgroAppState();
}

class _BashirAgroAppState extends ConsumerState<BashirAgroApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(appAppearanceProvider);
      final authState = ref.read(farmerAuthProvider);
      if (authState.isAuthenticated) {
        if (authState.user?.isOwner == true) {
          ref.invalidate(ownerFarmersListProvider);
        }
        ref.read(farmerAuthProvider.notifier).refreshIdentity();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'আমাদের খামার - Bashir Agro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: appRouter,
    );
  }
}
