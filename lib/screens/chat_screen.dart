import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_service.dart';
import '../widgets/message_bubble.dart';
import '../widgets/peer_list_drawer.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocus = FocusNode();
  bool _isStarting = false;

  @override
  void initState() {
    super.initState();
    _startChatService();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  Future<void> _startChatService() async {
    setState(() {
      _isStarting = true;
    });

    try {
      final chatService = Provider.of<ChatService>(context, listen: false);
      if (!chatService.isStarted) {
        await chatService.start();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start chat: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isStarting = false;
        });
      }
    }
  }

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    final chatService = Provider.of<ChatService>(context, listen: false);
    chatService.sendMessage(content);
    _messageController.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatService>(
          builder: (context, chatService, child) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Gossip Chat'),
                Text(
                  '${chatService.peers.length} peer${chatService.peers.length != 1 ? 's' : ''} connected (Debug: ${chatService.isStarted ? "Started" : "Stopped"})',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                ),
              ],
            );
          },
        ),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        actions: [
          Consumer<ChatService>(
            builder: (context, chatService, child) {
              return IconButton(
                icon: Stack(
                  children: [
                    const Icon(Icons.people),
                    if (chatService.peers.isNotEmpty)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '${chatService.peers.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
                onPressed: () {
                  Scaffold.of(context).openEndDrawer();
                },
              );
            },
          ),
        ],
      ),
      endDrawer: const PeerListDrawer(),
      body: Column(
        children: [
          // Connection status
          Consumer<ChatService>(
            builder: (context, chatService, child) {
              if (_isStarting) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.orange.shade100,
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Starting chat service...',
                        style: TextStyle(color: Colors.orange.shade800),
                      ),
                    ],
                  ),
                );
              } else if (!chatService.isStarted) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.red.shade100,
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red.shade800),
                      const SizedBox(width: 8),
                      Text(
                        'Chat service not started',
                        style: TextStyle(color: Colors.red.shade800),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _startChatService,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              } else if (chatService.peers.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.blue.shade50,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.wifi_find, color: Colors.blue.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Looking for nearby devices...',
                              style: TextStyle(
                                  color: Colors.blue.shade700,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Debug Status:',
                        style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '✓ Service Started: ${chatService.isStarted}',
                        style: TextStyle(
                            color: Colors.blue.shade600, fontSize: 11),
                      ),
                      Text(
                        '✓ User: ${chatService.userName ?? "Unknown"}',
                        style: TextStyle(
                            color: Colors.blue.shade600, fontSize: 11),
                      ),
                      Text(
                        '✓ Peers Found: ${chatService.peers.length}',
                        style: TextStyle(
                            color: Colors.blue.shade600, fontSize: 11),
                      ),
                      if (chatService.peers.isNotEmpty)
                        ...chatService.peers.map((peer) => Text(
                              '  - ${peer.name} (${peer.status.name})',
                              style: TextStyle(
                                  color: Colors.blue.shade600, fontSize: 10),
                            )),
                      Text(
                        '• Advertising your device to nearby phones',
                        style: TextStyle(
                            color: Colors.blue.shade600, fontSize: 11),
                      ),
                      Text(
                        '• Scanning for other devices with this app',
                        style: TextStyle(
                            color: Colors.blue.shade600, fontSize: 11),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Make sure: Bluetooth ON, Location ON, other devices within 20m with app open',
                        style: TextStyle(
                            color: Colors.blue.shade600,
                            fontSize: 10,
                            fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),

          // Messages list
          Expanded(
            child: Consumer<ChatService>(
              builder: (context, chatService, child) {
                if (chatService.messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No messages yet',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Start a conversation or wait for others to join',
                          style: TextStyle(
                            color: Colors.grey[500],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                // Scroll to bottom when new messages arrive
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToBottom();
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: chatService.messages.length,
                  itemBuilder: (context, index) {
                    final message = chatService.messages[index];
                    final isMe = message.senderId == chatService.userId;

                    return MessageBubble(
                      message: message,
                      isMe: isMe,
                    );
                  },
                );
              },
            ),
          ),

          // Message input
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocus,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      maxLines: null,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Consumer<ChatService>(
                    builder: (context, chatService, child) {
                      return FloatingActionButton(
                        mini: true,
                        onPressed: chatService.isStarted ? _sendMessage : null,
                        backgroundColor: chatService.isStarted
                            ? Theme.of(context).primaryColor
                            : Colors.grey,
                        child: const Icon(
                          Icons.send,
                          color: Colors.white,
                          size: 20,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
