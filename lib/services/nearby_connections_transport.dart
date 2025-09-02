import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Realization of [GossipTransport] using Nearby Connections API.
///
/// This transport provides automatic peer discovery and connection management
/// using Android's Nearby Connections API with Bluetooth and Wi-Fi Direct.
///
/// Implements the full 3-phase gossip protocol:
/// 1. Digest phase: Exchange vector clocks to determine what events are missing
/// 2. Response phase: Send missing events and request needed events
/// 3. Events phase: Send the requested events
class NearbyConnectionsTransport implements GossipTransport {
  final String serviceId;
  final String userName;
  final String nodeId;

  // Connection management
  final Map<String, GossipPeer> _connectedPeers = {};
  final Set<String> _pendingConnections = {};
  final Map<String, int> _connectionAttempts = {};

  // Message handling
  final StreamController<IncomingDigest> _incomingDigestsController =
      StreamController.broadcast();
  final StreamController<IncomingEvents> _incomingEventsController =
      StreamController.broadcast();

  // Pending requests for the gossip protocol
  final Map<String, Completer<GossipDigestResponse>> _pendingDigestRequests =
      {};
  final Map<String, Completer<void>> _pendingEventRequests = {};

  bool _initialized = false;

  // Connection settings
  static const int _maxConnectionAttempts = 3;
  static const Duration _connectionRetryDelay = Duration(seconds: 2);
  static const int _maxConcurrentConnections = 8;
  static const Duration _defaultTimeout = Duration(seconds: 10);
  static const Duration _connectionThrottleDelay = Duration(milliseconds: 500);

  final Strategy _connectionStrategy;

  NearbyConnectionsTransport({
    required this.serviceId,
    required this.userName,
    required this.nodeId,
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

    // Auto-accept all connections
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

    _pendingConnections.remove(id);

    if (status == Status.CONNECTED) {
      final peer = GossipPeer(
        id: id,
        address: id,
        lastContactTime: DateTime.now(),
        isActive: true,
      );
      _connectedPeers[id] = peer;
      _connectionAttempts.remove(id);
      debugPrint(
          '🎉 Successfully connected to peer $id (Total: ${_connectedPeers.length})');
    } else {
      _connectedPeers.remove(id);
      debugPrint('❌ Connection failed with $id: $status');
    }
  }

  void _onDisconnected(String id) {
    debugPrint('💔 Disconnected from peer $id');
    _connectedPeers.remove(id);
    _pendingConnections.remove(id);
    _connectionAttempts.remove(id);

    // Cancel any pending requests for this peer
    _cancelPendingRequestsForPeer(id);

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

    // Throttle connection attempts
    Future.delayed(_connectionThrottleDelay, () {
      if (!_connectedPeers.containsKey(id) &&
          !_pendingConnections.contains(id)) {
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
    if (_connectedPeers.containsKey(id) || _pendingConnections.contains(id)) {
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

      if (attempts + 1 < _maxConnectionAttempts) {
        Timer(_connectionRetryDelay, () {
          _requestConnection(id, name);
        });
      }
    }
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final data = payload.bytes!;
      final message = utf8.decode(data);

      try {
        final json = jsonDecode(message) as Map<String, dynamic>;
        final messageType = json['type'] as String;

        debugPrint('📥 Received $messageType from $endpointId');

        switch (messageType) {
          case 'digest':
            _handleIncomingDigest(endpointId, json);
            break;
          case 'digest_response':
            _handleIncomingDigestResponse(endpointId, json);
            break;
          case 'events':
            _handleIncomingEvents(endpointId, json);
            break;
          case 'events_ack':
            _handleEventsAcknowledgment(endpointId, json);
            break;
          default:
            debugPrint('❌ Unknown message type: $messageType');
        }
      } catch (e) {
        debugPrint('❌ Error parsing message from $endpointId: $e');
      }
    }
  }

  void _onPayloadTransferUpdate(
      String endpointId, PayloadTransferUpdate update) {
    if (update.status == PayloadStatus.SUCCESS) {
      debugPrint('✅ Payload transfer successful to $endpointId');
    } else if (update.status == PayloadStatus.FAILURE) {
      debugPrint('❌ Payload transfer failed to $endpointId');
    }
  }

  void _handleIncomingDigest(String endpointId, Map<String, dynamic> json) {
    try {
      final digest = GossipDigest.fromJson(json['digest']);
      final peer = _connectedPeers[endpointId];

      if (peer == null) {
        debugPrint('❌ Received digest from unknown peer: $endpointId');
        return;
      }

      final incomingDigest = IncomingDigest(
        fromPeer: peer,
        digest: digest,
        respond: (response) => _sendDigestResponse(endpointId, response),
      );

      _incomingDigestsController.add(incomingDigest);
    } catch (e) {
      debugPrint('❌ Error handling incoming digest from $endpointId: $e');
    }
  }

  void _handleIncomingDigestResponse(
      String endpointId, Map<String, dynamic> json) {
    try {
      final response = GossipDigestResponse.fromJson(json['response']);
      final requestId = json['requestId'] as String?;

      if (requestId != null && _pendingDigestRequests.containsKey(requestId)) {
        _pendingDigestRequests[requestId]!.complete(response);
        _pendingDigestRequests.remove(requestId);
      } else {
        debugPrint(
            '❌ Received digest response for unknown request: $requestId');
      }
    } catch (e) {
      debugPrint('❌ Error handling digest response from $endpointId: $e');
    }
  }

  void _handleIncomingEvents(String endpointId, Map<String, dynamic> json) {
    try {
      final eventMessage = GossipEventMessage.fromJson(json['message']);
      final peer = _connectedPeers[endpointId];

      if (peer == null) {
        debugPrint('❌ Received events from unknown peer: $endpointId');
        return;
      }

      // Send acknowledgment
      _sendEventsAcknowledgment(endpointId, json['requestId'] as String?);

      final incomingEvents = IncomingEvents(
        fromPeer: peer,
        message: eventMessage,
      );

      _incomingEventsController.add(incomingEvents);
    } catch (e) {
      debugPrint('❌ Error handling incoming events from $endpointId: $e');
    }
  }

  void _handleEventsAcknowledgment(
      String endpointId, Map<String, dynamic> json) {
    try {
      final requestId = json['requestId'] as String?;

      if (requestId != null && _pendingEventRequests.containsKey(requestId)) {
        _pendingEventRequests[requestId]!.complete();
        _pendingEventRequests.remove(requestId);
      }
    } catch (e) {
      debugPrint('❌ Error handling events acknowledgment from $endpointId: $e');
    }
  }

  Future<void> _sendDigestResponse(
      String endpointId, GossipDigestResponse response) async {
    try {
      final message = {
        'type': 'digest_response',
        'response': response.toJson(),
        'requestId': _generateRequestId(),
      };

      await _sendMessage(endpointId, message);
      debugPrint('📤 Sent digest response to $endpointId');
    } catch (e) {
      debugPrint('❌ Failed to send digest response to $endpointId: $e');
      rethrow;
    }
  }

  Future<void> _sendEventsAcknowledgment(
      String endpointId, String? requestId) async {
    try {
      final message = {
        'type': 'events_ack',
        'requestId': requestId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await _sendMessage(endpointId, message);
      debugPrint('📤 Sent events acknowledgment to $endpointId');
    } catch (e) {
      debugPrint('❌ Failed to send events acknowledgment to $endpointId: $e');
    }
  }

  Future<void> _sendMessage(
      String endpointId, Map<String, dynamic> message) async {
    final json = jsonEncode(message);
    final bytes = Uint8List.fromList(utf8.encode(json));

    await Nearby().sendBytesPayload(endpointId, bytes);
  }

  String _generateRequestId() {
    return '${nodeId}_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';
  }

  void _cancelPendingRequestsForPeer(String peerId) {
    // Cancel digest requests
    final digestKeysToRemove = <String>[];
    _pendingDigestRequests.forEach((key, completer) {
      if (key.startsWith(peerId)) {
        completer
            .completeError(TransportException('Peer disconnected: $peerId'));
        digestKeysToRemove.add(key);
      }
    });
    for (final key in digestKeysToRemove) {
      _pendingDigestRequests.remove(key);
    }

    // Cancel event requests
    final eventKeysToRemove = <String>[];
    _pendingEventRequests.forEach((key, completer) {
      if (key.startsWith(peerId)) {
        completer
            .completeError(TransportException('Peer disconnected: $peerId'));
        eventKeysToRemove.add(key);
      }
    });
    for (final key in eventKeysToRemove) {
      _pendingEventRequests.remove(key);
    }
  }

  @override
  Stream<IncomingDigest> get incomingDigests =>
      _incomingDigestsController.stream;

  @override
  Stream<IncomingEvents> get incomingEvents => _incomingEventsController.stream;

  @override
  Future<List<GossipPeer>> discoverPeers() async {
    if (!_initialized) {
      throw StateError('Transport not initialized');
    }

    return _connectedPeers.values.toList();
  }

  @override
  Future<bool> isPeerReachable(GossipPeer peer) async {
    if (!_initialized) {
      return false;
    }

    return _connectedPeers.containsKey(peer.id);
  }

  @override
  Future<GossipDigestResponse> sendDigest(
    GossipPeer peer,
    GossipDigest digest, {
    Duration? timeout,
  }) async {
    if (!_initialized) {
      throw StateError('Transport not initialized');
    }

    if (!_connectedPeers.containsKey(peer.id)) {
      throw TransportException('Peer ${peer.id} is not connected');
    }

    final requestId = _generateRequestId();
    final message = {
      'type': 'digest',
      'digest': digest.toJson(),
      'requestId': requestId,
    };

    final completer = Completer<GossipDigestResponse>();
    _pendingDigestRequests[requestId] = completer;

    try {
      await _sendMessage(peer.id, message);
      debugPrint('📤 Sent digest to ${peer.id}');

      // Wait for response with timeout
      final response = await completer.future.timeout(
        timeout ?? _defaultTimeout,
        onTimeout: () {
          _pendingDigestRequests.remove(requestId);
          throw TransportException('Digest request to ${peer.id} timed out');
        },
      );

      return response;
    } catch (e) {
      _pendingDigestRequests.remove(requestId);
      rethrow;
    }
  }

  @override
  Future<void> sendEvents(
    GossipPeer peer,
    GossipEventMessage message, {
    Duration? timeout,
  }) async {
    if (!_initialized) {
      throw StateError('Transport not initialized');
    }

    if (!_connectedPeers.containsKey(peer.id)) {
      throw TransportException('Peer ${peer.id} is not connected');
    }

    final requestId = _generateRequestId();
    final messagePayload = {
      'type': 'events',
      'message': message.toJson(),
      'requestId': requestId,
    };

    final completer = Completer<void>();
    _pendingEventRequests[requestId] = completer;

    try {
      await _sendMessage(peer.id, messagePayload);
      debugPrint('📤 Sent events to ${peer.id}');

      // Wait for acknowledgment with timeout
      await completer.future.timeout(
        timeout ?? _defaultTimeout,
        onTimeout: () {
          _pendingEventRequests.remove(requestId);
          throw TransportException('Events request to ${peer.id} timed out');
        },
      );
    } catch (e) {
      _pendingEventRequests.remove(requestId);
      rethrow;
    }
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized) return;

    try {
      debugPrint('🛑 Shutting down NearbyConnectionsTransport...');

      // Cancel all pending requests
      for (final completer in _pendingDigestRequests.values) {
        completer.completeError(TransportException('Transport shutting down'));
      }
      _pendingDigestRequests.clear();

      for (final completer in _pendingEventRequests.values) {
        completer.completeError(TransportException('Transport shutting down'));
      }
      _pendingEventRequests.clear();

      // Stop Nearby Connections services
      await Nearby().stopAdvertising();
      debugPrint('⏹️ Stopped advertising');

      await Nearby().stopDiscovery();
      debugPrint('⏹️ Stopped discovery');

      await Nearby().stopAllEndpoints();
      debugPrint('⏹️ Stopped all endpoints');

      // Close streams
      await _incomingDigestsController.close();
      await _incomingEventsController.close();

      // Clear state
      _connectedPeers.clear();
      _pendingConnections.clear();
      _connectionAttempts.clear();
      _initialized = false;

      debugPrint('✅ NearbyConnectionsTransport shut down successfully');
    } catch (e) {
      debugPrint('❌ Error shutting down transport: $e');
    }
  }

  /// Get connection statistics for debugging
  Map<String, dynamic> getStats() {
    return {
      'initialized': _initialized,
      'connectedPeers': _connectedPeers.length,
      'pendingConnections': _pendingConnections.length,
      'connectionAttempts': _connectionAttempts.length,
      'pendingDigestRequests': _pendingDigestRequests.length,
      'pendingEventRequests': _pendingEventRequests.length,
      'peerIds': _connectedPeers.keys.toList(),
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

  /// Get list of connected peer IDs
  List<String> get connectedPeerIds => _connectedPeers.keys.toList();

  /// Get detailed connection status for debugging
  String getConnectionStatus() {
    final buffer = StringBuffer();
    buffer.writeln('=== Nearby Connections Transport Status ===');
    buffer.writeln('Node ID: $nodeId');
    buffer.writeln('User Name: $userName');
    buffer.writeln('Service ID: $serviceId');
    buffer.writeln('Initialized: $_initialized');
    buffer.writeln('Strategy: $_connectionStrategy');
    buffer.writeln('Connected Peers: ${_connectedPeers.length}');
    buffer.writeln('Pending Connections: ${_pendingConnections.length}');
    buffer.writeln('Connection Attempts: ${_connectionAttempts.length}');
    buffer.writeln('Pending Digest Requests: ${_pendingDigestRequests.length}');
    buffer.writeln('Pending Event Requests: ${_pendingEventRequests.length}');

    if (_connectedPeers.isNotEmpty) {
      buffer.writeln('\nConnected Peers:');
      _connectedPeers.values.forEach((peer) {
        buffer.writeln(
            '  • ${peer.id} (${peer.isActive ? "active" : "inactive"})');
      });
    }

    if (_pendingConnections.isNotEmpty) {
      buffer.writeln('\nPending Connections:');
      for (final peerId in _pendingConnections) {
        buffer.writeln('  • $peerId');
      }
    }

    return buffer.toString();
  }
}
