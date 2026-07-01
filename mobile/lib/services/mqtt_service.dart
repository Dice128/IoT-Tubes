import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

enum MqttAppConnectionState { disconnected, connecting, connected }

class MqttService {
  final _dataController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<MqttAppConnectionState>.broadcast();

  MqttServerClient? _client;
  MqttAppConnectionState _status = MqttAppConnectionState.disconnected;
  
  String _serverIp = '127.0.0.1';
  final int _port = 1883;

  Stream<Map<String, dynamic>> get dataStream => _dataController.stream;
  Stream<MqttAppConnectionState> get statusStream => _statusController.stream;
  MqttAppConnectionState get status => _status;

  void setServer(String ip) {
    _serverIp = ip;
  }

  Future<void> connect() async {
    if (_client != null && _client!.connectionStatus!.state == MqttConnectionState.connected) return;

    _setStatus(MqttAppConnectionState.connecting);
    
    // Generate unique client ID
    final clientId = 'flutter_client_${DateTime.now().millisecondsSinceEpoch}';
    _client = MqttServerClient(_serverIp, clientId);
    _client!.port = _port;
    _client!.keepAlivePeriod = 20;
    _client!.autoReconnect = true;
    
    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _client!.connectionMessage = connMessage;

    try {
      debugPrint('[MQTT] Connecting to $_serverIp:$_port...');
      await _client!.connect();
    } on NoConnectionException catch (e) {
      debugPrint('[MQTT] NoConnectionException: $e');
      _disconnect();
      return;
    } on SocketException catch (e) {
      debugPrint('[MQTT] SocketException: $e');
      _disconnect();
      return;
    } catch (e) {
      debugPrint('[MQTT] Exception: $e');
      _disconnect();
      return;
    }

    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      debugPrint('[MQTT] Connected');
      _setStatus(MqttAppConnectionState.connected);

      _client!.subscribe('pushup/imu', MqttQos.atMostOnce);
      
      _client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        final recMess = c[0].payload as MqttPublishMessage;
        final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        
        try {
          final json = jsonDecode(pt) as Map<String, dynamic>;
          if (!_dataController.isClosed) {
            _dataController.add(json);
          }
        } catch (e) {
          debugPrint('[MQTT] Parse error: $e');
        }
      });
    } else {
      debugPrint('[MQTT] Connection failed, state is ${_client!.connectionStatus!.state}');
      _disconnect();
    }
  }

  void publishControl(Map<String, dynamic> data) {
    if (_client != null && _status == MqttAppConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode(data));
      _client!.publishMessage('pushup/control', MqttQos.atLeastOnce, builder.payload!);
    }
  }

  void _disconnect() {
    _client?.disconnect();
    _client = null;
    _setStatus(MqttAppConnectionState.disconnected);
  }

  void disconnect() {
    _disconnect();
  }

  void _setStatus(MqttAppConnectionState newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(newStatus);
    }
  }

  void dispose() {
    _disconnect();
    _dataController.close();
    _statusController.close();
  }
}
