import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/push_up_data.dart';
import '../models/session_summary.dart';
import '../services/prefs_service.dart';
import '../services/websocket_service.dart';
import 'settings_screen.dart';
import 'history_screen.dart';

/// Layar utama — monitor push-up realtime.
class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with SingleTickerProviderStateMixin {
  final WebSocketService _ws = WebSocketService();

  PushUpData? _latestData;
  ConnectionStatus _connStatus = ConnectionStatus.disconnected;
  StreamSubscription? _dataSub;
  StreamSubscription? _statusSub;

  // Untuk session tracking
  DateTime? _sessionStart;
  int _maxRepSeen = 0;
  int _totalIssuesSeen = 0;

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

    _dataSub = _ws.dataStream.listen(_onData);
    _statusSub = _ws.statusStream.listen((s) {
      setState(() => _connStatus = s);
    });

    _initConnection();
  }

  Future<void> _initConnection() async {
    final ip = await PrefsService.getServerIp();
    final port = await PrefsService.getServerPort();
    _ws.setServer(ip, port);
    _ws.connect();
  }

  void _onData(PushUpData data) {
    // Session tracking
    _sessionStart ??= DateTime.now();
    if (data.repCount > _maxRepSeen) _maxRepSeen = data.repCount;
    _totalIssuesSeen += data.allIssues.length;

    // Pulse animation saat rep baru
    if (data.repCount > _prevRep) {
      _pulseController.forward(from: 0);
      _prevRep = data.repCount;
    }

    setState(() => _latestData = data);
  }

  Future<void> _saveSession() async {
    if (_sessionStart != null && _maxRepSeen > 0) {
      await PrefsService.addSession(SessionSummary(
        startTime: _sessionStart!,
        endTime: DateTime.now(),
        totalReps: _maxRepSeen,
        totalIssues: _totalIssuesSeen,
      ));
    }
    // Reset
    _sessionStart = null;
    _maxRepSeen = 0;
    _totalIssuesSeen = 0;
    _prevRep = 0;
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _statusSub?.cancel();
    _pulseController.dispose();
    _ws.dispose();
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
            .withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color:
              (connected ? const Color(0xFF00E676) : const Color(0xFFFF5252))
                  .withValues(alpha: 0.4),
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

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Push-up Tracker',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded, color: Colors.white70),
            tooltip: 'Riwayat',
            onPressed: () async {
              final nav = Navigator.of(context);
              await _saveSession();
              if (!mounted) return;
              nav.push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, color: Colors.white70),
            tooltip: 'Pengaturan',
            onPressed: () async {
              final nav = Navigator.of(context);
              final result = await nav.push<bool>(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(wsService: _ws),
                ),
              );
              if (result == true) {
                // Reconnect dengan IP/port baru
                _ws.disconnect();
                await _initConnection();
              }
            },
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
              const SizedBox(height: 20),

              // ── Rep count (hero) ──
              _buildRepCounter(data, statusCol),
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
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopStatusBar() {
    String label;
    Color color;
    IconData icon;

    switch (_connStatus) {
      case ConnectionStatus.connected:
        label = 'Terhubung ke server';
        color = const Color(0xFF00E676);
        icon = Icons.wifi_rounded;
      case ConnectionStatus.connecting:
        label = 'Menghubungkan...';
        color = const Color(0xFFFFD740);
        icon = Icons.wifi_find_rounded;
      case ConnectionStatus.disconnected:
        label = 'Tidak terhubung';
        color = const Color(0xFFFF5252);
        icon = Icons.wifi_off_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
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

  Widget _buildRepCounter(PushUpData? data, Color accentColor) {
    final reps = data?.repCount ?? 0;
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
              accentColor.withValues(alpha: 0.2),
              accentColor.withValues(alpha: 0.05),
              Colors.transparent,
            ],
          ),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.5),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.3),
              blurRadius: 40,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$reps',
              style: GoogleFonts.inter(
                fontSize: 72,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'REPS',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white54,
                letterSpacing: 3,
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
        color: statusCol.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusCol.withValues(alpha: 0.35)),
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
            color: const Color(0xFFFF5252).withValues(alpha: 0.25)),
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
                      const Color(0xFFFF5252).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFFFF5252)
                          .withValues(alpha: 0.2)),
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
            'Rep (IMU)',
            '${data.repCountImu}',
            Icons.memory_rounded,
          ),
          const Divider(color: Colors.white10, height: 20),
          _detailRow(
            'Sudut Siku',
            data.elbowAngle != null ? '${data.elbowAngle!.toStringAsFixed(1)}°' : '—',
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
}
