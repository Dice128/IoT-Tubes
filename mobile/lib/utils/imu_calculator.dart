import 'dart:math';

class ImuCalculator {
  // LPF coefficient
  final double alpha = 0.25;
  
  // Thresholds vertikal (m/s^2)
  // Thresholds Kualitas Gerakan (Jitter & Kecepatan)
  final int jitterWindowSize = 10;
  final double accelJitterLimit = 1.5;
  final double gyroSpeedLimit = 5.0; // rad/s

  // State
  final List<double> _recentAccel = [];
  String _movementStatus = 'unknown';
  List<String> _movementIssues = [];
  double _lastJitter = 0.0;
  double _lastGyro = 0.0;

  String get movementStatus => _movementStatus;
  List<String> get movementIssues => _movementIssues;
  double get lastJitter => _lastJitter;
  double get lastGyro => _lastGyro;

  // Dipanggil setiap kali mendapat data mentah dari ESP32 (MQTT)
  void update(Map<String, dynamic> sample, int timestampMs, bool pushupReady) {
    double ax = (sample['ax'] ?? 0.0).toDouble();
    double ay = (sample['ay'] ?? 0.0).toDouble();
    double az = (sample['az'] ?? 0.0).toDouble();
    double gx = (sample['gx'] ?? 0.0).toDouble();
    double gy = (sample['gy'] ?? 0.0).toDouble();
    double gz = (sample['gz'] ?? 0.0).toDouble();

    double aMag = sqrt(ax * ax + ay * ay + az * az);

    // 2. Movement Analyzer Logic (Kualitas Gerakan)
    _recentAccel.add(aMag);
    if (_recentAccel.length > jitterWindowSize) {
      _recentAccel.removeAt(0);
    }

    _movementIssues.clear();

    // Cek rotasi gyro
    double gyroMagnitude = sqrt(gx * gx + gy * gy + gz * gz);
    _lastGyro = gyroMagnitude;
    if (gyroMagnitude > gyroSpeedLimit) {
      _movementIssues.add('Gerakan terlalu cepat / hentakan terdeteksi');
    }

    // Cek jitter / ketidakstabilan
    if (_recentAccel.length >= jitterWindowSize) {
      double sum = _recentAccel.reduce((a, b) => a + b);
      double mean = sum / _recentAccel.length;
      double variance = _recentAccel.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / _recentAccel.length;
      double stdDev = sqrt(variance);
      _lastJitter = stdDev;

      if (stdDev > accelJitterLimit) {
        _movementIssues.add('Gerakan tidak stabil — coba lebih terkontrol');
      }
    } else {
      _lastJitter = 0.0;
    }

    if (_movementIssues.isEmpty) {
      _movementStatus = 'good';
    } else {
      _movementStatus = 'bad';
    }

    if (_recentAccel.length < jitterWindowSize / 2) {
      _movementStatus = 'unknown';
    }
  }

  void reset() {
    _recentAccel.clear();
    _movementStatus = 'unknown';
    _movementIssues.clear();
    _lastJitter = 0.0;
    _lastGyro = 0.0;
  }
}
