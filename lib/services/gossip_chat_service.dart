import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_chat_demo/models/chat_message.dart';
import 'package:gossip_chat_demo/models/chat_peer.dart';
import 'package:gossip_chat_demo/services/shared_prefs_vector_clock_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'nearby_connections_transport.dart';
import 'permissions_service.dart';

/// Represents a user in the chat system.
class ChatUser {
  final String id;
  final String name;
  final bool isOnline;
  final DateTime? lastSeen;

  const ChatUser({
    required this.id,
    required this.name,
    required this.isOnline,
    this.lastSeen,
  });

  ChatUser copyWith({
    String? id,
    String? name,
    bool? isOnline,
    DateTime? lastSeen,
  }) {
    return ChatUser(
      id: id ?? this.id,
      name: name ?? this.name,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatUser && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Chat service using the GossipNode.
///
/// This service provides a clean, type-safe interface for chat functionality
/// using the gossip protocol for event synchronization across devices.
class GossipChatService extends ChangeNotifier {
  static const String _userNameKey = 'user_name';
  static const String _userIdKey = 'user_id';
  static const String _serviceId = 'gossip_chat_demo';

  String? _userId;
  String? _userName;
  late final NearbyConnectionsTransport _transport;
  late final GossipNode _gossipNode;

  final List<ChatMessage> _messages = [];
  final Map<String, ChatUser> _users = {};
  final Set<String> _processedEventIds = {};
  final Map<String, String> _peerIdToUserIdMap = {};

  StreamSubscription<Event>? _eventCreatedSubscription;
  StreamSubscription<ReceivedEvent>? _eventReceivedSubscription;
  StreamSubscription<GossipPeer>? _peerAddedSubscription;
  StreamSubscription<GossipPeer>? _peerRemovedSubscription;

  bool _isInitialized = false;
  bool _isStarted = false;
  String? _error;

  GossipChatService();

  void _initializeComponents() {
    if (_userId == null || _userName == null) {
      throw StateError(
          'User ID and name must be set before initializing components');
    }

    // Create transport
    _transport = NearbyConnectionsTransport(
      serviceId: _serviceId,
      userName: _userName!,
      nodeId: _userId!,
    );

    // Create gossip node with chat-optimized configuration
    final config = GossipConfig(
      nodeId: _userId!,
      gossipInterval: const Duration(seconds: 2),
      fanout: 3,
      gossipTimeout: const Duration(seconds: 8),
      maxEventsPerMessage: 50,
      enableAntiEntropy: true,
      antiEntropyInterval: const Duration(minutes: 2),
      peerDiscoveryInterval: const Duration(seconds: 1),
    );

    _gossipNode = GossipNode(
      config: config,
      eventStore: MemoryEventStore(),
      transport: _transport,
      vectorClockStore: SharedPrefsVectorClockStore(),
    );

    // Add ourselves as a user
    _users[_userId!] = ChatUser(
      id: _userId!,
      name: _userName!,
      isOnline: true,
    );
  }

  /// Set the user ID for this chat service.
  void setUserId(String userId) {
    if (_isInitialized) {
      throw StateError('Cannot change user ID after service is initialized');
    }
    _userId = userId;
    notifyListeners();
  }

  /// Set the user name for this chat service.
  Future<void> setUserName(String userName) async {
    if (_isInitialized) {
      throw StateError('Cannot change user name after service is initialized');
    }

    _userName = userName.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, _userName!);

    debugPrint('✅ Username set to: $_userName');
    notifyListeners();
  }

  /// Initialize the chat service.
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

      // Load or generate user info first
      await _loadUserInfo();
      debugPrint('✅ User info loaded: $_userName ($_userId)');

      _error = null;

      // Initialize components now that we have user info
      _initializeComponents();

      // Set up event listeners before starting the node
      _setupEventListeners();

      // Start the gossip node
      await _gossipNode.start();

      // Send initial presence announcement
      // The gossip library will automatically sync this to all peers (current and future)
      await _announcePresence();

      _isInitialized = true;
      notifyListeners();

      debugPrint('✅ GossipChatService initialized successfully');
    } catch (e, stackTrace) {
      _error = 'Failed to initialize chat service: $e';
      debugPrint('❌ $_error');
      debugPrint(stackTrace.toString());
      notifyListeners();
      rethrow;
    }
  }

  /// Start the chat service.
  Future<void> start() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_isStarted) return;

    try {
      debugPrint('▶️ Starting GossipChatService');

      _isStarted = true;
      notifyListeners();

      debugPrint('✅ GossipChatService started successfully');
    } catch (e) {
      _error = 'Failed to start chat service: $e';
      debugPrint('❌ $_error');
      notifyListeners();
      rethrow;
    }
  }

  /// Stop the chat service.
  Future<void> stop() async {
    if (!_isStarted) return;

    try {
      debugPrint('⏹️ Stopping GossipChatService');

      // Send presence departure
      await _announcePresence(isLeaving: true);
      // TODO: do we need to trigger an immediate sync before stopping the gossip node?
      //  Otherwise the departure message may not be received by other nodes.

      // Cancel subscriptions
      await _eventCreatedSubscription?.cancel();
      await _eventReceivedSubscription?.cancel();
      await _peerAddedSubscription?.cancel();
      await _peerRemovedSubscription?.cancel();

      // Stop gossip node
      await _gossipNode.stop();

      // Clear peer mappings
      _peerIdToUserIdMap.clear();

      _isStarted = false;
      _isInitialized = false;
      notifyListeners();

      debugPrint('✅ GossipChatService stopped successfully');
    } catch (e) {
      _error = 'Failed to stop chat service: $e';
      debugPrint('❌ $_error');
      notifyListeners();
    }
  }

  void _setupEventListeners() {
    // Listen for events we create
    _eventCreatedSubscription = _gossipNode.onEventCreated.listen(
      _handleEventCreated,
      onError: (error) {
        debugPrint('❌ Error in event created stream: $error');
      },
    );

    // Listen for events from other nodes
    _eventReceivedSubscription = _gossipNode.onEventReceived.listen(
      _handleEventReceived,
      onError: (error) {
        debugPrint('❌ Error in event received stream: $error');
      },
    );

    // Listen for peer connections
    _peerAddedSubscription = _gossipNode.onPeerAdded.listen(
      _handlePeerAdded,
      onError: (error) {
        debugPrint('❌ Error in peer added stream: $error');
      },
    );

    // Listen for peer disconnections
    _peerRemovedSubscription = _gossipNode.onPeerRemoved.listen(
      _handlePeerRemoved,
      onError: (error) {
        debugPrint('❌ Error in peer removed stream: $error');
      },
    );
  }

  void _handleEventCreated(Event event) {
    debugPrint('📝 Local event created: ${event.id}');
    _processEvent(event, isLocal: true);
  }

  void _handleEventReceived(ReceivedEvent receivedEvent) {
    final event = receivedEvent.event;
    final fromPeer = receivedEvent.fromPeer;

    debugPrint(
        '📥 Remote event received: ${event.id} from peer: ${fromPeer.id}');

    // Establish mapping between transport peer ID and user ID.
    // This allows us to correlate ChatUser with GossipPeer.
    final userId = event.nodeId;
    if (userId != _userId && !_peerIdToUserIdMap.containsKey(fromPeer.id)) {
      _peerIdToUserIdMap[fromPeer.id] = userId;
      debugPrint('🔗 Mapped peer ${fromPeer.id} to user $userId');
    }

    // Update user presence to online
    final ChatUser? user = _getUserByPeer(fromPeer);
    if (user != null && !user.isOnline) {
      // TODO: eventually this should be handled by the presence events.
      //  which won't need to use _getUserByPeer. That's only needed when a peer
      //  disconnects without sending a presence event.
      _users[user.id] = user.copyWith(
        isOnline: true,
        lastSeen: DateTime.now(),
      );
      debugPrint(
          '👤 Marked user online: ${user.name} (peer: ${fromPeer.id}, user: ${user.id})');
      notifyListeners();
    }

    _processEvent(event, isLocal: false);
  }

  void _handlePeerAdded(GossipPeer peer) {
    debugPrint('👋 Peer added: ${peer.id}');
    // Peer information will come through presence events
    // The gossip library will automatically sync all events including presence

    // final ChatUser? user = _getUserByPeer(peer);
    // if (user != null) {
    //   _users[user.id] = user.copyWith(
    //     isOnline: peer.isActive,
    //     lastSeen: DateTime.now(),
    //   );
    //   debugPrint(
    //       '👤 Marked user online: ${user.name} (peer: ${peer.id}, user: ${user.id})');
    // }

    notifyListeners();
  }

  void _handlePeerRemoved(GossipPeer peer) {
    debugPrint('👋 Peer removed: ${peer.id}');

    final ChatUser? user = _getUserByPeer(peer);

    if (user != null) {
      _users[user.id] = user.copyWith(
        isOnline: false,
        lastSeen: DateTime.now(),
      );
      debugPrint(
          '👤 Marked user offline: ${user.name} (peer: ${peer.id}, user: ${user.id})');
    }

    notifyListeners();
  }

  ChatUser? _getUserByPeer(GossipPeer peer) {
    final userId = _peerIdToUserIdMap[peer.id];
    if (userId != null) {
      return _users[userId];
    }
    return null;
  }

  void _processEvent(Event event, {required bool isLocal}) {
    // TODO: doesn't gossip already deal with duplicate events?
    // Prevent duplicate processing
    if (_processedEventIds.contains(event.id)) {
      return;
    }
    _processedEventIds.add(event.id);

    try {
      final payload = event.payload;
      final eventType = payload['type'] as String?;

      switch (eventType) {
        case 'chat_message':
          _processChatMessage(event);
          break;
        case 'user_presence':
          _processUserPresence(event);
          break;
        default:
          debugPrint('⚠️ Unknown event type: $eventType');
      }
    } catch (e) {
      debugPrint('❌ Error processing event ${event.id}: $e');
    }
  }

  void _processChatMessage(Event event) {
    try {
      final message = ChatMessage.fromEvent(event);

      // Add message if not already present
      if (!_messages.any((m) => m.id == message.id)) {
        _messages.add(message);
        _sortMessages();

        debugPrint('💬 Added chat message: ${message.content}');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('❌ Error processing chat message: $e');
    }
  }

  void _processUserPresence(Event event) {
    try {
      final payload = event.payload;
      final userId = payload['userId'] as String;
      final userName = payload['userName'] as String;
      final isOnline = payload['isOnline'] as bool? ?? true;

      // Skip processing our own presence events
      if (userId == _userId) {
        debugPrint('📢 Ignoring own presence event: $userName');
        return;
      }

      final wasNewUser = !_users.containsKey(userId);

      _users[userId] = ChatUser(
        id: userId,
        name: userName,
        isOnline: isOnline,
        lastSeen: isOnline ? null : DateTime.now(),
      );

      debugPrint(
          '👤 ${wasNewUser ? 'Added new user' : 'Updated user presence'}: $userName (${isOnline ? 'online' : 'offline'})');
      debugPrint(
          '📊 Total users: ${_users.length}, Online: ${onlineUsers.length}, Peers available: ${peers.length}');
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Error processing user presence: $e');
    }
  }

  void _sortMessages() {
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<void> _announcePresence({bool isLeaving = false}) async {
    try {
      final payload = {
        'type': 'user_presence',
        'userId': _userId!,
        'userName': _userName!,
        'isOnline': !isLeaving,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await _gossipNode.createEvent(payload);
      debugPrint(
          '📢 Announced ${isLeaving ? 'departure' : 'presence'} for $_userName');
      debugPrint('🌐 Connected transport peers: $connectedPeerCount');
      debugPrint(
          '👥 Known chat users: ${_users.length} (${onlineUsers.length} online)');
    } catch (e) {
      debugPrint('❌ Failed to announce presence: $e');
    }
  }

  /// Send a chat message.
  Future<ChatMessage> sendMessage(String content, {String? replyToId}) async {
    if (!_isStarted) {
      throw StateError('Chat service not started');
    }

    if (content.trim().isEmpty) {
      throw ArgumentError('Message content cannot be empty');
    }

    try {
      final messageId =
          '${_userId!}_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';

      final message = ChatMessage(
        id: messageId,
        senderId: _userId!,
        senderName: _userName!,
        content: content.trim(),
        timestamp: DateTime.now(),
        replyToId: replyToId,
      );

      // Create gossip event
      await _gossipNode.createEvent(message.toEventPayload());

      debugPrint('📤 Sent message: ${message.content}');
      return message;
    } catch (e) {
      debugPrint('❌ Failed to send message: $e');
      rethrow;
    }
  }

  /// Get all chat messages, sorted by timestamp.
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Get all known users.
  List<ChatUser> get users => _users.values.toList();

  /// Get online users only.
  List<ChatUser> get onlineUsers =>
      _users.values.where((user) => user.isOnline).toList();

  /// Get the current user.
  ChatUser get currentUser => _users[_userId!]!;

  /// Get the current user ID.
  String? get userId => _userId;

  /// Get the current user name.
  String? get userName => _userName;

  /// Whether the service is initialized.
  bool get isInitialized => _isInitialized;

  /// Whether the service is started.
  bool get isStarted => _isStarted;

  /// Current error message, if any.
  String? get error => _error;

  /// Number of connected peers.
  int get connectedPeerCount => _transport.peerCount;

  /// Whether we have any connected peers.
  bool get hasConnectedPeers => _transport.hasConnectedPeers;

  /// Get connection statistics for debugging.
  Map<String, dynamic> getConnectionStats() => _transport.getStats();

  /// Get detailed connection status for debugging.
  String getConnectionStatus() => _transport.getConnectionStatus();

  /// Get connection statistics for debugging (compatibility with SimpleGossipChatService)
  Map<String, dynamic> get connectionStats => getConnectionStats();

  /// Get peers as ChatPeer objects for UI compatibility
  List<ChatPeer> get peers {
    return users
        .map((user) => ChatPeer(
              id: user.id,
              name: user.name,
              status: user.isOnline
                  ? ChatPeerStatus.connected
                  : ChatPeerStatus.disconnected,
              connectedAt: DateTime.now(),
            ))
        .toList();
  }

  /// Clear the current error.
  void clearError() {
    if (_error != null) {
      _error = null;
      notifyListeners();
    }
  }

  /// Manually trigger peer discovery.
  Future<void> discoverPeers() async {
    if (!_isStarted) return;

    try {
      await _gossipNode.discoverPeers();
      debugPrint('🔍 Triggered peer discovery');
    } catch (e) {
      debugPrint('❌ Peer discovery failed: $e');
    }
  }

  /// Manually trigger gossip exchange.
  Future<void> gossip() async {
    if (!_isStarted) return;

    try {
      await _gossipNode.gossip();
      debugPrint('🗣️ Triggered gossip exchange');
    } catch (e) {
      debugPrint('❌ Gossip exchange failed: $e');
    }
  }

  /// Get a message by ID.
  ChatMessage? getMessageById(String messageId) {
    try {
      return _messages.firstWhere((m) => m.id == messageId);
    } catch (e) {
      return null;
    }
  }

  /// Get messages from a specific user.
  List<ChatMessage> getMessagesFromUser(String userId) {
    return _messages.where((m) => m.senderId == userId).toList();
  }

  /// Get messages that are replies to a specific message.
  List<ChatMessage> getRepliesTo(String messageId) {
    return _messages.where((m) => m.replyToId == messageId).toList();
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
    stop();
    super.dispose();
  }
}
