import 'dart:async';

import 'package:loki_logger/src/loki_sender.dart';
import 'package:loki_logger/src/model/event_message.dart';
import 'package:loki_logger/src/reliable_batch_queue.dart';

import 'loki_config.dart';

class LokiClient {
  /// Configuration for the logger to connect to Loki Server
  final LokiConfig config;

  late final ReliableBatchQueue _batchQueue;

  /// Map of labels to be added to each log
  final Map<String, String> _labels = {};

  LokiClient({required this.config}) {
    _labels.addAll(config.labels ?? {});
    _batchQueue = ReliableBatchQueue(
      config.batchQueueOptions,
      LokiSender(config: config),
    );
  }

  Future<void> init() {
    return _batchQueue.init();
  }

  /// Logs a message to Loki
  ///
  /// [level] is the log level (info, warn, error, etc.)
  /// [message] is the log message
  /// [error] is an optional error object
  /// [stackTrace] is an optional stack trace
  /// [time] is an optional timestamp (current time used if not provided)
  /// [loggerName] is an optional logger name
  /// [customLabels] allows adding custom labels to this specific log
  void log({
    required String level,
    required String message,
    Object? error,
    StackTrace? stackTrace,
    DateTime? time,
    String? loggerName,
    Map<String, String>? customLabels,
  }) {
    final timestamp =
        config.replaceTimestamp ? DateTime.now() : (time ?? DateTime.now());
    final nanoseconds = timestamp.microsecondsSinceEpoch * 1000;

    // Combine message with error and stack trace if present
    String fullMessage = message;
    if (error != null) {
      fullMessage += '\nError: $error';
    }
    if (stackTrace != null) {
      fullMessage += '\nStack Trace: $stackTrace';
    }

    // Prepare log entry
    final entry = EventMessage(
      timestamp: nanoseconds,
      message: fullMessage,
      labels: _prepareLabels(level, loggerName, customLabels),
    );

    _batchQueue.addEvent(entry);
  }

  /// Prepares the labels for a log entry
  Map<String, String> _prepareLabels(
    String level,
    String? loggerName,
    Map<String, String>? customLabels,
  ) {
    final allLabels = <String, String>{'level': level};

    // Add logger name if provided
    if (loggerName != null) {
      allLabels['logger'] = loggerName;
    }

    // Add global labels
    if (_labels.isNotEmpty) {
      allLabels.addAll(_labels);
    }

    // Add custom labels for this log
    if (customLabels != null) {
      allLabels.addAll(customLabels);
    }

    return allLabels;
  }

  /// Adds labels to the logger
  void addLabels(Map<String, String> labels) {
    _labels.addAll(labels);
  }

  /// Removes all labels from the logger
  void resetLabels() {
    _labels.clear();
  }

  /// Removes a specific label from the logger
  void removeLabel(String key) {
    _labels.remove(key);
  }

  /// Disposes resources used by this logger
  void dispose() {
    _labels.clear();
  }

  /// Closes the underlying batch queue and its database.
  Future<void> close() async {
    _labels.clear();
    await _batchQueue.close();
  }
}
