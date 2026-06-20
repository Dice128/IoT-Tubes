import 'push_up_data.dart';

/// Model ringkasan sesi untuk riwayat — diperkaya dengan data per-rep.
class SessionSummary {
  final DateTime startTime;
  final DateTime endTime;
  final int targetReps;
  final int totalReps;
  final int perfectReps;
  final int imperfectReps;
  final Map<String, int> issueBreakdown; // issue text → count
  final List<RepRecord> repHistory;

  SessionSummary({
    required this.startTime,
    required this.endTime,
    required this.targetReps,
    required this.totalReps,
    required this.perfectReps,
    required this.imperfectReps,
    required this.issueBreakdown,
    this.repHistory = const [],
  });

  Duration get duration => endTime.difference(startTime);

  /// Persentase rep sempurna (0.0 - 1.0).
  double get perfectRatio =>
      totalReps > 0 ? perfectReps / totalReps : 0.0;

  /// Apakah target tercapai.
  bool get targetReached => totalReps >= targetReps;

  Map<String, dynamic> toJson() => {
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'targetReps': targetReps,
        'totalReps': totalReps,
        'perfectReps': perfectReps,
        'imperfectReps': imperfectReps,
        'issueBreakdown': issueBreakdown,
        'repHistory': repHistory.map((e) => e.toJson()).toList(),
      };

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    return SessionSummary(
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      targetReps: (json['targetReps'] as num?)?.toInt() ?? 0,
      totalReps: (json['totalReps'] as num?)?.toInt() ?? 0,
      perfectReps: (json['perfectReps'] as num?)?.toInt() ?? 0,
      imperfectReps: (json['imperfectReps'] as num?)?.toInt() ?? 0,
      issueBreakdown: _parseIssueBreakdown(json['issueBreakdown']),
      repHistory: (json['repHistory'] as List?)
              ?.map((e) => RepRecord.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  static Map<String, int> _parseIssueBreakdown(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    }
    return {};
  }
}
