import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Real implementation of SimpleGossipTransport using nearby connections.
///
/// This transport provides automatic peer discovery and connection management
/// using Android's Nearby Connections API with Bluetooth and WiFi Direct.
class NearbyConnectionsTransport implements SimpleGossipTransport {
  final String serviceId;
  final String userName;

  final Set<String> _connectedPeers = {};
  final StreamController<Event> _incomingEventsController =
      StreamController.broadcast();

  bool _initialized = false;

  NearbyConnectionsTransport({
    required this.serviceId,
    required this.userName,
  });

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      debugPrint('🚀 Initializing NearbyConnectionsTransport for $userName');

      // Start advertising this device
      await _startAdvertising();
      debugPrint('📡 Started advertising successfully');

      // Start discovering other devices
      await _startDiscovery();
      debugPrint('🔍 Started discovery successfully');

      _initialized = true;
      debugPrint('✅ NearbyConnectionsTransport initialized successfully');
    } catch (e) {
      debugPrint('❌ Failed to initialize NearbyConnectionsTransport: $e');
      rethrow;
    }
  }

  Future<void> _startAdvertising() async {
    await Nearby().startAdvertising(
      userName,
      Strategy.P2P_CLUSTER,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
      serviceId: serviceId,
    );
  }

  Future<void> _startDiscovery() async {
    await Nearby().startDiscovery(
      userName,
      Strategy.P2P_CLUSTER,
      onEndpointFound: _onEndpointFound,
      onEndpointLost: _onEndpointLost,
      serviceId: serviceId,
    );
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    debugPrint('🤝 Connection initiated with $id: ${info.endpointName}');

    // Auto-accept all connections for simplicity
    try {
      Nearby().acceptConnection(
        id,
        onPayLoadRecieved: _onPayloadReceived,
        onPayloadTransferUpdate: _onPayloadTransferUpdate,
      );
      debugPrint('✅ Auto-accepted connection with $id');
    } catch (e) {
      debugPrint('❌ Failed to accept connection with $id: $e');
    }
  }

  void _onConnectionResult(String id, Status status) {
    debugPrint('🔗 Connection result for $id: $status');

    if (status == Status.CONNECTED) {
      _connectedPeers.add(id);
      debugPrint('🎉 Successfully connected to peer $id (Total: ${_connectedPeers.length})');
    } else {
      _connectedPeers.remove(id);
      debugPrint('❌ Connection failed with $id: $status');
    }
  }

  void _onDisconnected(String id) {
    debugPrint('💔 Disconnected from peer $id');
    _connectedPeers.remove(id);
    debugPrint('📊 Remaining peers: ${_connectedPeers.length}');
  }

  void _onEndpointFound(String id, String name, String serviceId) {
    debugPrint('🎯 FOUND DEVICE! ID: $id, Name: $name, Service: $serviceId');

    // Automatically request connection to found devices
    _requestConnection(id, name);
  }

  void _onEndpointLost(String? id) {
    if (id != null) {
      debugPrint('📤 Lost device: $id');
      _connectedPeers.remove(id);
    }
  }

  void _requestConnection(String id, String name) {
    debugPrint('📞 Requesting connection to $name ($id)');

    try {
      Nearby().requestConnection(
        userName,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      debugPrint('❌ Failed to request connection to $id: $e');
    }
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final data = payload.bytes!;
      final message = utf8.decode(data);

      try {
        final json = jsonDecode(message) as Map<String, dynamic>;
        final event = Event.fromJson(json);

        debugPrint('📥 Received event from $endpointId: ${event.id}');
        _incomingEventsController.add(event);
      } catch (e) {
        debugPrint('❌ Error parsing event from $endpointId: $e');
      }
    }
  }

  void _onPayloadTransferUpdate(
      String endpointId, PayloadTransferUpdate payloadTransferUpdate) {
    if (payloadTransferUpdate.status == PayloadStatus.SUCCESS) {
      debugPrint('✅ Payload transfer successful to $endpointId');
    } else if (payloadTransferUpdate.status == PayloadStatus.FAILURE) {
      debugPrint('❌ Payload transfer failed to $endpointId');
    }
  }

  @override
  Future<void> broadcastEvent(Event event) async {
    if (!_initialized) {
      throw StateError('Transport not initialized');
    }

    if (_connectedPeers.isEmpty) {
      debugPrint('⚠️ No connected peers to broadcast to');
      return;
    }

    final message = jsonEncode(event.toJson());
    final bytes = Uint8List.fromList(utf8.encode(message));

    debugPrint('📤 Broadcasting event ${event.id} to ${_connectedPeers.length} peers');

    // Send to all connected peers
    int successCount = 0;
    for (final peerId in _connectedPeers.toList()) {
      try {
        await Nearby().sendBytesPayload(peerId, bytes);
        successCount++;
        debugPrint('✉️ Sent event to peer $peerId');
      } catch (e) {
        debugPrint('❌ Failed to send event to $peerId: $e');
        // Remove failed peer from connected list
        _connectedPeers.remove(peerId);
      }
    }

    debugPrint('📊 Broadcast complete: $successCount/${_connectedPeers.length + (successCount < _connectedPeers.length ? _connectedPeers.length - successCount : 0)} peers reached');
  }

  @override
  Stream<Event> get incomingEvents => _incomingEventsController.stream;

  @override
  List<String> get connectedPeerIds => _connectedPeers.toList();

  @override
  Future<void> dispose() async {
    if (!_initialized) return;

    try {
      debugPrint('🛑 Disposing NearbyConnectionsTransport...');

      await Nearby().stopAdvertising();
      debugPrint('⏹️ Stopped advertising');

      await Nearby().stopDiscovery();
      debugPrint('⏹️ Stopped discovery');

      await Nearby().stopAllEndpoints();
      debugPrint('⏹️ Stopped all endpoints');

      await _incomingEventsController.close();
      _connectedPeers.clear();
      _initialized = false;

      debugPrint('✅ NearbyConnectionsTransport disposed successfully');
    } catch (e) {
      debugPrint('❌ Error disposing transport: $e');
    }
  }

  /// Check if the transport is initialized
  bool get isInitialized => _initialized;

  /// Get connection statistics for debugging
  Map<String, dynamic> getStats() {
    return {
      'initialized': _initialized,
      'connectedPeers': _connectedPeers.length,
      'peerIds': _connectedPeers.toList(),
      'userName': userName,
      'serviceId': serviceId,
    };
  }

  /// Get the number of connected peers
  int get peerCount => _connectedPeers.length;

  /// Check if we have any connected peers
  bool get hasConnectedPeers => _connectedPeers.isNotEmpty;
}
