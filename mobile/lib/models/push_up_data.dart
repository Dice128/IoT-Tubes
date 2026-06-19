/// Model untuk data push-up tracker yang diterima dari server via WebSocket.
class PushUpData {
  final int timestamp;
  final int repCount;
  final int repCountImu;
  final String postureStatus;
  final List<String> postureIssues;
  final String movementStatus;
  final List<String> movementIssues;
  final double? elbowAngle;
  final double? hipDeviation;
  final bool esp32Connected;
  final bool cameraConnected;

  PushUpData({
    required this.timestamp,
    required this.repCount,
    required this.repCountImu,
    required this.postureStatus,
    required this.postureIssues,
    required this.movementStatus,
    required this.movementIssues,
    this.elbowAngle,
    this.hipDeviation,
    required this.esp32Connected,
    required this.cameraConnected,
  });

  factory PushUpData.fromJson(Map<String, dynamic> json) {
    final connection = json['connection'] as Map<String, dynamic>? ?? {};
    return PushUpData(
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      repCount: (json['rep_count'] as num?)?.toInt() ?? 0,
      repCountImu: (json['rep_count_imu'] as num?)?.toInt() ?? 0,
      postureStatus: (json['posture_status'] as String?) ?? 'unknown',
      postureIssues: _toStringList(json['posture_issues']),
      movementStatus: (json['movement_status'] as String?) ?? 'unknown',
      movementIssues: _toStringList(json['movement_issues']),
      elbowAngle: (json['elbow_angle'] as num?)?.toDouble(),
      hipDeviation: (json['hip_deviation'] as num?)?.toDouble(),
      esp32Connected: (connection['esp32'] as bool?) ?? false,
      cameraConnected: (connection['camera'] as bool?) ?? false,
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
