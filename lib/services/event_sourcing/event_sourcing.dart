/// Event Sourcing and CQRS implementation for Gossip Chat
///
/// This library provides the core components for implementing Event Sourcing
/// and Command Query Responsibility Segregation (CQRS) patterns in the
/// gossip chat application.
///
/// Key components:
/// - EventProcessor: Coordinates event processing to projections
/// - Projection: Base class for read models
/// - ChatProjection: Main projection for chat state
library event_sourcing;

export 'event_processor.dart';
export 'projections/projection.dart';
export 'projections/chat_projection.dart';
