import '../core/constants/api_constants.dart';
import '../core/storage/local_storage_service.dart';
import '../core/utils/task_time_helper.dart';
import '../models/task_assignment_model.dart';
import 'api_service.dart';

enum TaskTabFilter {
  today,
  inProgress,
  upcoming,
  pending,
  completed,
}

class TaskService {
  final ApiService _apiService;
  final LocalStorageService _storage;

  TaskService({ApiService? apiService, LocalStorageService? storage})
      : _apiService = apiService ?? ApiService(),
        _storage = storage ?? LocalStorageService.instance;

  Future<List<TaskAssignmentModel>>? _inFlightFetch;

  /// Fetch assignments from API or fallback to local cache (with in-flight deduplication)
  Future<List<TaskAssignmentModel>> fetchAssignments({bool forceRefresh = false}) async {
    if (_inFlightFetch != null) {
      return _inFlightFetch!;
    }

    _inFlightFetch = _executeFetchAssignments();
    try {
      return await _inFlightFetch!;
    } finally {
      _inFlightFetch = null;
    }
  }

  Future<List<TaskAssignmentModel>> _executeFetchAssignments() async {
    try {
      final assignments = await _apiService.getAssignments();

      // Save to local cache
      final jsonList = assignments.map((a) => a.toJson()).toList();
      await _storage.setJson(ApiConstants.cachedTasksKey, jsonList);

      return assignments;
    } catch (e) {
      // Network failure -> load from offline cache
      final cached = getCachedAssignments();
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  /// Read cached assignments
  List<TaskAssignmentModel> getCachedAssignments() {
    final cached = _storage.getJson(ApiConstants.cachedTasksKey);
    if (cached is List) {
      return cached
          .map((item) => TaskAssignmentModel.fromJson(item as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Get today's tasks (all tasks scheduled for today, whether completed or in-progress)
  List<TaskAssignmentModel> filterTodayTasks(
    List<TaskAssignmentModel> allTasks, {
    DateTime? selectedDate,
  }) {
    final now = DateTime.now();
    final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final targetStr = selectedDate != null
        ? "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}"
        : todayStr;

    return allTasks.where((task) {
      if (selectedDate != null && targetStr != todayStr) {
        return task.scheduledDate == targetStr;
      }
      return task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ';
    }).toList();
  }

  /// Get ongoing / in-progress tasks (tasks that have been started and not yet completed)
  List<TaskAssignmentModel> filterInProgressTasks(
    List<TaskAssignmentModel> allTasks, {
    DateTime? selectedDate,
  }) {
    final targetStr = selectedDate != null
        ? "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}"
        : null;

    return allTasks.where((task) {
      if (selectedDate != null && targetStr != null) {
        final now = DateTime.now();
        final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
        final matches = (targetStr == todayStr)
            ? (task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ')
            : (task.scheduledDate == targetStr);
        if (!matches) return false;
      }
      return task.isInProgress && !task.isCompleted;
    }).toList();
  }

  /// Get upcoming tasks (tasks that have not started and whose start_time has not passed)
  List<TaskAssignmentModel> filterUpcomingTasks(
    List<TaskAssignmentModel> allTasks, {
    DateTime? selectedDate,
  }) {
    final now = DateTime.now();
    final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final targetStr = selectedDate != null
        ? "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}"
        : null;

    return allTasks.where((task) {
      if (task.isCompleted || task.isInProgress) return false;

      if (selectedDate != null && targetStr != null) {
        final matches = (targetStr == todayStr)
            ? (task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ')
            : (task.scheduledDate == targetStr);
        if (!matches) return false;

        if (targetStr.compareTo(todayStr) > 0) {
          return true; // Future date tasks are upcoming
        } else if (targetStr.compareTo(todayStr) < 0) {
          return false; // Past date cannot be upcoming
        } else {
          return !TaskTimeHelper.isStartTimePassed(
            date: task.scheduledDate,
            startTime: task.startTime,
            now: now,
          );
        }
      } else {
        final isToday = task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ';
        final isFuture = task.scheduledDate.isNotEmpty &&
            task.scheduledDate != 'আজ' &&
            task.scheduledDate.compareTo(todayStr) > 0;
        if (isFuture) return true;
        if (isToday) {
          return !TaskTimeHelper.isStartTimePassed(
            date: task.scheduledDate,
            startTime: task.startTime,
            now: now,
          );
        }
        return false;
      }
    }).toList();
  }

  /// Get pending / overdue tasks:
  /// When [strictDate] is true and [selectedDate] is provided, only tasks belonging
  /// to that exact date are returned (preventing other dates from leaking in).
  List<TaskAssignmentModel> filterPendingTasks(
    List<TaskAssignmentModel> allTasks, {
    DateTime? selectedDate,
    bool strictDate = false,
  }) {
    final now = DateTime.now();
    final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final targetStr = selectedDate != null
        ? "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}"
        : null;

    return allTasks.where((task) {
      if (task.isCompleted || task.isInProgress) return false;

      if (strictDate && targetStr != null) {
        final matches = (targetStr == todayStr)
            ? (task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ')
            : (task.scheduledDate == targetStr);
        if (!matches) return false;

        if (targetStr.compareTo(todayStr) < 0) {
          return true; // Past date overdue
        } else if (targetStr == todayStr) {
          return TaskTimeHelper.isStartTimePassed(
            date: task.scheduledDate,
            startTime: task.startTime,
            now: now,
          );
        } else {
          return false; // Future date
        }
      }

      // Default / All Dates behavior
      final isPastDate = task.scheduledDate.isNotEmpty && task.scheduledDate != 'আজ' && task.scheduledDate.compareTo(todayStr) < 0;
      final isToday = task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ';
      final isTodayOverdue = isToday && TaskTimeHelper.isStartTimePassed(
        date: task.scheduledDate,
        startTime: task.startTime,
        now: now,
      );

      return isPastDate || isTodayOverdue;
    }).toList();
  }

  /// Get completed tasks
  List<TaskAssignmentModel> filterCompletedTasks(
    List<TaskAssignmentModel> allTasks, {
    DateTime? selectedDate,
  }) {
    final targetStr = selectedDate != null
        ? "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}"
        : null;

    return allTasks.where((task) {
      if (selectedDate != null && targetStr != null) {
        final now = DateTime.now();
        final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
        final matches = (targetStr == todayStr)
            ? (task.scheduledDate == todayStr || task.scheduledDate.isEmpty || task.scheduledDate == 'আজ')
            : (task.scheduledDate == targetStr);
        if (!matches) return false;
      }
      return task.isCompleted;
    }).toList();
  }

  /// Start a task
  Future<TaskAssignmentModel> startTask(int assignmentId) async {
    try {
      final updated = await _apiService.startAssignment(assignmentId);
      // Update local cache
      final cached = getCachedAssignments();
      final index = cached.indexWhere((t) => t.id == assignmentId);
      if (index != -1) {
        cached[index] = updated;
        await _storage.setJson(
          ApiConstants.cachedTasksKey,
          cached.map((e) => e.toJson()).toList(),
        );
      }
      return updated;
    } catch (_) {
      rethrow;
    }
  }
}
