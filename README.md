# Gossip Chat Demo

A Flutter chat application that enables peer-to-peer messaging between nearby devices using Android's Nearby Connections API. Messages are synchronized across all connected devices in real-time without requiring internet connectivity.

## Features

- **Offline peer-to-peer messaging** - Chat with nearby devices without internet
- **Automatic device discovery** - Automatically finds and connects to nearby devices running the app
- **Real-time synchronization** - Messages appear instantly on all connected devices
- **User-friendly interface** - Clean, modern chat interface with message bubbles
- **Peer management** - View all connected users in a sidebar
- **System messages** - Notifications when users join or leave the chat

## Requirements

- Android device (API level 23 or higher)
- Bluetooth and Location services enabled
- Physical proximity to other devices (Nearby Connections range)

## Permissions

The app requires the following permissions:
- **Location** - Required for Nearby Connections API
- **Bluetooth** - For device discovery and connection
- **WiFi** - For high-speed data transfer
- **Storage** - Optional, for potential file sharing features

## Setup Instructions

1. Clone the repository:
```bash
git clone <repository-url>
cd gossip-demo
```

2. Install Flutter dependencies:
```bash
flutter pub get
```

3. Build and install the APK:
```bash
flutter build apk --release
flutter install
```

## Usage

1. **Launch the app** on multiple Android devices
2. **Enter your name** when prompted
3. **Enable permissions** when requested (Bluetooth, Location, etc.)
4. **Wait for device discovery** - The app will automatically find nearby devices
5. **Start chatting** - Messages will sync across all connected devices in real-time

## Architecture

The app uses a simple peer-to-peer architecture:

- **Nearby Connections API** - Handles device discovery and data transfer
- **Provider State Management** - Manages app state and UI updates  
- **JSON Message Protocol** - Simple message format for different event types
- **Automatic Reconnection** - Handles network disruptions gracefully

### Message Types

- `chat_message` - User text messages
- `user_joined` - System notification when a user joins
- `user_left` - System notification when a user leaves

## Project Structure

```
lib/
├── main.dart                 # App entry point
├── models/
│   ├── chat_message.dart    # Message data model
│   └── chat_peer.dart       # Peer data model
├── screens/
│   ├── name_input_screen.dart # Initial name input screen
│   └── chat_screen.dart     # Main chat interface
├── services/
│   ├── chat_service.dart    # Core chat logic and networking
│   └── permissions_service.dart # Permission handling
└── widgets/
    ├── message_bubble.dart  # Chat message UI component
    └── peer_list_drawer.dart # Connected peers sidebar
```

## Technical Notes

- Uses Flutter's `nearby_connections` plugin for Android Nearby Connections API
- Implements automatic peer discovery and connection management
- Messages are broadcast to all connected peers simultaneously
- No central server required - fully decentralized architecture
- Handles connection drops and reconnections automatically

## Limitations

- **Android only** - Nearby Connections API is Android-specific
- **Range limited** - Devices must be within Bluetooth/WiFi range
- **No message persistence** - Messages are lost when app is closed
- **No encryption** - Messages are sent in plain text (suitable for demo purposes)

## Development

To run in development mode:

```bash
flutter run
```

For debugging network issues:
```bash
flutter run --verbose
```

## Troubleshooting

**Devices not connecting?**
- Ensure Bluetooth and Location are enabled on both devices
- Try moving devices closer together
- Restart the app if discovery seems stuck

**Permission errors?**
- Grant all requested permissions in Android settings
- For Android 12+, ensure nearby device permissions are enabled

**Messages not syncing?**
- Check that devices appear in the peer list (tap the people icon)
- Try sending a message from each device to test bi-directional communication

## Future Enhancements

- Message persistence with local database
- File and image sharing
- End-to-end encryption
- iOS support (using different networking stack)
- Group chat management
- Message history and search

## License

MIT License - see LICENSE file for details