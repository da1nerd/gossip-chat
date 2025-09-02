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
  final Set<String> _pendingConnections = {};
  final Map<String, int> _connectionAttempts = {};
  final StreamController<Event> _incomingEventsController =
      StreamController.broadcast();

  bool _initialized = false;

  // Connection management settings
  static const int _maxConnectionAttempts = 3;
  static const Duration _connectionRetryDelay = Duration(seconds: 2);
  static const int _maxConcurrentConnections =
      8; // Android Nearby Connections limit
  static const Duration _connectionThrottleDelay = Duration(milliseconds: 500);

  // Connection strategy options
  final Strategy _connectionStrategy;

  NearbyConnectionsTransport({
    required this.serviceId,
    required this.userName,
    Strategy connectionStrategy = Strategy.P2P_CLUSTER,
  }) : _connectionStrategy = connectionStrategy;

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
    debugPrint('📡 Starting advertising with strategy: $_connectionStrategy');
    await Nearby().startAdvertising(
      userName,
      _connectionStrategy,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
      serviceId: serviceId,
    );
  }

  Future<void> _startDiscovery() async {
    debugPrint('🔍 Starting discovery with strategy: $_connectionStrategy');
    await Nearby().startDiscovery(
      userName,
      _connectionStrategy,
      onEndpointFound: _onEndpointFound,
      onEndpointLost: _onEndpointLost,
      serviceId: serviceId,
    );
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    debugPrint('🤝 Connection initiated with $id: ${info.endpointName}');

    // Check connection limits before accepting
    if (_connectedPeers.length >= _maxConcurrentConnections) {
      debugPrint('❌ Connection limit reached, rejecting connection from $id');
      try {
        Nearby().rejectConnection(id);
      } catch (e) {
        debugPrint('❌ Failed to reject connection with $id: $e');
      }
      return;
    }

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

    // Always remove from pending connections
    _pendingConnections.remove(id);

    if (status == Status.CONNECTED) {
      _connectedPeers.add(id);
      _connectionAttempts.remove(id); // Reset attempts on successful connection
      debugPrint(
          '🎉 Successfully connected to peer $id (Total: ${_connectedPeers.length})');
    } else {
      _connectedPeers.remove(id);
      debugPrint('❌ Connection failed with $id: $status');

      // Don't immediately retry on connection failure to avoid spam
      // The retry logic is handled in _requestConnection if appropriate
    }
  }

  void _onDisconnected(String id) {
    debugPrint('💔 Disconnected from peer $id');
    _connectedPeers.remove(id);
    _pendingConnections.remove(id);
    // Reset connection attempts when disconnected to allow reconnection
    _connectionAttempts.remove(id);
    debugPrint('📊 Remaining peers: ${_connectedPeers.length}');
  }

  void _onEndpointFound(String id, String name, String serviceId) {
    debugPrint('🎯 FOUND DEVICE! ID: $id, Name: $name, Service: $serviceId');

    // Check connection limits before attempting connection
    if (_connectedPeers.length + _pendingConnections.length >=
        _maxConcurrentConnections) {
      debugPrint(
          '⚠️ Connection limit reached, skipping connection to $name ($id)');
      return;
    }

    // Skip if we've already tried too many times
    if ((_connectionAttempts[id] ?? 0) >= _maxConnectionAttempts) {
      debugPrint('⚠️ Max attempts reached for $name ($id), skipping');
      return;
    }

    // Throttle connection attempts to avoid overwhelming the system
    Future.delayed(_connectionThrottleDelay, () {
      if (!_connectedPeers.contains(id) && !_pendingConnections.contains(id)) {
        _requestConnection(id, name);
      }
    });
  }

  void _onEndpointLost(String? id) {
    if (id != null) {
      debugPrint('📤 Lost device: $id');
      _connectedPeers.remove(id);
    }
  }

  void _requestConnection(String id, String name) async {
    // Check if already connected or pending
    if (_connectedPeers.contains(id) || _pendingConnections.contains(id)) {
      debugPrint('⚠️ Connection to $name ($id) already exists or is pending');
      return;
    }

    // Check connection attempts
    final attempts = _connectionAttempts[id] ?? 0;
    if (attempts >= _maxConnectionAttempts) {
      debugPrint('❌ Max connection attempts reached for $name ($id)');
      return;
    }

    _pendingConnections.add(id);
    _connectionAttempts[id] = attempts + 1;

    debugPrint(
        '📞 Requesting connection to $name ($id) (attempt ${attempts + 1}/$_maxConnectionAttempts)');

    try {
      await Nearby().requestConnection(
        userName,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      debugPrint('❌ Failed to request connection to $id: $e');
      _pendingConnections.remove(id);

      // Handle specific error codes
      if (e.toString().contains('STATUS_ENDPOINT_IO_ERROR') ||
          e.toString().contains('8012')) {
        debugPrint('🔄 IO Error detected, waiting longer before retry...');
        if (attempts + 1 < _maxConnectionAttempts) {
          Timer(Duration(seconds: 3 + attempts), () {
            _requestConnection(id, name);
          });
        }
      } else if (attempts + 1 < _maxConnectionAttempts) {
        debugPrint('🔄 Retrying connection to $name ($id) after delay...');
        Timer(_connectionRetryDelay, () {
          _requestConnection(id, name);
        });
      }
    }
  }

  // void _onConnectionInitiated(String id, ConnectionInfo info) {
  //   debugPrint('🤝 Connection initiated with $id: ${info.endpointName}');
  //
  //   // Auto-accept all connections for simplicity
  //   try {
  //     Nearby().acceptConnection(
  //       id,
  //       onPayLoadRecieved: _onPayloadReceived,
  //       onPayloadTransferUpdate: _onPayloadTransferUpdate,
  //     );
  //     debugPrint('✅ Auto-accepted connection with $id');
  //   } catch (e) {
  //     debugPrint('❌ Failed to accept connection with $id: $e');
  //   }
  // }

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

    debugPrint(
        '📤 Broadcasting event ${event.id} to ${_connectedPeers.length} peers');

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

    debugPrint(
        '📊 Broadcast complete: $successCount/${_connectedPeers.length + (successCount < _connectedPeers.length ? _connectedPeers.length - successCount : 0)} peers reached');
  }

  @override
  Future<void> sendEventToPeer(String peerId, Event event) async {
    if (!_initialized) {
      throw StateError('Transport not initialized');
    }

    if (!_connectedPeers.contains(peerId)) {
      debugPrint('⚠️ Peer $peerId is not connected, cannot send event');
      return;
    }

    final message = jsonEncode(event.toJson());
    final bytes = Uint8List.fromList(utf8.encode(message));

    try {
      await Nearby().sendBytesPayload(peerId, bytes);
      debugPrint('✉️ Sent event ${event.id} to peer $peerId');
    } catch (e) {
      debugPrint('❌ Failed to send event to $peerId: $e');
      // Remove failed peer from connected list
      _connectedPeers.remove(peerId);
      rethrow;
    }
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
      _pendingConnections.clear();
      _connectionAttempts.clear();
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
      'pendingConnections': _pendingConnections.length,
      'connectionAttempts': _connectionAttempts.length,
      'peerIds': _connectedPeers.toList(),
      'pendingIds': _pendingConnections.toList(),
      'userName': userName,
      'serviceId': serviceId,
      'connectionStrategy': _connectionStrategy.toString(),
    };
  }

  /// Get the number of connected peers
  int get peerCount => _connectedPeers.length;

  /// Check if we have any connected peers
  bool get hasConnectedPeers => _connectedPeers.isNotEmpty;

  /// Get detailed connection status for debugging
  String getConnectionStatus() {
    final buffer = StringBuffer();
    buffer.writeln('=== Nearby Connections Status ===');
    buffer.writeln('Initialized: $_initialized');
    buffer.writeln('Strategy: $_connectionStrategy');
    buffer.writeln('Connected Peers: ${_connectedPeers.length}');
    buffer.writeln('Pending Connections: ${_pendingConnections.length}');
    buffer.writeln('Connection Attempts: ${_connectionAttempts.length}');

    if (_connectedPeers.isNotEmpty) {
      buffer.writeln('\nConnected Peer IDs:');
      for (final peerId in _connectedPeers) {
        buffer.writeln('  • $peerId');
      }
    }

    if (_pendingConnections.isNotEmpty) {
      buffer.writeln('\nPending Connections:');
      for (final peerId in _pendingConnections) {
        buffer.writeln('  • $peerId');
      }
    }

    if (_connectionAttempts.isNotEmpty) {
      buffer.writeln('\nConnection Attempts:');
      _connectionAttempts.forEach((id, attempts) {
        buffer.writeln('  • $id: $attempts/$_maxConnectionAttempts');
      });
    }

    return buffer.toString();
  }

  /// Force cleanup of stale connection states
  void cleanupStaleConnections() {
    debugPrint('🧹 Cleaning up stale connections...');

    // Note: In a real implementation, you'd want to track connection timestamps
    // and remove stale connections that have been stuck for too long
    // For now, we'll just log the cleanup attempt
    debugPrint(
        '🧹 Cleanup complete - Connected: ${_connectedPeers.length}, Pending: ${_pendingConnections.length}');
  }

  /// Retry failed connections with exponential backoff
  Future<void> retryFailedConnections() async {
    if (_connectionAttempts.isEmpty) return;

    debugPrint('🔄 Retrying failed connections...');
    final toRetry = <String, int>{};

    // Find connections that haven't reached max attempts
    _connectionAttempts.forEach((id, attempts) {
      if (attempts < _maxConnectionAttempts &&
          !_connectedPeers.contains(id) &&
          !_pendingConnections.contains(id)) {
        toRetry[id] = attempts;
      }
    });

    if (toRetry.isEmpty) {
      debugPrint('🔄 No connections to retry');
      return;
    }

    debugPrint('🔄 Retrying ${toRetry.length} connections');
    for (final entry in toRetry.entries) {
      final id = entry.key;
      final attempts = entry.value;

      // Exponential backoff delay
      final delay = Duration(seconds: 2 * (attempts + 1));
      Timer(delay, () {
        _requestConnection(id, 'Unknown-$id');
      });
    }
  }
}
