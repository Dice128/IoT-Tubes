import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/prefs_service.dart';
import '../services/websocket_service.dart';

/// Layar pengaturan — input IP & port server, tombol tes koneksi.
class SettingsScreen extends StatefulWidget {
  final WebSocketService wsService;

  const SettingsScreen({super.key, required this.wsService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();
  bool _testing = false;
  bool? _testResult;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final ip = await PrefsService.getServerIp();
    final port = await PrefsService.getServerPort();
    _ipController.text = ip;
    _portController.text = port.toString();
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8000;
    final result = await widget.wsService.testConnection(ip, port);

    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _save() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8000;
    await PrefsService.saveServer(ip, port);
    if (!mounted) return;
    Navigator.pop(context, true); // true = settings changed
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Pengaturan Server',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Info box ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF448AFF).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFF448AFF).withOpacity(0.25)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: Color(0xFF82B1FF), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pastikan HP dan laptop terhubung ke WiFi yang sama.',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF82B1FF),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // ── IP Address ──
            Text(
              'IP Address Server',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            _buildTextField(
              controller: _ipController,
              hint: '192.168.1.100',
              icon: Icons.router_rounded,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),

            // ── Port ──
            Text(
              'Port',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 8),
            _buildTextField(
              controller: _portController,
              hint: '8000',
              icon: Icons.numbers_rounded,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 28),

            // ── Test connection ──
            OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white54),
                    )
                  : const Icon(Icons.network_check_rounded),
              label: Text(_testing ? 'Menguji...' : 'Test Koneksi'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle:
                    GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_testResult!
                          ? const Color(0xFF00E676)
                          : const Color(0xFFFF5252))
                      .withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _testResult!
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      color: _testResult!
                          ? const Color(0xFF00E676)
                          : const Color(0xFFFF5252),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _testResult!
                          ? 'Koneksi berhasil!'
                          : 'Gagal terhubung — periksa IP, port, dan WiFi.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: _testResult!
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFF5252),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const Spacer(),

            // ── Save ──
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: const Text('Simpan & Hubungkan'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF448AFF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle:
                    GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(color: Colors.white24),
        prefixIcon: Icon(icon, color: Colors.white30, size: 20),
        filled: true,
        fillColor: const Color(0xFF1A1A2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Color(0xFF448AFF), width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}
