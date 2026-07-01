/// Model untuk data push-up tracker yang diterima dari server via WebSocket.
class PushUpData {
  final int timestamp;
  final int repCount;
  final String postureStatus;
  final List<String> postureIssues;
  final String movementStatus;
  final List<String> movementIssues;
  final double? elbowAngle;
  final double? hipDeviation;
  final bool pushupReady;
  final bool esp32Connected;
  final bool cameraConnected;

  // Session data
  final bool sessionActive;
  final int targetReps;
  final List<RepRecord> repHistory;

  PushUpData({
    required this.timestamp,
    required this.repCount,
    required this.postureStatus,
    required this.postureIssues,
    required this.movementStatus,
    required this.movementIssues,
    this.elbowAngle,
    this.hipDeviation,
    required this.pushupReady,
    required this.esp32Connected,
    required this.cameraConnected,
    required this.sessionActive,
    required this.targetReps,
    required this.repHistory,
  });

  factory PushUpData.fromJson(Map<String, dynamic> json) {
    final connection = json['connection'] as Map<String, dynamic>? ?? {};
    final session = json['session'] as Map<String, dynamic>? ?? {};
    final rawHistory = session['rep_history'] as List? ?? [];

    return PushUpData(
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      repCount: (json['rep_count'] as num?)?.toInt() ?? 0,
      postureStatus: (json['posture_status'] as String?) ?? 'unknown',
      postureIssues: _toStringList(json['posture_issues']),
      movementStatus: (json['movement_status'] as String?) ?? 'unknown',
      movementIssues: _toStringList(json['movement_issues']),
      elbowAngle: (json['elbow_angle'] as num?)?.toDouble(),
      hipDeviation: (json['hip_deviation'] as num?)?.toDouble(),
      pushupReady: (json['pushup_ready'] as bool?) ?? false,
      esp32Connected: (connection['esp32'] as bool?) ?? false,
      cameraConnected: (connection['camera'] as bool?) ?? false,
      sessionActive: (session['active'] as bool?) ?? false,
      targetReps: (session['target_reps'] as num?)?.toInt() ?? 0,
      repHistory: rawHistory
          .map((e) => RepRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  PushUpData copyWith({
    int? timestamp,
    int? repCount,
    String? postureStatus,
    List<String>? postureIssues,
    String? movementStatus,
    List<String>? movementIssues,
    double? elbowAngle,
    double? hipDeviation,
    bool? pushupReady,
    bool? esp32Connected,
    bool? cameraConnected,
    bool? sessionActive,
    int? targetReps,
    List<RepRecord>? repHistory,
  }) {
    return PushUpData(
      timestamp: timestamp ?? this.timestamp,
      repCount: repCount ?? this.repCount,
      postureStatus: postureStatus ?? this.postureStatus,
      postureIssues: postureIssues ?? this.postureIssues,
      movementStatus: movementStatus ?? this.movementStatus,
      movementIssues: movementIssues ?? this.movementIssues,
      elbowAngle: elbowAngle ?? this.elbowAngle,
      hipDeviation: hipDeviation ?? this.hipDeviation,
      pushupReady: pushupReady ?? this.pushupReady,
      esp32Connected: esp32Connected ?? this.esp32Connected,
      cameraConnected: cameraConnected ?? this.cameraConnected,
      sessionActive: sessionActive ?? this.sessionActive,
      targetReps: targetReps ?? this.targetReps,
      repHistory: repHistory ?? this.repHistory,
    );
  }

  static List<String> _toStringList(dynamic value) {
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return [];
  }

  /// Status keseluruhan: good hanya jika keduanya good, bad jika salah satu bad.
  String get overallStatus {
    if (postureStatus == 'bad' || movementStatus == 'bad') return 'bad';
    if (postureStatus == 'good' && movementStatus == 'good') return 'good';
    return 'unknown';
  }

  /// Gabungan semua issue dari posture + movement.
  List<String> get allIssues => [...postureIssues, ...movementIssues];
}

/// Record kualitas satu repetisi push-up.
class RepRecord {
  final int repNumber;
  final String quality; // "perfect" atau "imperfect"
  final List<String> issues;
  final double? elbowAngle;
  final double? hipDeviation;
  final double? gyroMagnitude;
  final double? accelJitter;
  final int timestamp;
  final List<Map<String, dynamic>> seriesData;

  RepRecord({
    required this.repNumber,
    required this.quality,
    required this.issues,
    this.elbowAngle,
    this.hipDeviation,
    this.gyroMagnitude,
    this.accelJitter,
    required this.timestamp,
    this.seriesData = const [],
  });

  bool get isPerfect => quality == 'perfect';

  factory RepRecord.fromJson(Map<String, dynamic> json) {
    return RepRecord(
      repNumber: (json['rep_number'] as num?)?.toInt() ?? 0,
      quality: (json['quality'] as String?) ?? 'unknown',
      issues: (json['issues'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      elbowAngle: (json['elbow_angle'] as num?)?.toDouble(),
      hipDeviation: (json['hip_deviation'] as num?)?.toDouble(),
      gyroMagnitude: (json['gyro_magnitude'] as num?)?.toDouble(),
      accelJitter: (json['accel_jitter'] as num?)?.toDouble(),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      seriesData: (json['series_data'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'rep_number': repNumber,
        'quality': quality,
        'issues': issues,
        'elbow_angle': elbowAngle,
        'hip_deviation': hipDeviation,
        'gyro_magnitude': gyroMagnitude,
        'accel_jitter': accelJitter,
        'timestamp': timestamp,
        'series_data': seriesData,
      };
}
