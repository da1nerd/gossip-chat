import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'projections/projection.dart';

/// Coordinates processing of events to update projections.
/// This is the core of the Event Sourcing architecture.
class EventProcessor {
  final List<Projection> _projections = [];
  final Set<String> _processedEvents = {};

  /// Register a projection to be updated when events are processed
  void registerProjection(Projection projection) {
    _projections.add(projection);
    debugPrint(
        '📋 EventProcessor: Registered projection ${projection.runtimeType}');
  }

  /// Unregister a projection
  void unregisterProjection(Projection projection) {
    _projections.remove(projection);
    debugPrint(
        '📋 EventProcessor: Unregistered projection ${projection.runtimeType}');
  }

  /// Process a single event through all projections
  Future<void> processEvent(Event event) async {
    // Skip if already processed (idempotency)
    if (_processedEvents.contains(event.id)) {
      debugPrint(
          '⏭️  EventProcessor: Skipping already processed event ${event.id}');
      return;
    }

    debugPrint(
        '⚙️  EventProcessor: Processing event ${event.id} through ${_projections.length} projections');

    // Process through all projections
    for (final projection in _projections) {
      try {
        await projection.apply(event);
      } catch (e, stackTrace) {
        debugPrint(
            '❌ EventProcessor: Error applying event ${event.id} to ${projection.runtimeType}: $e');
        debugPrint(stackTrace.toString());
        // Continue processing other projections even if one fails
      }
    }

    _processedEvents.add(event.id);
    debugPrint('✅ EventProcessor: Finished processing event ${event.id}');
  }

  /// Process multiple events in order
  Future<void> processEvents(List<Event> events) async {
    if (events.isEmpty) {
      debugPrint('📝 EventProcessor: No events to process');
      return;
    }

    debugPrint('📝 EventProcessor: Processing ${events.length} events');

    // Sort by creation timestamp to ensure proper ordering
    events.sort((a, b) => a.creationTimestamp.compareTo(b.creationTimestamp));

    for (final event in events) {
      await processEvent(event);
    }

    debugPrint('✅ EventProcessor: Finished processing ${events.length} events');
  }

  /// Rebuild all projections from stored events
  /// This is the key method for Event Sourcing - rebuilds state from events
  Future<void> rebuildProjections(List<Event> allEvents) async {
    debugPrint(
        '🔄 EventProcessor: Rebuilding projections from ${allEvents.length} events');

    // Clear processed events cache
    _processedEvents.clear();

    // Reset all projections to initial state
    for (final projection in _projections) {
      try {
        await projection.reset();
        debugPrint(
            '🔄 EventProcessor: Reset projection ${projection.runtimeType}');
      } catch (e, stackTrace) {
        debugPrint(
            '❌ EventProcessor: Error resetting ${projection.runtimeType}: $e');
        debugPrint(stackTrace.toString());
      }
    }

    // Process all events in chronological order
    await processEvents(allEvents);

    debugPrint('✅ EventProcessor: Finished rebuilding all projections');
  }

  /// Get a projection by type
  T? getProjection<T extends Projection>() {
    try {
      return _projections.whereType<T>().first;
    } catch (e) {
      return null;
    }
  }

  /// Get all registered projections
  List<Projection> get projections => List.unmodifiable(_projections);

  /// Get count of processed events (for debugging/monitoring)
  int get processedEventCount => _processedEvents.length;

  /// Clear processed events cache (useful for testing)
  void clearProcessedEventsCache() {
    _processedEvents.clear();
    debugPrint('🧹 EventProcessor: Cleared processed events cache');
  }

  /// Dispose of the event processor
  void dispose() {
    _projections.clear();
    _processedEvents.clear();
    debugPrint('🔒 EventProcessor: Disposed');
  }

  /// Get current state of all projections (for debugging)
  Map<String, Map<String, dynamic>> getAllProjectionStates() {
    final Map<String, Map<String, dynamic>> states = {};
    for (final projection in _projections) {
      try {
        states[projection.runtimeType.toString()] = projection.getState();
      } catch (e) {
        states[projection.runtimeType.toString()] = {'error': e.toString()};
      }
    }
    return states;
  }
}
