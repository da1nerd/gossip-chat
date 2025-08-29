import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';

import '../models/chat_message.dart';
import '../models/chat_peer.dart';
import 'permissions_service.dart';

class ChatService extends ChangeNotifier {
  static const String _userNameKey = 'user_name';
  static const String _userIdKey = 'user_id';
  static const String _serviceId = 'com.example.gossip_chat_demo';

  String? _userName;
  String? _userId;

  final List<ChatMessage> _messages = [];
  final Map<String, ChatPeer> _peers = {};
  bool _isInitialized = false;
  bool _isStarted = false;

  final StreamController<ChatMessage> _messageController =
      StreamController.broadcast();
  final StreamController<ChatPeer> _peerJoinedController =
      StreamController.broadcast();
  final StreamController<ChatPeer> _peerLeftController =
      StreamController.broadcast();

  // Getters
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ChatPeer> get peers => List.unmodifiable(_peers.values);
  String? get userName => _userName;
  String? get userId => _userId;
  bool get isInitialized => _isInitialized;
  bool get isStarted => _isStarted;

  // Streams
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;
  Stream<ChatPeer> get onPeerJoined => _peerJoinedController.stream;
  Stream<ChatPeer> get onPeerLeft => _peerLeftController.stream;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Request permissions
    final permissionsService = PermissionsService();
    final hasPermissions = await permissionsService.requestAllPermissions();
    if (!hasPermissions) {
      throw Exception('Required permissions not granted');
    }

    // Load or generate user info
    await _loadUserInfo();

    _isInitialized = true;
    notifyListeners();
  }

  Future<void> start() async {
    if (!_isInitialized || _isStarted) return;

    try {
      debugPrint('🚀 Starting chat service for user: $_userName');

      // Start advertising
      debugPrint('📡 Starting advertising with service ID: $_serviceId');
      await Nearby().startAdvertising(
        _userName!,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: _serviceId,
      );
      debugPrint('✅ Advertising started successfully');

      // Start discovery
      debugPrint('🔍 Starting discovery for nearby devices');
      await Nearby().startDiscovery(
        _userName!,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: _serviceId,
      );
      debugPrint('✅ Discovery started successfully');

      _isStarted = true;

      // Send join message
      await _sendJoinMessage();
      debugPrint('✅ Chat service fully started and ready');

      notifyListeners();
    } catch (e) {
      debugPrint('❌ Error starting chat service: $e');
      throw Exception('Failed to start chat service: $e');
    }
  }

  Future<void> stop() async {
    if (!_isStarted) return;

    try {
      // Send leave message
      await _sendLeaveMessage();

      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
      await Nearby().stopAllEndpoints();

      _isStarted = false;
      _peers.clear();

      notifyListeners();
    } catch (e) {
      debugPrint('Error stopping chat service: $e');
    }
  }

  Future<void> sendMessage(String content) async {
    if (!_isStarted || content.trim().isEmpty) return;

    final message = ChatMessage(
      senderId: _userId!,
      senderName: _userName!,
      content: content.trim(),
      type: ChatMessageType.text,
    );

    // Add to local messages
    _messages.add(message);
    _messageController.add(message);
    notifyListeners();

    // Broadcast to all connected peers
    await _broadcastMessage({
      'type': 'chat_message',
      'data': message.toJson(),
    });
  }

  Future<void> setUserName(String name) async {
    if (name.trim().isEmpty) return;

    _userName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, _userName!);

    notifyListeners();
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    debugPrint('🤝 Connection initiated with $id: ${info.endpointName}');
    // Auto-accept all connections for simplicity
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: _onPayloadTransferUpdate,
    );
    debugPrint('✅ Auto-accepted connection with $id');
  }

  void _onConnectionResult(String id, Status status) {
    debugPrint('🔗 Connection result for $id: $status');
    if (status == Status.CONNECTED) {
      // Connection successful - peer will be added when they send join message
      debugPrint('🎉 Successfully connected to peer $id');
    } else {
      // Connection failed
      debugPrint('❌ Connection failed with $id: $status');
      _removePeer(id);
    }
  }

  void _onDisconnected(String id) {
    debugPrint('💔 Disconnected from peer $id');
    _removePeer(id);
  }

  void _onEndpointFound(String id, String name, String serviceId) {
    debugPrint('🎯 FOUND DEVICE! ID: $id, Name: $name, Service: $serviceId');
    // Request connection when we find an endpoint
    debugPrint('📞 Requesting connection to $name ($id)');
    Nearby().requestConnection(
      _userName!,
      id,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  void _onEndpointLost(String? id) {
    if (id != null) {
      debugPrint('📤 Lost endpoint $id');
      _removePeer(id);
    }
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final data = payload.bytes!;
      final message = utf8.decode(data);

      try {
        final json = jsonDecode(message) as Map<String, dynamic>;
        final type = json['type'] as String;

        switch (type) {
          case 'chat_message':
            _handleChatMessage(json['data'] as Map<String, dynamic>);
            break;
          case 'user_joined':
            _handleUserJoined(json['data'] as Map<String, dynamic>);
            break;
          case 'user_left':
            _handleUserLeft(json['data'] as Map<String, dynamic>);
            break;
        }
      } catch (e) {
        debugPrint('Error parsing payload from $endpointId: $e');
      }
    }
  }

  void _onPayloadTransferUpdate(
      String endpointId, PayloadTransferUpdate payloadTransferUpdate) {
    if (payloadTransferUpdate.status == PayloadStatus.FAILURE) {
      debugPrint('Payload transfer failed for $endpointId');
    }
  }

  void _handleChatMessage(Map<String, dynamic> data) {
    try {
      final message = ChatMessage.fromJson(data);

      // Don't add our own messages again
      if (message.senderId == _userId) return;

      // Check if message already exists (duplicate detection)
      if (_messages.any((m) => m.id == message.id)) return;

      _messages.add(message);
      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _messageController.add(message);
      notifyListeners();
    } catch (e) {
      debugPrint('Error handling chat message: $e');
    }
  }

  void _handleUserJoined(Map<String, dynamic> data) {
    try {
      final peer = ChatPeer.fromJson(data);

      // Don't add ourselves
      if (peer.id == _userId) return;

      _addPeer(peer);

      // Add system message
      final joinMessage = ChatMessage(
        senderId: 'system',
        senderName: 'System',
        content: '${peer.name} joined the chat',
        type: ChatMessageType.userJoined,
      );
      _messages.add(joinMessage);
      _messageController.add(joinMessage);
      notifyListeners();
    } catch (e) {
      debugPrint('Error handling user joined: $e');
    }
  }

  void _handleUserLeft(Map<String, dynamic> data) {
    try {
      final peer = ChatPeer.fromJson(data);

      _removePeer(peer.id);

      // Add system message
      final leaveMessage = ChatMessage(
        senderId: 'system',
        senderName: 'System',
        content: '${peer.name} left the chat',
        type: ChatMessageType.userLeft,
      );
      _messages.add(leaveMessage);
      _messageController.add(leaveMessage);
      notifyListeners();
    } catch (e) {
      debugPrint('Error handling user left: $e');
    }
  }

  void _addPeer(ChatPeer peer) {
    if (!_peers.containsKey(peer.id)) {
      _peers[peer.id] = peer;
      _peerJoinedController.add(peer);
      notifyListeners();
    }
  }

  void _removePeer(String peerId) {
    final peer = _peers.remove(peerId);
    if (peer != null) {
      _peerLeftController.add(peer);
      notifyListeners();
    }
  }

  Future<void> _sendJoinMessage() async {
    final peer = ChatPeer(
      id: _userId!,
      name: _userName!,
      status: ChatPeerStatus.connected,
    );

    await _broadcastMessage({
      'type': 'user_joined',
      'data': peer.toJson(),
    });
  }

  Future<void> _sendLeaveMessage() async {
    final peer = ChatPeer(
      id: _userId!,
      name: _userName!,
      status: ChatPeerStatus.disconnected,
    );

    await _broadcastMessage({
      'type': 'user_left',
      'data': peer.toJson(),
    });
  }

  Future<void> _broadcastMessage(Map<String, dynamic> messageData) async {
    final message = jsonEncode(messageData);
    final bytes = Uint8List.fromList(utf8.encode(message));

    // Send to all connected peers
    final connectedPeerIds = _peers.keys.toList();
    for (final peerId in connectedPeerIds) {
      try {
        await Nearby().sendBytesPayload(peerId, bytes);
      } catch (e) {
        debugPrint('Error sending message to $peerId: $e');
      }
    }
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();

    _userName = prefs.getString(_userNameKey);
    _userId = prefs.getString(_userIdKey);

    // Generate new user ID if none exists
    if (_userId == null) {
      _userId = const Uuid().v4();
      await prefs.setString(_userIdKey, _userId!);
    }
  }

  @override
  void dispose() {
    _messageController.close();
    _peerJoinedController.close();
    _peerLeftController.close();
    stop();
    super.dispose();
  }
}
