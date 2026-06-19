/// Model ringkasan sesi untuk riwayat.
class SessionSummary {
  final DateTime startTime;
  final DateTime endTime;
  final int totalReps;
  final int totalIssues;

  SessionSummary({
    required this.startTime,
    required this.endTime,
    required this.totalReps,
    required this.totalIssues,
  });

  Duration get duration => endTime.difference(startTime);

  Map<String, dynamic> toJson() => {
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'totalReps': totalReps,
        'totalIssues': totalIssues,
      };

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    return SessionSummary(
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      totalReps: (json['totalReps'] as num?)?.toInt() ?? 0,
      totalIssues: (json['totalIssues'] as num?)?.toInt() ?? 0,
    );
  }
}
