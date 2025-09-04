import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_chat_demo/models/chat_message.dart';
import 'package:gossip_chat_demo/models/chat_peer.dart';
import 'package:gossip_chat_demo/services/shared_prefs_vector_clock_store.dart';
import 'package:gossip_chat_demo/services/hive_event_store.dart';
import 'package:gossip_chat_demo/services/event_sourcing/event_sourcing.dart';
import 'package:gossip_chat_demo/models/chat_events.dart';
import 'package:gossip_typed_events/gossip_typed_events.dart';
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
  late final HiveEventStore _eventStore;

  // Event Sourcing components
  late final EventProcessor _eventProcessor;
  late final ChatProjection _chatProjection;

  // Legacy state - keeping for backward compatibility during transition
  final Map<String, String> _peerIdToUserIdMap = {};

  StreamSubscription<Event>? _eventCreatedSubscription;
  StreamSubscription<ReceivedEvent>? _eventReceivedSubscription;
  StreamSubscription<GossipPeer>? _peerAddedSubscription;
  StreamSubscription<GossipPeer>? _peerRemovedSubscription;

  bool _isInitialized = false;
  bool _isStarted = false;
  String? _error;

  GossipChatService() {
    _setupEventSourcing();
    _registerTypedEvents();
  }

  void _setupEventSourcing() {
    _eventProcessor = EventProcessor();
    _chatProjection = ChatProjection();

    // Register projection with processor
    _eventProcessor.registerProjection(_chatProjection);

    // Listen to projection changes and notify UI
    _chatProjection.addListener(() {
      notifyListeners();
    });

    debugPrint('✅ Event Sourcing architecture initialized');
  }

  void _registerTypedEvents() {
    // Register all chat event types in the global registry
    ChatEventRegistry.registerAll();
    debugPrint('✅ Typed events registered');
  }

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

    // Create event store
    _eventStore = HiveEventStore();

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
      eventStore: _eventStore,
      transport: _transport,
      vectorClockStore: SharedPrefsVectorClockStore(),
    );

    // Note: User will be added through presence announcement events
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

      // Initialize the event store
      await _eventStore.initialize();

      // Set up event listeners before starting the node
      _setupEventListeners();

      // Start the gossip node
      await _gossipNode.start();

      // Rebuild projections from stored events (Event Sourcing!)
      await _rebuildProjectionsFromStore();

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

  /// Rebuild all projections from stored events
  /// This is the core of Event Sourcing - rebuilds UI state from events
  Future<void> _rebuildProjectionsFromStore() async {
    try {
      debugPrint('🔄 Rebuilding projections from stored events...');

      // Get all events from store
      final allEvents = await _eventStore.getAllEvents();

      // Rebuild all projections
      await _eventProcessor.rebuildProjections(allEvents);

      debugPrint(
          '✅ Rebuilt projections from ${allEvents.length} stored events');
      debugPrint('💬 Messages in projection: ${_chatProjection.messageCount}');
      debugPrint('👥 Users in projection: ${_chatProjection.userCount}');
    } catch (e, stackTrace) {
      debugPrint('❌ Error rebuilding projections: $e');
      debugPrint(stackTrace.toString());
      rethrow; // This should prevent service from starting if projections can't be built
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

      // Close event store
      await _eventStore.close();

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
    // Process through Event Sourcing pipeline
    _eventProcessor.processEvent(event);
  }

  void _handleEventReceived(ReceivedEvent receivedEvent) {
    final event = receivedEvent.event;
    final fromPeer = receivedEvent.fromPeer;

    debugPrint(
        '📥 Remote event received: ${event.id} from peer: ${fromPeer.id}');

    // Establish mapping between transport peer ID and user ID.
    // This allows us to correlate ChatPeer with GossipPeer.
    final userId = event.nodeId;
    if (userId != _userId && !_peerIdToUserIdMap.containsKey(fromPeer.id)) {
      _peerIdToUserIdMap[fromPeer.id] = userId;
      debugPrint('🔗 Mapped peer ${fromPeer.id} to user $userId');
    }

    // Process through Event Sourcing pipeline
    _eventProcessor.processEvent(event);
  }

  void _handlePeerAdded(GossipPeer peer) {
    debugPrint('👋 Peer added: ${peer.id}');
    // Peer information will come through presence events
    // The gossip library will automatically sync all events including presence
    notifyListeners();
  }

  void _handlePeerRemoved(GossipPeer peer) {
    debugPrint('👋 Peer removed: ${peer.id}');

    final userId = _peerIdToUserIdMap[peer.id];
    if (userId != null) {
      final user = _chatProjection.getUser(userId);
      if (user != null) {
        // Create a synthetic user_presence event to mark them offline
        final presenceEvent = Event(
          id: 'presence_offline_${userId}_${DateTime.now().millisecondsSinceEpoch}',
          nodeId: _userId!,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          creationTimestamp: DateTime.now().millisecondsSinceEpoch,
          payload: {
            'type': 'user_presence',
            'userId': userId,
            'userName': user.name,
            'isOnline': false,
          },
        );
        _eventProcessor.processEvent(presenceEvent);
      }
    }

    notifyListeners();
  }

  Future<void> _announcePresence({bool isLeaving = false}) async {
    try {
      // Create typed event for presence
      final presenceEvent = UserPresenceEvent(
        userId: _userId!,
        userName: _userName!,
        isOnline: !isLeaving,
      );

      // Add metadata for context
      presenceEvent.setMetadata('source', 'gossip_chat_service');
      presenceEvent.setMetadata(
          'action', isLeaving ? 'departure' : 'announcement');

      await _gossipNode.createTypedEvent(presenceEvent);
      debugPrint(
          '📢 Announced ${isLeaving ? 'departure' : 'presence'} for $_userName (typed event)');
      debugPrint('🌐 Connected transport peers: $connectedPeerCount');
      debugPrint(
          '👥 Known chat users: ${users.length} (${onlineUsers.length} online)');
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
      // Create typed event for the message
      final messageEvent = ChatMessageEvent(
        senderId: _userId!,
        senderName: _userName!,
        content: content.trim(),
      );

      // Add metadata for context
      messageEvent.setMetadata('source', 'gossip_chat_service');
      if (replyToId != null) {
        messageEvent.setMetadata('replyToId', replyToId);
      }

      // Create typed event through gossip node
      final gossipEvent = await _gossipNode.createTypedEvent(messageEvent);

      // Create ChatMessage for return value
      final message = ChatMessage(
        id: gossipEvent.id,
        senderId: _userId!,
        senderName: _userName!,
        content: content.trim(),
        timestamp: DateTime.now(),
        replyToId: replyToId,
      );

      debugPrint('📤 Sent typed message: ${message.content}');
      return message;
    } catch (e) {
      debugPrint('❌ Failed to send message: $e');
      rethrow;
    }
  }

  /// Get all chat messages, sorted by timestamp.
  List<ChatMessage> get messages => _chatProjection.messages;

  /// Get all known users.
  List<ChatUser> get users => _chatProjection.users.values
      .cast<ChatPeer>()
      .map((peer) => ChatUser(
            id: peer.id,
            name: peer.name,
            isOnline: peer.isOnline,
            lastSeen: peer.lastSeen,
          ))
      .toList();

  /// Get online users only.
  List<ChatUser> get onlineUsers => _chatProjection.onlineUsers
      .cast<ChatPeer>()
      .map((peer) => ChatUser(
            id: peer.id,
            name: peer.name,
            isOnline: peer.isOnline,
            lastSeen: peer.lastSeen,
          ))
      .toList();

  /// Get the current user.
  ChatUser get currentUser {
    final peer = _chatProjection.getUser(_userId!);
    if (peer != null) {
      return ChatUser(
        id: peer.id,
        name: peer.name,
        isOnline: peer.isOnline,
        lastSeen: peer.lastSeen,
      );
    }
    return ChatUser(id: _userId!, name: _userName!, isOnline: true);
  }

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
    return _chatProjection.getMessageById(messageId);
  }

  /// Get messages from a specific user.
  List<ChatMessage> getMessagesFromUser(String userId) {
    return _chatProjection.getMessagesFromUser(userId);
  }

  /// Get messages that are replies to a specific message.
  List<ChatMessage> getRepliesTo(String messageId) {
    return _chatProjection.getRepliesTo(messageId);
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

    // Clean up event sourcing components
    _chatProjection.dispose();
    _eventProcessor.dispose();

    super.dispose();
  }
}
