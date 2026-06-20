import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/push_up_data.dart';
import '../services/prefs_service.dart';
import '../services/websocket_service.dart';
import 'monitor_screen.dart';
import 'settings_screen.dart';
import 'history_screen.dart';

/// Layar pemilihan target reps sebelum mulai sesi push-up.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen>
    with TickerProviderStateMixin {
  final WebSocketService _ws = WebSocketService();

  ConnectionStatus _connStatus = ConnectionStatus.disconnected;
  PushUpData? _latestData;
  StreamSubscription? _dataSub;
  StreamSubscription? _statusSub;

  int _selectedReps = 10;
  final _customController = TextEditingController();
  bool _isCustom = false;

  // Preset options
  static const List<int> _presets = [5, 10, 15, 20, 25, 30];

  late AnimationController _bgAnimController;

  @override
  void initState() {
    super.initState();

    _bgAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);

    _dataSub = _ws.dataStream.listen((data) {
      setState(() => _latestData = data);
    });
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

  @override
  void dispose() {
    _dataSub?.cancel();
    _statusSub?.cancel();
    _bgAnimController.dispose();
    _customController.dispose();
    _ws.dispose();
    super.dispose();
  }

  bool get _canStart =>
      _connStatus == ConnectionStatus.connected && _selectedReps > 0;

  void _startSession() {
    if (!_canStart) return;

    // Kirim perintah start ke server
    _ws.sendMessage({
      'action': 'start_session',
      'target_reps': _selectedReps,
    });

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MonitorScreen(
          wsService: _ws,
          targetReps: _selectedReps,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: () {
              Navigator.of(context).push(
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
                _ws.disconnect();
                await _initConnection();
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            children: [
              // ── Connection status ──
              _buildConnectionBar(),
              const SizedBox(height: 28),

              // ── Header ──
              _buildHeader(),
              const SizedBox(height: 32),

              // ── Target reps selector ──
              _buildSectionTitle('Pilih Target Reps'),
              const SizedBox(height: 16),
              _buildPresetGrid(),
              const SizedBox(height: 16),
              _buildCustomInput(),
              const SizedBox(height: 32),

              // ── Device status ──
              _buildSectionTitle('Status Perangkat'),
              const SizedBox(height: 12),
              _buildDeviceStatusCard(),
              const SizedBox(height: 32),

              // ── Start button ──
              _buildStartButton(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionBar() {
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

  Widget _buildHeader() {
    return AnimatedBuilder(
      animation: _bgAnimController,
      builder: (context, child) {
        final t = _bgAnimController.value;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                  const Color(0xFF1A237E),
                  const Color(0xFF0D47A1),
                  t,
                )!,
                Color.lerp(
                  const Color(0xFF283593),
                  const Color(0xFF1565C0),
                  t,
                )!,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF448AFF).withOpacity(0.2),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        );
      },
      child: Column(
        children: [
          const Icon(
            Icons.fitness_center_rounded,
            color: Colors.white70,
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            'Siap Latihan?',
            style: GoogleFonts.inter(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Pilih jumlah target push-up\nlalu mulai sesi latihanmu',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: Colors.white60,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: Colors.white70,
        ),
      ),
    );
  }

  Widget _buildPresetGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.6,
      ),
      itemCount: _presets.length,
      itemBuilder: (context, index) {
        final value = _presets[index];
        final isSelected = !_isCustom && _selectedReps == value;

        return GestureDetector(
          onTap: () {
            setState(() {
              _selectedReps = value;
              _isCustom = false;
              _customController.clear();
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF448AFF).withOpacity(0.25)
                  : const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF448AFF)
                    : Colors.white10,
                width: isSelected ? 2 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color:
                            const Color(0xFF448AFF).withOpacity(0.2),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Text(
                '$value',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: isSelected
                      ? const Color(0xFF82B1FF)
                      : Colors.white54,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCustomInput() {
    return GestureDetector(
      onTap: () {
        setState(() => _isCustom = true);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: _isCustom
              ? const Color(0xFF448AFF).withOpacity(0.15)
              : const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _isCustom
                ? const Color(0xFF448AFF)
                : Colors.white10,
            width: _isCustom ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.edit_rounded,
              color: _isCustom
                  ? const Color(0xFF82B1FF)
                  : Colors.white30,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _customController,
                keyboardType: TextInputType.number,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  hintText: 'Jumlah custom...',
                  hintStyle: GoogleFonts.inter(
                    color: Colors.white24,
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onTap: () {
                  setState(() => _isCustom = true);
                },
                onChanged: (val) {
                  final n = int.tryParse(val);
                  if (n != null && n > 0) {
                    setState(() {
                      _selectedReps = n;
                      _isCustom = true;
                    });
                  }
                },
              ),
            ),
            if (_isCustom && _selectedReps > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF448AFF).withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$_selectedReps reps',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF82B1FF),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceStatusCard() {
    final esp32 = _latestData?.esp32Connected ?? false;
    final camera = _latestData?.cameraConnected ?? false;
    final ready = _latestData?.pushupReady ?? false;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _deviceRow('ESP32 Sensor', esp32, Icons.memory_rounded),
          const SizedBox(height: 12),
          _deviceRow('Webcam', camera, Icons.videocam_rounded),
          const SizedBox(height: 12),
          _deviceRow('Posisi Push-up', ready, Icons.accessibility_new_rounded),
        ],
      ),
    );
  }

  Widget _deviceRow(String label, bool active, IconData icon) {
    final color = active ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    return Row(
      children: [
        Icon(icon, color: Colors.white30, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: Colors.white54,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                active ? 'Aktif' : 'Tidak aktif',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStartButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: _canStart
              ? const LinearGradient(
                  colors: [Color(0xFF448AFF), Color(0xFF2979FF)],
                )
              : null,
          color: _canStart ? null : Colors.white10,
          boxShadow: _canStart
              ? [
                  BoxShadow(
                    color: const Color(0xFF448AFF).withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _canStart ? _startSession : null,
            borderRadius: BorderRadius.circular(16),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.play_arrow_rounded,
                    color: _canStart ? Colors.white : Colors.white24,
                    size: 28,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _canStart
                        ? 'Mulai Push-up  ($_selectedReps reps)'
                        : 'Hubungkan ke server dulu',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: _canStart ? Colors.white : Colors.white24,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
