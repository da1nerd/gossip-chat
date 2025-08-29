import 'package:gossip/gossip.dart';

/// Typed event for chat messages.
class ChatMessageEvent extends TypedEvent {
  final String senderId;
  final String senderName;
  final String content;
  final DateTime timestamp;

  ChatMessageEvent({
    required this.senderId,
    required this.senderName,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String get type => 'chat_message';

  @override
  Map<String, dynamic> toJson() {
    return {
      'senderId': senderId,
      'senderName': senderName,
      'content': content,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  static ChatMessageEvent fromJson(Map<String, dynamic> json) {
    return ChatMessageEvent(
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      content: json['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }

  @override
  String toString() {
    return '[$senderName]: $content';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessageEvent &&
          runtimeType == other.runtimeType &&
          senderId == other.senderId &&
          content == other.content &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(senderId, content, timestamp);
}

/// Typed event for when a user joins the chat.
class UserJoinedEvent extends TypedEvent {
  final String userId;
  final String userName;
  final DateTime timestamp;

  UserJoinedEvent({
    required this.userId,
    required this.userName,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String get type => 'user_joined';

  @override
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'userName': userName,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  static UserJoinedEvent fromJson(Map<String, dynamic> json) {
    return UserJoinedEvent(
      userId: json['userId'] as String,
      userName: json['userName'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }

  @override
  String toString() {
    return '$userName joined the chat';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserJoinedEvent &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          userName == other.userName;

  @override
  int get hashCode => Object.hash(userId, userName);
}

/// Typed event for when a user leaves the chat.
class UserLeftEvent extends TypedEvent {
  final String userId;
  final String userName;
  final DateTime timestamp;

  UserLeftEvent({
    required this.userId,
    required this.userName,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String get type => 'user_left';

  @override
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'userName': userName,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  static UserLeftEvent fromJson(Map<String, dynamic> json) {
    return UserLeftEvent(
      userId: json['userId'] as String,
      userName: json['userName'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }

  @override
  String toString() {
    return '$userName left the chat';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserLeftEvent &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          userName == other.userName;

  @override
  int get hashCode => Object.hash(userId, userName);
}

/// Helper class to register all chat event types.
class ChatEventRegistry {
  static void registerAll() {
    final registry = TypedEventRegistry();

    registry.register<ChatMessageEvent>(
      'chat_message',
      ChatMessageEvent.fromJson,
    );

    registry.register<UserJoinedEvent>(
      'user_joined',
      UserJoinedEvent.fromJson,
    );

    registry.register<UserLeftEvent>(
      'user_left',
      UserLeftEvent.fromJson,
    );
  }
}
