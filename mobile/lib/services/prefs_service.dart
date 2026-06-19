import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session_summary.dart';

/// Service untuk menyimpan & membaca pengaturan dan riwayat sesi
/// menggunakan shared_preferences.
class PrefsService {
  static const _keyIp = 'server_ip';
  static const _keyPort = 'server_port';
  static const _keySessions = 'session_history';

  // ─── Server settings ──────────────────────────────────────────────

  static Future<String> getServerIp() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString(_keyIp);
    if (savedIp != null && savedIp.isNotEmpty) {
      return savedIp;
    }
    return dotenv.env['SERVER_IP'] ?? '192.168.1.1';
  }

  static Future<int> getServerPort() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPort = prefs.getInt(_keyPort);
    if (savedPort != null) {
      return savedPort;
    }
    final envPort = dotenv.env['SERVER_PORT'];
    if (envPort != null) {
      return int.tryParse(envPort) ?? 8000;
    }
    return 8000;
  }

  static Future<void> saveServer(String ip, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyIp, ip);
    await prefs.setInt(_keyPort, port);
  }

  // ─── Session history ──────────────────────────────────────────────

  static Future<List<SessionSummary>> getSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySessions);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SessionSummary.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addSession(SessionSummary session) async {
    final sessions = await getSessions();
    sessions.insert(0, session); // terbaru di atas
    // Simpan maksimal 50 sesi terakhir
    final trimmed = sessions.take(50).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keySessions,
      jsonEncode(trimmed.map((s) => s.toJson()).toList()),
    );
  }

  static Future<void> clearSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySessions);
  }
}
