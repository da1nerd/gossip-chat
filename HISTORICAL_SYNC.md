# Historical Event Sync Feature

This document describes the new historical event synchronization feature added to the Gossip Chat Demo.

## Overview

The historical sync feature ensures that when a new device joins the chat network, it receives all past chat messages and events that occurred before it connected. This provides a complete conversation history to new participants.

## How It Works

### Automatic Sync

When a new peer connects to the network:

1. **Peer Detection**: The `SimpleGossipNode` monitors connected peers every second using a timer
2. **Automatic Trigger**: When a new peer is detected, historical sync is automatically triggered
3. **Event Retrieval**: All events are retrieved from the local `EventStore` 
4. **Chronological Ordering**: Events are sorted by their creation timestamp to maintain proper order
5. **Individual Transmission**: Each historical event is sent individually to the new peer using `sendEventToPeer()`
6. **Deduplication**: The receiving peer's event store automatically handles duplicate detection

### Manual Sync

Users can also manually trigger historical sync through the debug interface:

- **Sync to All Peers**: Sends all historical events to all currently connected peers
- **Sync to Specific Peer**: Sends historical events to a selected peer from a dropdown menu

## Configuration

### Enabling/Disabling Historical Sync

```dart
// Enable historical sync (default)
chatService.setHistoricalSyncEnabled(true);

// Disable historical sync
chatService.setHistoricalSyncEnabled(false);
```

### Manual Sync Operations

```dart
// Sync to all connected peers
await chatService.syncHistoricalEventsToAllPeers();

// Sync to a specific peer
await chatService.syncHistoricalEventsToPeer('peer-id');
```

## UI Controls

The Connection Debug Widget provides several controls for historical sync:

1. **Toggle Switch**: Enable/disable automatic historical sync for new peers
2. **"Sync History" Button**: Manually sync all historical events to all connected peers
3. **"Sync to..." Dropdown**: Select a specific peer to sync historical events to
4. **Message Count Display**: Shows the total number of messages that would be synced

## Technical Implementation

### Key Components

1. **`SimpleGossipNode`**:
   - `_syncHistoricalEventsToPeer()`: Internal method for syncing to a specific peer
   - `syncHistoricalEventsToPeer()`: Public method for manual sync to specific peer
   - `syncHistoricalEventsToAllPeers()`: Public method for manual sync to all peers

2. **`SimpleGossipTransport`**:
   - `sendEventToPeer()`: New method to send events to specific peers (vs broadcasting)

3. **`GossipChatService`**:
   - `setHistoricalSyncEnabled()`: Enable/disable automatic sync
   - `syncHistoricalEventsToPeer()` & `syncHistoricalEventsToAllPeers()`: Wrapper methods

4. **`EventStore`**:
   - `getAllEvents()`: Retrieves all stored events for syncing
   - Built-in deduplication prevents duplicate events

### Event Flow

```
New Peer Connects
       ↓
Peer Monitoring Timer Detects Change (1s interval)
       ↓
_syncHistoricalEventsToPeer() Called Automatically
       ↓
EventStore.getAllEvents() - Get All Historical Events
       ↓
Sort Events by Creation Timestamp
       ↓
For Each Event: Transport.sendEventToPeer()
       ↓
Receiving Peer Processes Events via Normal Event Handling
       ↓
EventStore Deduplication Prevents Duplicates
```

## Performance Considerations

### Network Efficiency
- Events are sent individually rather than in large batches to avoid overwhelming the connection
- Failed sends abort the sync process for that peer to avoid network spam
- Only connected peers receive historical events

### Memory Usage
- Historical events are loaded into memory temporarily during sync
- Events are sorted in-place using a copy to avoid modifying the original list
- Large event histories may impact memory usage during sync operations

### Timing
- Peer detection runs every 1 second to balance responsiveness with resource usage
- Historical sync happens asynchronously and doesn't block normal chat operations

## Error Handling

The system gracefully handles various error conditions:

- **Peer Disconnection**: If a peer disconnects during sync, the process is aborted
- **Transport Failures**: Individual event send failures are logged but don't stop the overall sync
- **Empty Event Store**: No events are sent if there's no history (no error thrown)
- **Invalid Peer IDs**: Manual sync methods throw `ArgumentError` for invalid peer IDs

## Debugging

### Log Messages

Historical sync operations produce detailed console logs:

```
📚 Syncing 15 historical events to peer peer-123
✅ Successfully synced 15/15 historical events to peer peer-123
❌ Failed to sync event msg_456 to peer peer-123: Connection lost
```

### Debug UI

The Connection Debug Widget shows:
- Current historical sync enabled/disabled status
- Total message count available for sync
- Manual sync controls with success/failure feedback
- Real-time peer connection status

## Best Practices

1. **Enable by Default**: Historical sync should remain enabled for the best user experience
2. **Monitor Performance**: Watch for performance issues with very large message histories
3. **Network Conditions**: Historical sync works best with stable network connections
4. **Privacy Considerations**: All connected peers receive full message history - ensure this aligns with your privacy requirements

## Testing

The feature includes comprehensive unit tests covering:
- Automatic sync when peers connect
- Manual sync operations
- Error handling scenarios
- Event ordering preservation
- Edge cases (empty stores, disconnected peers, etc.)

Run tests with:
```bash
cd gossip
dart test test/src/simple_gossip_node_historical_sync_test.dart
```
