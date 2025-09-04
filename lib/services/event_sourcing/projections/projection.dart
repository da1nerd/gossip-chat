import 'package:gossip/gossip.dart';

/// Base class for all projections (read models).
/// Projections build and maintain UI state from events.
abstract class Projection {
  /// Apply an event to update this projection's state
  Future<void> apply(Event event);

  /// Reset the projection to initial state
  Future<void> reset();

  /// Get the current state of this projection
  Map<String, dynamic> getState();
}

/// Mixin to add change notification to projections
mixin ProjectionChangeNotifier {
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  void dispose() {
    _listeners.clear();
  }
}
