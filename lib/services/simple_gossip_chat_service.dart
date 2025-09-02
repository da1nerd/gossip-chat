import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_events.dart';
import '../models/chat_message.dart';
import '../models/chat_peer.dart';
import 'simple_nearby_connections_transport.dart';
import 'permissions_service.dart';

/// Chat service using the improved Gossip library with SimpleGossipNode.
///
/// This service provides a clean, type-safe interface for chat functionality
/// using the gossip protocol for event synchronization across devices.
class SimpleGossipChatService extends ChangeNotifier {
  static const String _userNameKey = 'user_name';
  static const String _userIdKey = 'user_id';
  static const String _serviceId = 'com.example.gossip_chat_demo';

  SimpleGossipNode? _gossipNode;
  SimpleNearbyConnectionsTransport? _transport;
  String? _userName;
  String? _userId;

  final List<ChatMessage> _messages = [];
  final Map<String, ChatPeer> _peers = {};
  bool _isInitialized = false;
  bool _isStarted = false;
  bool _enableHistoricalSync = true; // Enable historical sync by default

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
  bool get enableHistoricalSync => _enableHistoricalSync;

  // Streams
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;
  Stream<ChatPeer> get onPeerJoined => _peerJoinedController.stream;
  Stream<ChatPeer> get onPeerLeft => _peerLeftController.stream;

  /// Get connection statistics for debugging
  Map<String, dynamic> get connectionStats {
    return _transport?.getStats() ?? {};
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('🚀 Initializing GossipChatService...');

      // Request permissions first
      final permissionsService = PermissionsService();
      final hasPermissions = await permissionsService.requestAllPermissions();
      if (!hasPermissions) {
        throw Exception('Required permissions not granted');
      }
      debugPrint('✅ Permissions granted');

      // Load or generate user info
      await _loadUserInfo();
      debugPrint('✅ User info loaded: $_userName ($_userId)');

      // Register typed events
      ChatEventRegistry.registerAll();
      debugPrint('✅ Typed events registered');

      // Create transport
      _transport = SimpleNearbyConnectionsTransport(
        serviceId: _serviceId,
        userName: _userName!,
        connectionStrategy:
            Strategy.P2P_CLUSTER, // Use P2P_STAR for hub-and-spoke if needed
      );
      debugPrint('✅ Transport created');

      // Create gossip node using the simplified interface
      _gossipNode = SimpleGossipNode(
        nodeId: _userId!,
        transport: _transport!,
        eventStore: MemoryEventStore(),
      );
      debugPrint('✅ SimpleGossipNode created');

      // Set up event listeners
      _setupEventListeners();
      debugPrint('✅ Event listeners set up');

      _isInitialized = true;
      debugPrint('🎉 GossipChatService initialized successfully');
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Failed to initialize GossipChatService: $e');
      rethrow;
    }
  }

  Future<void> start() async {
    if (!_isInitialized || _isStarted) return;

    try {
      debugPrint('🚀 Starting GossipChatService...');

      // Start the gossip node (this will initialize the transport)
      await _gossipNode!.start();
      debugPrint('✅ Gossip node started');

      _isStarted = true;

      // Wait for peer connections to stabilize before sending join event
      // TODO: it would be better to send the join event after we get our first peer.
      await _waitForConnectionStabilization();

      // Send join event after connections are stable
      await _sendJoinEvent();
      debugPrint('📤 Join event sent');

      debugPrint('🎉 GossipChatService started successfully');
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Failed to start GossipChatService: $e');
      throw Exception('Failed to start chat service: $e');
    }
  }

  Future<void> stop() async {
    if (!_isStarted) return;

    try {
      debugPrint('🛑 Stopping GossipChatService...');

      // Send leave event before stopping
      await _sendLeaveEvent();
      debugPrint('📤 Leave event sent');

      // Stop the gossip node
      await _gossipNode?.stop();
      debugPrint('✅ Gossip node stopped');

      _isStarted = false;
      _peers.clear();

      debugPrint('✅ GossipChatService stopped successfully');
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Error stopping GossipChatService: $e');
    }
  }

  Future<void> sendMessage(String content) async {
    if (!_isStarted || content.trim().isEmpty) return;

    try {
      final messageEvent = ChatMessageEvent(
        senderId: _userId!,
        senderName: _userName!,
        content: content.trim(),
      );

      debugPrint('📤 Sending message: "${content.trim()}"');

      // Broadcast the typed event using the gossip node
      await _gossipNode!.broadcastTypedEvent(messageEvent);

      // Add to local messages immediately for better UX
      final localMessage = ChatMessage(
        id: '${_userId!}_${DateTime.now().millisecondsSinceEpoch}',
        senderId: _userId!,
        senderName: _userName!,
        content: content.trim(),
        type: ChatMessageType.text,
      );

      _messages.add(localMessage);
      _messageController.add(localMessage);
      notifyListeners();

      debugPrint('✅ Message sent and added locally');
    } catch (e) {
      debugPrint('❌ Failed to send message: $e');
      throw Exception('Failed to send message: $e');
    }
  }

  Future<void> setUserName(String name) async {
    if (name.trim().isEmpty) return;

    _userName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, _userName!);

    debugPrint('✅ Username set to: $_userName');
    notifyListeners();
  }

  /// Enable or disable historical sync for newly connected peers
  void setHistoricalSyncEnabled(bool enabled) {
    _enableHistoricalSync = enabled;
    debugPrint('📚 Historical sync ${enabled ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  /// Manually sync historical events to a specific peer
  Future<void> syncHistoricalEventsToPeer(String peerId) async {
    if (!_isStarted || _gossipNode == null) {
      throw StateError('Service not started');
    }

    try {
      debugPrint('📚 Manually syncing historical events to peer: $peerId');
      await _gossipNode!.syncHistoricalEventsToPeer(peerId);
      debugPrint('✅ Manual historical sync completed for peer: $peerId');
    } catch (e) {
      debugPrint('❌ Manual historical sync failed for peer $peerId: $e');
      rethrow;
    }
  }

  /// Sync historical events to all currently connected peers
  Future<void> syncHistoricalEventsToAllPeers() async {
    if (!_isStarted || _gossipNode == null) {
      throw StateError('Service not started');
    }

    try {
      debugPrint('📚 Manually syncing historical events to all peers');
      await _gossipNode!.syncHistoricalEventsToAllPeers();
      debugPrint('✅ Manual historical sync completed for all peers');
    } catch (e) {
      debugPrint('❌ Manual historical sync failed: $e');
      rethrow;
    }
  }

  void _setupEventListeners() {
    if (_gossipNode == null) return;

    // Listen for chat message events
    _gossipNode!
        .onTypedEvent<ChatMessageEvent>(ChatMessageEvent.fromJson)
        .listen(_handleChatMessageEvent);

    // Listen for user joined events
    _gossipNode!
        .onTypedEvent<UserJoinedEvent>(UserJoinedEvent.fromJson)
        .listen(_handleUserJoinedEvent);

    // Listen for user left events
    _gossipNode!
        .onTypedEvent<UserLeftEvent>(UserLeftEvent.fromJson)
        .listen(_handleUserLeftEvent);

    // Listen for peer changes from the transport
    _gossipNode!.onPeerJoined.listen((peerId) {
      debugPrint('👋 Peer joined: $peerId');
      // Re-send our join event to newly connected peers so they know we're here
      _sendJoinEventToPeer(peerId);
      // Note: Historical sync is automatically handled by SimpleGossipNode
      if (_enableHistoricalSync) {
        debugPrint(
            '📚 Historical sync enabled - events will be synced automatically to $peerId');
      }
    });

    _gossipNode!.onPeerLeft.listen((peerId) {
      debugPrint('👋 Peer left: $peerId');
      _removePeer(peerId);
    });

    debugPrint('✅ Event listeners configured');
  }

  void _handleChatMessageEvent(ChatMessageEvent event) {
    try {
      // Don't add our own messages again (already added locally)
      if (event.senderId == _userId) return;

      // Check if message already exists (duplicate detection)
      if (_messages.any((m) =>
          m.senderId == event.senderId && m.timestamp == event.timestamp)) {
        return;
      }

      final message = ChatMessage(
        id: '${event.senderId}_${event.timestamp.millisecondsSinceEpoch}',
        senderId: event.senderId,
        senderName: event.senderName,
        content: event.content,
        timestamp: event.timestamp,
        type: ChatMessageType.text,
      );

      _messages.add(message);
      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _messageController.add(message);
      notifyListeners();

      debugPrint(
          '📨 Received message from ${event.senderName}: "${event.content}"');
    } catch (e) {
      debugPrint('❌ Error handling chat message event: $e');
    }
  }

  void _handleUserJoinedEvent(UserJoinedEvent event) {
    try {
      // Don't add ourselves
      if (event.userId == _userId) return;

      final peer = ChatPeer(
        id: event.userId,
        name: event.userName,
        status: ChatPeerStatus.connected,
      );

      // Check if this is a new peer (not a duplicate join event)
      final isNewPeer = !_peers.containsKey(peer.id);
      _addPeer(peer);

      // Only add system message for genuinely new peers
      if (isNewPeer) {
        final joinMessage = ChatMessage(
          senderId: 'system',
          senderName: 'System',
          content: '${event.userName} joined the chat',
          type: ChatMessageType.userJoined,
        );
        _messages.add(joinMessage);
        _messageController.add(joinMessage);
        notifyListeners();

        debugPrint('👋 User joined: ${event.userName} (${event.userId})');
      } else {
        debugPrint(
            '🔄 Received duplicate join event for: ${event.userName} (${event.userId})');
      }
    } catch (e) {
      debugPrint('❌ Error handling user joined event: $e');
    }
  }

  void _handleUserLeftEvent(UserLeftEvent event) {
    try {
      _removePeer(event.userId);

      // Add system message
      final leaveMessage = ChatMessage(
        senderId: 'system',
        senderName: 'System',
        content: '${event.userName} left the chat',
        type: ChatMessageType.userLeft,
      );
      _messages.add(leaveMessage);
      _messageController.add(leaveMessage);
      notifyListeners();

      debugPrint('👋 User left: ${event.userName} (${event.userId})');
    } catch (e) {
      debugPrint('❌ Error handling user left event: $e');
    }
  }

  void _addPeer(ChatPeer peer) {
    if (!_peers.containsKey(peer.id)) {
      _peers[peer.id] = peer;
      _peerJoinedController.add(peer);
      debugPrint(
          '➕ Added peer: ${peer.name} (${peer.id}) - Total peers: ${_peers.length}');
      notifyListeners();
    } else {
      // Update existing peer info
      _peers[peer.id] = peer;
      debugPrint('🔄 Updated existing peer: ${peer.name} (${peer.id})');
      notifyListeners();
    }
  }

  void _removePeer(String peerId) {
    final peer = _peers.remove(peerId);
    if (peer != null) {
      _peerLeftController.add(peer);
      debugPrint(
          '➖ Removed peer: ${peer.name} (${peer.id}) - Total peers: ${_peers.length}');
      notifyListeners();
    }
  }

  Future<void> _sendJoinEvent() async {
    try {
      final joinEvent = UserJoinedEvent(
        userId: _userId!,
        userName: _userName!,
      );

      await _gossipNode!.broadcastTypedEvent(joinEvent);
      debugPrint('📤 Sent join event for $_userName');
    } catch (e) {
      debugPrint('❌ Failed to send join event: $e');
    }
  }

  Future<void> _sendLeaveEvent() async {
    try {
      final leaveEvent = UserLeftEvent(
        userId: _userId!,
        userName: _userName!,
      );

      await _gossipNode!.broadcastTypedEvent(leaveEvent);
      debugPrint('📤 Sent leave event for $_userName');
    } catch (e) {
      debugPrint('❌ Failed to send leave event: $e');
    }
  }

  /// Wait for peer connections to stabilize before sending join event.
  /// This ensures that when we broadcast the join event, we're properly
  /// connected to other peers who can receive it.
  Future<void> _waitForConnectionStabilization() async {
    debugPrint('⏳ Waiting for peer connections to stabilize...');

    // Initial delay to allow transport to start discovering peers
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if we have any peers and wait for connection stability
    int stableConnectionCount = 0;
    int lastPeerCount = 0;
    const int requiredStableChecks = 3; // Number of stable checks required
    const Duration checkInterval = Duration(milliseconds: 500);
    const Duration maxWaitTime = Duration(seconds: 5);

    final stopwatch = Stopwatch()..start();

    while (stableConnectionCount < requiredStableChecks &&
        stopwatch.elapsed < maxWaitTime) {
      final currentPeerCount = _gossipNode?.connectedPeers.length ?? 0;

      if (currentPeerCount == lastPeerCount) {
        stableConnectionCount++;
        debugPrint(
            '🔗 Peer count stable: $currentPeerCount (check $stableConnectionCount/$requiredStableChecks)');
      } else {
        stableConnectionCount = 0; // Reset if peer count changed
        debugPrint('🔄 Peer count changed: $lastPeerCount → $currentPeerCount');
      }

      lastPeerCount = currentPeerCount;

      if (stableConnectionCount < requiredStableChecks) {
        await Future.delayed(checkInterval);
      }
    }

    final finalPeerCount = _gossipNode?.connectedPeers.length ?? 0;
    debugPrint(
        '✅ Connection stabilization complete. Connected to $finalPeerCount peer(s)');
  }

  /// Send join event to a specific newly connected peer
  Future<void> _sendJoinEventToPeer(String peerId) async {
    if (!_isStarted) return;

    try {
      // Small delay to ensure the peer connection is fully established
      await Future.delayed(const Duration(milliseconds: 100));

      final joinEvent = UserJoinedEvent(
        userId: _userId!,
        userName: _userName!,
      );

      await _gossipNode!.broadcastTypedEvent(joinEvent);
      debugPrint('📤 Re-sent join event to newly connected peer: $peerId');
    } catch (e) {
      debugPrint('❌ Failed to send join event to peer $peerId: $e');
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
      debugPrint('🆔 Generated new user ID: $_userId');
    }

    debugPrint('👤 Loaded user: $_userName ($_userId)');
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
