class TaskTimeHelper {
  /// Parses a scheduled date string and time string into a local DateTime.
  /// Handles "YYYY-MM-DD", "আজ", and time formats like "08:00:00", "08:00", "14:30",
  /// or localized strings containing AM/PM or Bengali period words.
  static DateTime? parseScheduledDateTime(String? dateStr, String? timeStr) {
    if (timeStr == null || timeStr.trim().isEmpty) return null;

    final now = DateTime.now();
    int year = now.year;
    int month = now.month;
    int day = now.day;

    if (dateStr != null && dateStr.isNotEmpty && dateStr != 'আজ') {
      final dateParts = dateStr.split('-');
      if (dateParts.length == 3) {
        final y = int.tryParse(dateParts[0]);
        final m = int.tryParse(dateParts[1]);
        final d = int.tryParse(dateParts[2]);
        if (y != null && m != null && d != null) {
          year = y;
          month = m;
          day = d;
        }
      }
    }

    final normalized = _convertBanglaDigitsToEnglish(timeStr.trim());
    final timeMatch = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(normalized);
    if (timeMatch != null) {
      int hour = int.parse(timeMatch.group(1)!);
      final minute = int.parse(timeMatch.group(2)!);
      final second = timeMatch.group(3) != null ? int.parse(timeMatch.group(3)!) : 0;

      final isPm = normalized.toUpperCase().contains('PM') ||
          normalized.contains('দুপুর') ||
          normalized.contains('বিকাল') ||
          normalized.contains('সন্ধ্যা') ||
          normalized.contains('রাত');

      if (isPm && hour < 12) {
        hour += 12;
      } else if (!isPm && normalized.contains('রাত') && hour == 12) {
        hour = 0;
      }

      return DateTime(year, month, day, hour, minute, second);
    }

    return null;
  }

  /// Has the task's start time passed? (even by 1 minute)
  static bool isStartTimePassed({
    required String? date,
    required String? startTime,
    DateTime? now,
  }) {
    if (startTime == null || startTime.trim().isEmpty) return false;
    final scheduledStart = parseScheduledDateTime(date, startTime);
    if (scheduledStart == null) return false;

    final currentTime = now ?? DateTime.now();
    return currentTime.isAfter(scheduledStart);
  }

  /// Has the task's end time passed? (deadline passed)
  static bool isEndTimePassed({
    required String? date,
    required String? endTime,
    DateTime? now,
  }) {
    if (endTime == null || endTime.trim().isEmpty) return false;
    final scheduledEnd = parseScheduledDateTime(date, endTime);
    if (scheduledEnd == null) return false;

    final currentTime = now ?? DateTime.now();
    return currentTime.isAfter(scheduledEnd);
  }

  /// Evaluates whether a completed/submitted task was completed late:
  /// Late if started after start_time OR completed after end_time.
  static bool isTaskLate({
    required String? date,
    required String? startTime,
    required String? endTime,
    required String? startedAt,
    required String? completedAt,
    bool? existingIsLate,
  }) {
    if (existingIsLate == true) return true;

    final scheduledStart = parseScheduledDateTime(date, startTime);
    final scheduledEnd = parseScheduledDateTime(date, endTime);

    if (startedAt != null && scheduledStart != null) {
      final start = DateTime.tryParse(startedAt);
      if (start != null && start.isAfter(scheduledStart)) {
        return true;
      }
    }

    if (completedAt != null && scheduledEnd != null) {
      final end = DateTime.tryParse(completedAt);
      if (end != null && end.isAfter(scheduledEnd)) {
        return true;
      }
    }

    return false;
  }

  static String _convertBanglaDigitsToEnglish(String input) {
    const bangla = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];
    const english = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    var result = input;
    for (int i = 0; i < bangla.length; i++) {
      result = result.replaceAll(bangla[i], english[i]);
    }
    return result;
  }
}
