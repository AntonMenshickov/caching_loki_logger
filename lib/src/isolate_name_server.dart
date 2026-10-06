import 'dart:isolate';

/// Registry used by logger instances to find a logger isolate shared by
/// multiple isolates.
///
/// Implementations must make registered ports visible to every participating
/// isolate. Flutter applications can adapt `dart:ui`'s `IsolateNameServer`.
abstract interface class LokiIsolateNameServer {
  /// Returns the port registered under [name], or `null` if none exists.
  SendPort? lookupPortByName(String name);

  /// Registers [port] under [name]. Returns false if that name is already used.
  bool registerPortWithName(SendPort port, String name);

  /// Removes the mapping for [name].
  bool removePortNameMapping(String name);
}
