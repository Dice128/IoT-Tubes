import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/push_up_data.dart';
import '../models/session_summary.dart';
import '../services/prefs_service.dart';
import 'setup_screen.dart';
import 'history_screen.dart';

/// Tips perbaikan berdasarkan jenis issue.
const Map<String, String> _issueTips = {
  'Pinggul turun - tahan badan tetap lurus':
      'Kencangkan otot perut (core) dan punggung bawah. Bayangkan tubuhmu seperti papan lurus dari kepala sampai tumit.',
  'Pinggul terlalu naik - sejajarkan dengan bahu dan tumit':
      'Turunkan pinggul sedikit. Pastikan bahu, pinggul, dan tumit membentuk garis lurus.',
  'Kedalaman kurang - turunkan badan lebih rendah':
      'Turunkan dada lebih dekat ke lantai. Siku harus menekuk minimal 90° untuk rep penuh.',
  'Gerakan terlalu cepat / hentakan terdeteksi':
      'Lakukan gerakan lebih pelan dan terkontrol. Fokus pada kualitas, bukan kecepatan. Hitung 2 detik turun, 2 detik naik.',
  'Gerakan tidak stabil — coba lebih terkontrol':
      'Pastikan posisi tangan selebar bahu dan jari menghadap ke depan. Kencangkan core untuk stabilitas lebih baik.',
};

/// Layar rekap setelah sesi push-up selesai.
class RecapScreen extends StatefulWidget {
  final DateTime sessionStart;
  final int targetReps;
  final List<RepRecord> repHistory;

  const RecapScreen({
    super.key,
    required this.sessionStart,
    required this.targetReps,
    required this.repHistory,
  });

  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<RecapScreen>
    with TickerProviderStateMixin {
  late AnimationController _entryController;
  late Animation<double> _fadeAnim;
  late Animation<double> _slideAnim;
  late AnimationController _progressController;

  late int _totalReps;
  late int _perfectReps;
  late int _imperfectReps;
  late Map<String, int> _issueBreakdown;

  @override
  void initState() {
    super.initState();

    // Hitung statistik
    _totalReps = widget.repHistory.length;
    _perfectReps = widget.repHistory.where((r) => r.isPerfect).length;
    _imperfectReps = _totalReps - _perfectReps;

    _issueBreakdown = {};
    for (final rep in widget.repHistory) {
      for (final issue in rep.issues) {
        _issueBreakdown[issue] = (_issueBreakdown[issue] ?? 0) + 1;
      }
    }

    // Entry animation
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOut,
    );
    _slideAnim = Tween<double>(begin: 30, end: 0).animate(
      CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
    );

    // Progress ring animation
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _entryController.forward();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _progressController.forward();
    });

    // Simpan sesi ke riwayat
    _saveSession();
  }

  Future<void> _saveSession() async {
    await PrefsService.addSession(SessionSummary(
      startTime: widget.sessionStart,
      endTime: DateTime.now(),
      targetReps: widget.targetReps,
      totalReps: _totalReps,
      perfectReps: _perfectReps,
      imperfectReps: _imperfectReps,
      issueBreakdown: _issueBreakdown,
    ));
  }

  @override
  void dispose() {
    _entryController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final duration = DateTime.now().difference(widget.sessionStart);
    final targetReached = _totalReps >= widget.targetReps;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D1A),
        body: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: AnimatedBuilder(
              animation: _slideAnim,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _slideAnim.value),
                  child: child,
                );
              },
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  children: [
                    const SizedBox(height: 16),

                    // ── Header ──
                    _buildHeader(targetReached),
                    const SizedBox(height: 28),

                    // ── Progress ring + stats ──
                    _buildProgressSection(),
                    const SizedBox(height: 28),

                    // ── Stats cards ──
                    _buildStatsRow(duration),
                    const SizedBox(height: 24),

                    // ── Quality breakdown ──
                    _buildQualityCard(),
                    const SizedBox(height: 20),

                    // ── Per-Rep Details ──
                    if (widget.repHistory.isNotEmpty) ...[
                      _buildPerRepDetailsList(),
                      const SizedBox(height: 24),
                    ],

                    // ── Action buttons ──
                    _buildActions(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool targetReached) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: targetReached
                  ? [const Color(0xFF00E676), const Color(0xFF00C853)]
                  : [const Color(0xFFFFD740), const Color(0xFFFFAB00)],
            ),
            boxShadow: [
              BoxShadow(
                color: (targetReached
                        ? const Color(0xFF00E676)
                        : const Color(0xFFFFD740))
                    .withOpacity(0.3),
                blurRadius: 24,
              ),
            ],
          ),
          child: Icon(
            targetReached
                ? Icons.emoji_events_rounded
                : Icons.flag_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          targetReached ? 'Sesi Selesai! 🎉' : 'Sesi Berakhir',
          style: GoogleFonts.inter(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          targetReached
              ? 'Kamu berhasil mencapai target!'
              : 'Tetap semangat, terus berlatih!',
          style: GoogleFonts.inter(
            fontSize: 14,
            color: Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressSection() {
    final progress = widget.targetReps > 0
        ? (_totalReps / widget.targetReps).clamp(0.0, 1.0)
        : 0.0;

    return AnimatedBuilder(
      animation: _progressController,
      builder: (context, _) {
        final animatedProgress = progress * _progressController.value;
        return SizedBox(
          width: 180,
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 180,
                height: 180,
                child: CircularProgressIndicator(
                  value: animatedProgress,
                  strokeWidth: 10,
                  strokeCap: StrokeCap.round,
                  backgroundColor: Colors.white10,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    progress >= 1.0
                        ? const Color(0xFF00E676)
                        : const Color(0xFF448AFF),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_totalReps',
                    style: GoogleFonts.inter(
                      fontSize: 48,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    '/ ${widget.targetReps} reps',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  double _calculateRhythmScore() {
    if (_totalReps == 0) return 0;
    int rhythmIssuesCount = 0;
    for (final rep in widget.repHistory) {
      if (rep.issues.any((i) =>
          i.toLowerCase().contains('terlalu cepat') ||
          i.toLowerCase().contains('tidak stabil'))) {
        rhythmIssuesCount++;
      }
    }
    return ((_totalReps - rhythmIssuesCount) / _totalReps) * 100;
  }

  Widget _buildStatsRow(Duration duration) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _statCard('Durasi', _formatDuration(duration), Icons.timer_rounded)),
            const SizedBox(width: 12),
            Expanded(child: _statCard('Target', '${widget.targetReps}', Icons.flag_rounded)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _statCard(
                'Akurasi',
                _totalReps > 0
                    ? '${(_perfectReps / _totalReps * 100).toStringAsFixed(0)}%'
                    : '—',
                Icons.analytics_rounded,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statCard(
                'Ritme',
                _totalReps > 0
                    ? '${(_calculateRhythmScore()).toStringAsFixed(0)}%'
                    : '—',
                Icons.speed_rounded,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white24, size: 20),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Kualitas Rep',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 16),
          // Quality bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  if (_perfectReps > 0)
                    Expanded(
                      flex: _perfectReps,
                      child: Container(color: const Color(0xFF00E676)),
                    ),
                  if (_imperfectReps > 0)
                    Expanded(
                      flex: _imperfectReps,
                      child: Container(color: const Color(0xFFFFD740)),
                    ),
                  if (_totalReps == 0)
                    Expanded(child: Container(color: Colors.white10)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _qualityChip(
                '✅ Sempurna',
                '$_perfectReps',
                const Color(0xFF00E676),
              ),
              const SizedBox(width: 12),
              _qualityChip(
                '⚠️ Kurang sempurna',
                '$_imperfectReps',
                const Color(0xFFFFD740),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _qualityChip(String label, String count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              count,
              style: GoogleFonts.inter(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: color.withOpacity(0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPerRepDetailsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Detail Per Repetisi',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        ...widget.repHistory.map((rep) => _buildSingleRepCard(rep)),
      ],
    );
  }

  Widget _buildSingleRepCard(RepRecord rep) {
    final bool isPerfect = rep.isPerfect;
    final Color accentColor =
        isPerfect ? const Color(0xFF00E676) : const Color(0xFFFFD740);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Rep
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.1),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Rep #${rep.repNumber}',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: accentColor,
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      isPerfect ? Icons.check_circle_rounded : Icons.warning_rounded,
                      color: accentColor,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isPerfect ? 'Sempurna' : 'Kurang',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accentColor,
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),

          // Tips Khusus untuk rep ini (jika ada issue)
          if (!isPerfect && rep.issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tips_and_updates_rounded,
                          color: Color(0xFFFFD740), size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Feedback:',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...rep.issues.map((issue) {
                    final tip = _issueTips[issue] ??
                        'Perhatikan teknik gerakanmu untuk rep berikutnya.';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5252).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: const Color(0xFFFF5252).withOpacity(0.15)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            issue,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFFFF8A80),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tip,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),

          // Grafik (Charts)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Grafik Gerakan',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 12),
                // Sudut Siku Chart
                _buildChartContainer(
                  title: 'Sudut Siku',
                  data: rep.seriesData,
                  yKey: 'elbow_angle',
                  color: const Color(0xFF448AFF),
                  minY: 80,
                  maxY: 180,
                  idealLine: true,
                ),
                const SizedBox(height: 16),
                // Deviasi Pinggul Chart
                _buildChartContainer(
                  title: 'Deviasi Pinggul (Posture)',
                  data: rep.seriesData,
                  yKey: 'hip_deviation',
                  color: const Color(0xFFFF5252),
                  minY: -0.2,
                  maxY: 0.2,
                  idealLine: false,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legendDot(Colors.white54, 'Garis Aktual', solid: true),
                    const SizedBox(width: 16),
                    _legendDot(Colors.white24, 'Garis Sempurna', solid: false),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartContainer({
    required String title,
    required List<Map<String, dynamic>> data,
    required String yKey,
    required Color color,
    required double minY,
    required double maxY,
    required bool idealLine,
  }) {
    // Ekstrak data Y
    final List<double> points = data.map((d) {
      final val = d[yKey];
      if (val is num) return val.toDouble();
      return 0.0;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 80,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black12,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: points.isEmpty
              ? Center(
                  child: Text('Data tidak tersedia',
                      style: GoogleFonts.inter(
                          fontSize: 10, color: Colors.white24)))
              : CustomPaint(
                  painter: LineChartPainter(
                    points: points,
                    color: color,
                    minY: minY,
                    maxY: maxY,
                    drawIdealV: idealLine,
                    drawIdealZero: !idealLine,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _legendDot(Color color, String label, {required bool solid}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 2,
          color: color, // Jika butuh putus-putus, kita anggap warna pudar = putus
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            color: Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Column(
      children: [
        // Latihan Lagi
        SizedBox(
          width: double.infinity,
          height: 52,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [Color(0xFF448AFF), Color(0xFF2979FF)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF448AFF).withOpacity(0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                        builder: (_) => const SetupScreen()),
                    (route) => false,
                  );
                },
                borderRadius: BorderRadius.circular(14),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.replay_rounded,
                          color: Colors.white, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'Latihan Lagi',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Lihat Riwayat
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const SetupScreen()),
                (route) => false,
              );
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
            icon: const Icon(Icons.history_rounded),
            label: const Text('Lihat Riwayat'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: const BorderSide(color: Colors.white12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              textStyle:
                  GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }
}

/// Painter kustom untuk menggambar grafik garis sederhana (aktual vs ideal)
class LineChartPainter extends CustomPainter {
  final List<double> points;
  final Color color;
  final double minY;
  final double maxY;
  final bool drawIdealV;
  final bool drawIdealZero;

  LineChartPainter({
    required this.points,
    required this.color,
    required this.minY,
    required this.maxY,
    required this.drawIdealV,
    required this.drawIdealZero,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final actualPaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final idealPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final double range = maxY - minY;
    if (range <= 0) return;

    final double stepX = size.width / (points.length > 1 ? points.length - 1 : 1);

    // 1. Gambar Garis Ideal
    final Path idealPath = Path();
    if (drawIdealV) {
      // V-shape (180 -> 100 -> 180). Y axis di-invert karena 0 di atas
      final startY = size.height - ((180 - minY) / range) * size.height;
      final midY = size.height - ((100 - minY) / range) * size.height;
      final endY = size.height - ((180 - minY) / range) * size.height;

      idealPath.moveTo(0, startY);
      idealPath.lineTo(size.width / 2, midY);
      idealPath.lineTo(size.width, endY);
      _drawDashedPath(canvas, idealPath, idealPaint);
    } else if (drawIdealZero) {
      // Garis lurus di 0.0
      final y = size.height - ((0.0 - minY) / range) * size.height;
      idealPath.moveTo(0, y);
      idealPath.lineTo(size.width, y);
      _drawDashedPath(canvas, idealPath, idealPaint);
    }

    // 2. Gambar Garis Aktual
    final Path actualPath = Path();
    for (int i = 0; i < points.length; i++) {
      final x = i * stepX;
      // Clamp nilai agar tidak keluar kotak
      final clampedVal = points[i].clamp(minY, maxY);
      // Invert Y: nilai minY di bawah (height), maxY di atas (0)
      final y = size.height - ((clampedVal - minY) / range) * size.height;

      if (i == 0) {
        actualPath.moveTo(x, y);
      } else {
        actualPath.lineTo(x, y);
      }
    }
    canvas.drawPath(actualPath, actualPaint);
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    // Implementasi simpel garis putus-putus
    const double dashWidth = 5;
    const double dashSpace = 4;
    double distance = 0.0;
    
    for (PathMetric pathMetric in path.computeMetrics()) {
      while (distance < pathMetric.length) {
        final Path extractPath =
            pathMetric.extractPath(distance, distance + dashWidth);
        canvas.drawPath(extractPath, paint);
        distance += dashWidth + dashSpace;
      }
      distance = 0.0;
    }
  }

  @override
  bool shouldRepaint(covariant LineChartPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.color != color;
  }
}
