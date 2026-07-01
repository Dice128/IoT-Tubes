import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/push_up_data.dart';
import '../services/websocket_service.dart';
import '../services/mqtt_service.dart';
import '../utils/imu_calculator.dart';
import 'recap_screen.dart';

/// Layar monitor push-up realtime — bagian dari session flow.
///
/// Menerima [wsService] dan [targetReps] dari SetupScreen.
/// Otomatis pindah ke RecapScreen saat reps mencapai target.
class MonitorScreen extends StatefulWidget {
  final WebSocketService wsService;
  final MqttService mqttService;
  final int targetReps;

  const MonitorScreen({
    super.key,
    required this.wsService,
    required this.mqttService,
    required this.targetReps,
  });

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with SingleTickerProviderStateMixin {
  WebSocketService get _ws => widget.wsService;
  MqttService get _mqtt => widget.mqttService;

  PushUpData? _latestData;
  ConnectionStatus _connStatus = ConnectionStatus.disconnected;
  MqttAppConnectionState _mqttStatus = MqttAppConnectionState.disconnected;
  
  StreamSubscription? _dataSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _mqttDataSub;
  StreamSubscription? _mqttStatusSub;

  final ImuCalculator _imuCalc = ImuCalculator();

  // Session tracking
  final DateTime _sessionStart = DateTime.now();
  bool _sessionEnded = false;
  
  // Local Session History
  final List<RepRecord> _localRepHistory = [];
  List<Map<String, dynamic>> _currentSeriesData = [];

  // Animasi pulse untuk rep count
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  int _prevRep = 0;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );
    _pulseController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _pulseController.reverse();
      }
    });

    _dataSub = _ws.dataStream.listen(_onWsData);
    _statusSub = _ws.statusStream.listen((s) {
      setState(() => _connStatus = s);
    });

    _mqttDataSub = _mqtt.dataStream.listen(_onMqttData);
    _mqttStatusSub = _mqtt.statusStream.listen((s) {
      setState(() => _mqttStatus = s);
    });

    // Set initial connection status
    _connStatus = _ws.status;
    _mqttStatus = _mqtt.status;
  }

  void _onMqttData(Map<String, dynamic> data) {
    if (_sessionEnded) return;

    final pushupReady = _latestData?.pushupReady ?? false;
    final ts = data['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    
    _imuCalc.update(data, ts, pushupReady);

    if (_latestData != null) {
      final newData = _latestData!.copyWith(
        movementStatus: _imuCalc.movementStatus,
        movementIssues: _imuCalc.movementIssues,
        esp32Connected: true,
      );
      _updateDataAndCheckTarget(newData);
    }
  }

  void _onWsData(PushUpData data) {
    if (_sessionEnded) return;

    // Merge dengan data IMU lokal yang sedang berjalan
    // Kita TETAP menggunakan repCount dari Python (Kamera) karena lebih akurat
    final mergedData = data.copyWith(
      movementStatus: _imuCalc.movementStatus,
      movementIssues: _imuCalc.movementIssues,
      esp32Connected: _mqttStatus == MqttAppConnectionState.connected,
    );

    // Kirim sinyal ready ke ESP32
    if (mergedData.pushupReady) {
      _mqtt.publishControl({'pushup_ready': true});
    }

    _updateDataAndCheckTarget(mergedData);
  }

  void _updateDataAndCheckTarget(PushUpData data) {
    // Kumpulkan series data
    _currentSeriesData.add({
      'elbow_angle': data.elbowAngle ?? 180,
      'hip_deviation': data.hipDeviation ?? 0.0,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Sinkronisasi _prevRep jika server me-reset angka (misal session baru)
    if (data.repCount < _prevRep) {
      _prevRep = data.repCount;
    }

    // Jika ada rep baru, kita rekam ke dalam _localRepHistory!
    if (data.repCount > _prevRep) {
      final isPerfect = data.allIssues.isEmpty;
      final record = RepRecord(
        repNumber: data.repCount,
        quality: isPerfect ? 'perfect' : 'imperfect',
        issues: data.allIssues,
        elbowAngle: data.elbowAngle,
        hipDeviation: data.hipDeviation,
        gyroMagnitude: _imuCalc.lastGyro,
        accelJitter: _imuCalc.lastJitter,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        seriesData: List.from(_currentSeriesData),
      );
      _localRepHistory.add(record);
      _currentSeriesData.clear(); // reset grafik untuk rep berikutnya

      _pulseController.forward(from: 0);
      _prevRep = data.repCount;
    }

    if (data.repCount >= widget.targetReps) {
      // Sisipkan local history ke dalam payload data sebelum pindah screen
      final finalData = data.copyWith(repHistory: _localRepHistory);
      _endSession(finalData);
    }
    setState(() => _latestData = data);
  }

  void _endSession(PushUpData? data) {
    if (_sessionEnded) return;
    _sessionEnded = true;

    // Kirim perintah end ke server
    _ws.sendMessage({'action': 'end_session'});

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => RecapScreen(
          sessionStart: _sessionStart,
          targetReps: widget.targetReps,
          repHistory: _localRepHistory, // Gunakan local history yang kita bangun sendiri
        ),
      ),
    );
  }

  void _showEndEarlyDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Selesai Lebih Awal?',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'Sesi akan diakhiri dan hasilmu akan direkap.',
          style: GoogleFonts.inter(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Lanjutkan',
                style: GoogleFonts.inter(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _endSession(_latestData);
            },
            child: Text('Selesai',
                style: GoogleFonts.inter(
                    color: const Color(0xFFFF5252),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _statusSub?.cancel();
    _mqttDataSub?.cancel();
    _mqttStatusSub?.cancel();
    _pulseController.dispose();
    _ws.dispose();
    _mqtt.dispose();
    super.dispose();
  }

  // ─── UI helpers ─────────────────────────────────────────────────────

  Color _statusColor(String status) {
    switch (status) {
      case 'good':
        return const Color(0xFF00E676);
      case 'bad':
        return const Color(0xFFFF5252);
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'good':
        return Icons.check_circle_rounded;
      case 'bad':
        return Icons.error_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'good':
        return 'Form Bagus!';
      case 'bad':
        return 'Perlu Perbaikan';
      default:
        return 'Menunggu Data...';
    }
  }

  Widget _buildConnectionChip(String label, bool connected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (connected ? const Color(0xFF00E676) : const Color(0xFFFF5252))
            .withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color:
              (connected ? const Color(0xFF00E676) : const Color(0xFFFF5252))
                  .withOpacity(0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            connected ? Icons.link_rounded : Icons.link_off_rounded,
            size: 14,
            color: connected
                ? const Color(0xFF00E676)
                : const Color(0xFFFF5252),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final data = _latestData;
    final overall = data?.overallStatus ?? 'unknown';
    final statusCol = _statusColor(overall);
    final sessionReps = data?.repHistory.length ?? 0;
    final progress = widget.targetReps > 0
        ? (sessionReps / widget.targetReps).clamp(0.0, 1.0)
        : 0.0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _showEndEarlyDialog();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D1A),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.stop_rounded, color: Color(0xFFFF5252)),
            tooltip: 'Selesai Lebih Awal',
            onPressed: _showEndEarlyDialog,
          ),
          title: Text(
            'Sesi Push-up',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: Colors.white,
            ),
          ),
          actions: [
            // Target badge
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF448AFF).withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF448AFF).withOpacity(0.4),
                ),
              ),
              child: Text(
                '🎯 ${widget.targetReps} reps',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF82B1FF),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              children: [
                // ── Connection status bar ──
                _buildTopStatusBar(),
                const SizedBox(height: 16),

                // ── Progress bar ──
                _buildProgressBar(sessionReps, progress),
                const SizedBox(height: 20),

                // ── Rep count (hero) ──
                _buildRepCounter(sessionReps, statusCol),
                const SizedBox(height: 24),

                // ── Overall status badge ──
                _buildStatusBadge(overall, statusCol),
                const SizedBox(height: 24),

                // ── Issues list ──
                if (data != null && data.allIssues.isNotEmpty)
                  _buildIssuesCard(data.allIssues),

                if (data != null) ...[
                  const SizedBox(height: 20),
                  _buildDetailsCard(data),
                ],

                const SizedBox(height: 24),

                // ── Device connections ──
                _buildDeviceConnections(data),

                const SizedBox(height: 16),

                // ── End session button ──
                _buildEndButton(),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopStatusBar() {
    return Column(
      children: [
        _buildConnPill('Webcam Server', _connStatus == ConnectionStatus.connected),
        const SizedBox(height: 8),
        _buildConnPill('IMU Sensor (MQTT)', _mqttStatus == MqttAppConnectionState.connected),
      ],
    );
  }

  Widget _buildConnPill(String name, bool isConnected) {
    final color = isConnected ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final icon = isConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded;
    final label = isConnected ? 'Terhubung' : 'Terputus';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            '$name: $label',
            style: GoogleFonts.inter(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(int sessionReps, double progress) {
    final progressColor = progress >= 1.0
        ? const Color(0xFF00E676)
        : const Color(0xFF448AFF);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Progress',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white54,
              ),
            ),
            Text(
              '$sessionReps / ${widget.targetReps}',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: progressColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: Colors.white10,
            valueColor: AlwaysStoppedAnimation<Color>(progressColor),
          ),
        ),
      ],
    );
  }

  Widget _buildRepCounter(int sessionReps, Color accentColor) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, child) {
        return Transform.scale(
          scale: _pulseAnim.value,
          child: child,
        );
      },
      child: Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              accentColor.withOpacity(0.2),
              accentColor.withOpacity(0.05),
              Colors.transparent,
            ],
          ),
          border: Border.all(
            color: accentColor.withOpacity(0.5),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withOpacity(0.3),
              blurRadius: 40,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$sessionReps',
              style: GoogleFonts.inter(
                fontSize: 72,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '/ ${widget.targetReps} REPS',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white54,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String overall, Color statusCol) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        color: statusCol.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusCol.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_statusIcon(overall), color: statusCol, size: 28),
          const SizedBox(width: 12),
          Text(
            _statusLabel(overall),
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: statusCol,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIssuesCard(List<String> issues) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFFFF5252).withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFFFD740), size: 20),
              const SizedBox(width: 8),
              Text(
                'Feedback',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: issues.map((issue) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      const Color(0xFFFF5252).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFFFF5252)
                          .withOpacity(0.2)),
                ),
                child: Text(
                  issue,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFFFF8A80),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsCard(PushUpData data) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _detailRow(
            'Sudut Siku',
            data.elbowAngle != null
                ? '${data.elbowAngle!.toStringAsFixed(1)}°'
                : '—',
            Icons.rotate_right_rounded,
          ),
          const Divider(color: Colors.white10, height: 20),
          _detailRow(
            'Deviasi Pinggul',
            data.hipDeviation != null
                ? data.hipDeviation!.toStringAsFixed(3)
                : '—',
            Icons.straighten_rounded,
          ),
          const Divider(color: Colors.white10, height: 20),
          _detailRow(
            'Postur',
            data.postureStatus.toUpperCase(),
            Icons.accessibility_new_rounded,
            valueColor: _statusColor(data.postureStatus),
          ),
          const Divider(color: Colors.white10, height: 20),
          _detailRow(
            'Gerakan',
            data.movementStatus.toUpperCase(),
            Icons.speed_rounded,
            valueColor: _statusColor(data.movementStatus),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, IconData icon,
      {Color? valueColor}) {
    return Row(
      children: [
        Icon(icon, color: Colors.white30, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: Colors.white54,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: valueColor ?? Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceConnections(PushUpData? data) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildConnectionChip(
            'ESP32', data?.esp32Connected ?? false),
        const SizedBox(width: 12),
        _buildConnectionChip(
            'Kamera', data?.cameraConnected ?? false),
      ],
    );
  }

  Widget _buildEndButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _showEndEarlyDialog,
        icon: const Icon(Icons.stop_rounded, size: 20),
        label: const Text('Selesai Lebih Awal'),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF5252),
          side: const BorderSide(
            color: Color(0xFFFF5252),
            width: 1,
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          textStyle:
              GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
    );
  }
}
