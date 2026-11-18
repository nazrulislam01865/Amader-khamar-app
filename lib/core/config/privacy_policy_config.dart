import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PrivacyPolicyConfig {
  static const url = String.fromEnvironment('PRIVACY_POLICY_URL');
  static Future<void> open(BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      _showError(context);
      return;
    }
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (context.mounted) _showError(context);
  }
  static void _showError(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('গোপনীয়তা নীতি খোলা যাচ্ছে না। অনুগ্রহ করে পরে চেষ্টা করুন।'),
    ));
  }
}
