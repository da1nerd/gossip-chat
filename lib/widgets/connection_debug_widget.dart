import 'package:flutter/material.dart';
import 'package:gossip_chat_demo/services/gossip_chat_service.dart';
import 'package:provider/provider.dart';

/// A debug widget that displays connection status and statistics.
/// Useful for troubleshooting multi-device connection issues.
class ConnectionDebugWidget extends StatefulWidget {
  const ConnectionDebugWidget({super.key});

  @override
  State<ConnectionDebugWidget> createState() => _ConnectionDebugWidgetState();
}

class _ConnectionDebugWidgetState extends State<ConnectionDebugWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<GossipChatService>(
      builder: (context, chatService, child) {
        final stats = chatService.getConnectionStats();
        final peerCount = chatService.connectedPeerCount;

        return Card(
          margin: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  Icons.network_check,
                  color: _getConnectionStatusColor(stats),
                ),
                title: const Text('Connection Debug'),
                subtitle: Text(
                    'Peers: $peerCount | Status: ${_getConnectionStatusText(stats)}'),
                trailing: IconButton(
                  icon:
                      Icon(_isExpanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _isExpanded = !_isExpanded),
                ),
              ),
              if (_isExpanded) _buildDetailedInfo(stats, chatService),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailedInfo(
      Map<String, dynamic> stats, GossipChatService chatService) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow(
              'Initialized', stats['initialized']?.toString() ?? 'false'),
          _buildInfoRow(
              'Connected Peers', stats['connectedPeers']?.toString() ?? '0'),
          _buildInfoRow('Pending Connections',
              stats['pendingConnections']?.toString() ?? '0'),
          _buildInfoRow('Connection Attempts',
              stats['connectionAttempts']?.toString() ?? '0'),
          _buildInfoRow('Service ID', stats['serviceId']?.toString() ?? 'N/A'),
          _buildInfoRow('Username', stats['userName']?.toString() ?? 'N/A'),
          _buildInfoRow(
              'Strategy', stats['connectionStrategy']?.toString() ?? 'N/A'),
          _buildInfoRow(
              'Total Messages', chatService.messages.length.toString()),
          const Divider(),
          const SizedBox(height: 8),
          if (stats['peerIds'] != null &&
              (stats['peerIds'] as List).isNotEmpty) ...[
            const Text('Connected Peer IDs:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ...(stats['peerIds'] as List).map((id) => Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 2),
                  child: Text('• $id',
                      style: const TextStyle(fontFamily: 'monospace')),
                )),
            const SizedBox(height: 8),
          ],
          if (stats['pendingIds'] != null &&
              (stats['pendingIds'] as List).isNotEmpty) ...[
            const Text('Pending Connections:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.orange)),
            const SizedBox(height: 4),
            ...(stats['pendingIds'] as List).map((id) => Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 2),
                  child: Text('• $id',
                      style: const TextStyle(
                          fontFamily: 'monospace', color: Colors.orange)),
                )),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () => _refreshStats(),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _showDetailedLog(chatService),
                icon: const Icon(Icons.info),
                label: const Text('Details'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Color _getConnectionStatusColor(Map<String, dynamic> stats) {
    final isInitialized = stats['initialized'] == true;
    final connectedPeers = stats['connectedPeers'] as int? ?? 0;
    final pendingConnections = stats['pendingConnections'] as int? ?? 0;

    if (!isInitialized) return Colors.grey;
    if (connectedPeers > 0) return Colors.green;
    if (pendingConnections > 0) return Colors.orange;
    return Colors.red;
  }

  String _getConnectionStatusText(Map<String, dynamic> stats) {
    final isInitialized = stats['initialized'] == true;
    final connectedPeers = stats['connectedPeers'] as int? ?? 0;
    final pendingConnections = stats['pendingConnections'] as int? ?? 0;

    if (!isInitialized) return 'Not Initialized';
    if (connectedPeers > 0) return 'Connected';
    if (pendingConnections > 0) return 'Connecting...';
    return 'Searching...';
  }

  void _refreshStats() {
    setState(() {});
  }

  void _showDetailedLog(GossipChatService chatService) {
    // This would show a detailed log dialog - you can implement based on your needs
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connection Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'User ID: ${chatService.userId ?? 'N/A'}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              Text(
                'Username: ${chatService.userName ?? 'N/A'}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              // Text(
              //   'Chat Peers: ${chatService.connectedPeerCount}',
              //   style: const TextStyle(fontWeight: FontWeight.bold),
              // ),
              // ...chatService.peers.map((peer) => Text(
              //     '• ${peer.name} (${peer.id})',
              //     style: const TextStyle(fontFamily: 'monospace'))),
              const SizedBox(height: 16),
              const Text(
                'Tips for Multi-Device Connections:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text('• Ensure all devices have location permissions'),
              const Text('• Keep devices close together (within 100m)'),
              const Text(
                  '• Avoid connecting more than 8 devices simultaneously'),
              const Text('• Try P2P_STAR strategy for hub-and-spoke topology'),
              const Text('• Check for STATUS_ENDPOINT_IO_ERROR in logs'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// A floating action button for quick connection debugging
class ConnectionDebugFAB extends StatelessWidget {
  const ConnectionDebugFAB({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<GossipChatService>(
      builder: (context, chatService, child) {
        final stats = chatService.connectionStats;
        final peerCount = chatService.peers.length;

        return FloatingActionButton(
          mini: true,
          backgroundColor: _getStatusColor(stats),
          onPressed: () => _showQuickStats(context, stats, peerCount),
          child: Text('$peerCount'),
        );
      },
    );
  }

  Color _getStatusColor(Map<String, dynamic> stats) {
    final connectedPeers = stats['connectedPeers'] as int? ?? 0;
    final pendingConnections = stats['pendingConnections'] as int? ?? 0;

    if (connectedPeers > 0) return Colors.green;
    if (pendingConnections > 0) return Colors.orange;
    return Colors.red;
  }

  void _showQuickStats(
      BuildContext context, Map<String, dynamic> stats, int peerCount) {
    final connectedPeers = stats['connectedPeers'] as int? ?? 0;
    final pendingConnections = stats['pendingConnections'] as int? ?? 0;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Connected: $connectedPeers | Pending: $pendingConnections | Chat Peers: $peerCount'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
