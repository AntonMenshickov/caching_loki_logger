import 'package:loki_logger/src/reliable_batch_queue.dart';

/// Configuration for [LokiLogger] to connect to Loki Server and send logs.
class LokiConfig {
  /// URL for Grafana Loki server
  final String host;

  /// Whether to replace log timestamps with current time
  final bool replaceTimestamp;

  /// Custom labels to attach to all logs
  final Map<String, String>? labels;

  /// Timeout for requests to Grafana Loki in milliseconds
  final int? timeout;

  /// Bearer authentication token to access Loki through Grafana’s data source proxy over HTTP
  final String? bearerToken;

  /// Basic authentication credentials to access Loki over HTTP
  final String? basicAuth;

  final ReliableBatchQueueOptions batchQueueOptions;

  const LokiConfig({
    required this.host,
    required this.batchQueueOptions,
    this.replaceTimestamp = true,
    this.labels,
    this.timeout,
    this.basicAuth,
    this.bearerToken,
  }) : assert(
          bearerToken == null || basicAuth == null,
          'Cannot use both bearer token and basic auth at the same time',
        );
}
