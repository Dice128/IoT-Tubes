import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/push_up_data.dart';

/// Status koneksi WebSocket.
enum ConnectionStatus { disconnected, connecting, connected }

/// Service untuk mengelola koneksi WebSocket ke server push-up tracker.
///
/// Fitur:
/// - Auto-reconnect tiap 3 detik saat putus
/// - Parsing JSON aman (tidak crash kalau field hilang/null)
/// - Stream data untuk dipakai di UI
class WebSocketService {
  final _dataController = StreamController<PushUpData>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  bool _disposed = false;

  String _serverIp = '192.168.1.1';
  int _serverPort = 8000;

  /// Stream data push-up terbaru.
  Stream<PushUpData> get dataStream => _dataController.stream;

  /// Stream status koneksi.
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  /// Status koneksi saat ini.
  ConnectionStatus get status => _status;

  /// Update alamat server.
  void setServer(String ip, int port) {
    _serverIp = ip;
    _serverPort = port;
  }

  /// Mulai koneksi ke server.
  void connect() {
    if (_disposed) return;
    _cancelReconnect();
    _doConnect();
  }

  /// Putuskan koneksi dan berhenti reconnect.
  void disconnect() {
    _cancelReconnect();
    _channel?.sink.close();
    _channel = null;
    _setStatus(ConnectionStatus.disconnected);
  }

  /// Kirim pesan JSON ke server (session commands, dll).
  void sendMessage(Map<String, dynamic> data) {
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode(data));
      } catch (e) {
        debugPrint('[WS] Failed to send message: $e');
      }
    }
  }

  /// Bersihkan resource.
  void dispose() {
    _disposed = true;
    disconnect();
    _dataController.close();
    _statusController.close();
  }

  // ─── Internal ──────────────────────────────────────────────────────

  void _doConnect() {
    if (_disposed) return;
    _setStatus(ConnectionStatus.connecting);

    final uri = Uri.parse('ws://$_serverIp:$_serverPort/ws/mobile');
    debugPrint('[WS] Connecting to $uri');

    try {
      _channel = WebSocketChannel.connect(uri);
      _setStatus(ConnectionStatus.connected);

      _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          debugPrint('[WS] Error: $error');
          _onDisconnect();
        },
        onDone: () {
          debugPrint('[WS] Connection closed');
          _onDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[WS] Failed to connect: $e');
      _onDisconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final data = PushUpData.fromJson(json);
      if (!_dataController.isClosed) {
        _dataController.add(data);
      }
      // Pastikan status connected saat data masuk (edge case reconnect)
      if (_status != ConnectionStatus.connected) {
        _setStatus(ConnectionStatus.connected);
      }
    } catch (e) {
      debugPrint('[WS] Parse error: $e');
    }
  }

  void _onDisconnect() {
    _channel = null;
    _setStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _cancelReconnect();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      debugPrint('[WS] Reconnecting...');
      _doConnect();
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _setStatus(ConnectionStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(newStatus);
    }
  }

  /// Test koneksi — coba connect, tunggu beberapa detik, return true/false.
  Future<bool> testConnection(String ip, int port) async {
    final uri = Uri.parse('ws://$ip:$port/ws/mobile');
    try {
      final testChannel = WebSocketChannel.connect(uri);

      // Tunggu sampai ready atau timeout
      bool received = false;
      final completer = Completer<bool>();

      final sub = testChannel.stream.listen(
        (_) {
          if (!received) {
            received = true;
            if (!completer.isCompleted) completer.complete(true);
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(received);
        },
      );

      // Timeout 5 detik
      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );

      await sub.cancel();
      await testChannel.sink.close();
      return result;
    } catch (e) {
      debugPrint('[WS] Test connection failed: $e');
      return false;
    }
  }
}
