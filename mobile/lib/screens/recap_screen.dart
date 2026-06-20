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

                    // ── Issues & tips ──
                    if (_issueBreakdown.isNotEmpty) ...[
                      _buildIssuesCard(),
                      const SizedBox(height: 20),
                    ],

                    // ── Rep timeline ──
                    if (widget.repHistory.isNotEmpty) ...[
                      _buildRepTimeline(),
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

  Widget _buildIssuesCard() {
    // Urutkan issues dari yang paling sering
    final sorted = _issueBreakdown.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFFF5252).withOpacity(0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_rounded,
                  color: Color(0xFFFFD740), size: 20),
              const SizedBox(width: 8),
              Text(
                'Tips Perbaikan',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...sorted.map((entry) => _issueItem(entry.key, entry.value)),
        ],
      ),
    );
  }

  Widget _issueItem(String issue, int count) {
    final tip = _issueTips[issue] ?? 'Perhatikan teknik push-up yang benar.';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF5252).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${count}x',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFFF8A80),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  issue,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF00E676).withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFF00E676).withOpacity(0.12),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.tips_and_updates_rounded,
                    color: Color(0xFF69F0AE), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tip,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: const Color(0xFF69F0AE),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRepTimeline() {
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
            'Detail Per Rep',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.repHistory.map((rep) {
              final color = rep.isPerfect
                  ? const Color(0xFF00E676)
                  : const Color(0xFFFFD740);
              return Tooltip(
                message: rep.isPerfect
                    ? 'Rep #${rep.repNumber}: Sempurna!'
                    : 'Rep #${rep.repNumber}: ${rep.issues.join(", ")}',
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color.withOpacity(0.4)),
                  ),
                  child: Center(
                    child: Text(
                      '${rep.repNumber}',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _legendDot(const Color(0xFF00E676), 'Sempurna'),
              const SizedBox(width: 16),
              _legendDot(const Color(0xFFFFD740), 'Kurang sempurna'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withOpacity(0.4),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: color, width: 1.5),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            color: Colors.white38,
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
