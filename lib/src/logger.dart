import 'dart:async';
import 'dart:isolate';

import 'package:loki_logger/src/log_event.dart';
import 'package:loki_logger/src/log_filter.dart';
import 'package:loki_logger/src/log_level.dart';
import 'package:loki_logger/src/log_output.dart';
import 'package:loki_logger/src/log_printer.dart';
import 'package:loki_logger/src/isolate_logger_connection.dart';
import 'package:loki_logger/src/isolate_name_server.dart';
import 'package:loki_logger/src/loki_client.dart';
import 'package:loki_logger/src/loki_config.dart';

/// Main logger class that brings together filter, printer, and output
class LokiLogger {
  /// Global logger level
  static Level level = Level.info;

  /// The log filter
  final LogFilter filter;

  /// The log printer
  final LogPrinter printer;

  /// The log output
  final LogOutput output;

  /// The logger name
  final String? name;

  /// Configuration for the logger to connect to Loki Server
  /// If set, the logger will send log events to Loki Server
  final LokiConfig? config;

  /// Whether Loki network operations should run in a dedicated isolate.
  ///
  /// Call [init] before logging when this option is enabled.
  final bool multiThreaded;

  /// Registry used to discover a logger isolate from other isolates.
  final LokiIsolateNameServer? isolateNameServer;

  /// Name used to register and find the shared logger isolate.
  final String isolateName;

  SendPort? _connectedSendPort;
  bool _ownsIsolate = false;
  IsolateLoggerConnection? _isolateConnection;
  final List<Map<String, Object?>> _pendingIsolateMessages = [];

  /// Loki client to send log events to Loki Server
  late LokiClient? lokiClient;

  /// Creates a new logger instance.
  LokiLogger({
    this.name,
    this.config,
    LogFilter? filter,
    LogPrinter? printer,
    LogOutput? output,
    this.multiThreaded = false,
    this.isolateNameServer,
    this.isolateName = 'loki_logger',
  })  : filter = filter ?? LevelFilter(level),
        printer = printer ?? PrettyPrinter(),
        lokiClient = config != null && !multiThreaded
            ? LokiClient(config: config)
            : null,
        output = output ?? ConsoleOutput(),
        _connectedSendPort = null;

  /// Creates a logger facade that sends Loki operations to an existing logger
  /// isolate. The [sendPort] must be obtained from a logger whose
  /// [multiThreaded] mode has been initialized.
  LokiLogger.connect(
    SendPort sendPort, {
    this.name,
    LogFilter? filter,
    LogPrinter? printer,
    LogOutput? output,
    this.isolateNameServer,
    this.isolateName = 'loki_logger',
  })  : config = null,
        multiThreaded = true,
        filter = filter ?? LevelFilter(level),
        printer = printer ?? PrettyPrinter(),
        output = output ?? ConsoleOutput(),
        lokiClient = null,
        _connectedSendPort = sendPort;

  /// The port that other isolates in the same isolate group can use to connect
  /// to this logger after [init] completes.
  SendPort? get sendPort => _connectedSendPort ?? _isolateConnection?.sendPort;

  FutureOr<void> init() async {
    if (_connectedSendPort != null) return;
    if (multiThreaded && config != null) {
      final server = isolateNameServer;
      final existingPort = server?.lookupPortByName(isolateName);
      if (existingPort != null) {
        _connectedSendPort = existingPort;
        _flushPendingMessages();
        return;
      }

      _isolateConnection ??= await IsolateLoggerConnection.spawn();
      final newPort = _isolateConnection!.sendPort;
      if (server != null &&
          !server.registerPortWithName(newPort, isolateName)) {
        await _isolateConnection!.close();
        _isolateConnection = null;
        final registeredPort = server.lookupPortByName(isolateName);
        if (registeredPort == null) {
          throw StateError(
            'Failed to register or find logger isolate "$isolateName".',
          );
        }
        _connectedSendPort = registeredPort;
      } else {
        _ownsIsolate = true;
        _connectedSendPort = newPort;
        try {
          await _isolateConnection!.initialize(config!);
        } catch (_) {
          _isolateConnection!.terminate();
          _isolateConnection = null;
          _connectedSendPort = null;
          _ownsIsolate = false;
          server?.removePortNameMapping(isolateName);
          rethrow;
        }
      }
      _flushPendingMessages();
      return;
    }
    return lokiClient?.init();
  }

  /// Log a trace message
  void t(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    log(Level.trace, message, error, stackTrace, customLabels);
  }

  /// Log a debug message
  void d(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    log(Level.debug, message, error, stackTrace, customLabels);
  }

  /// Log an info message
  void i(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    log(Level.info, message, error, stackTrace, customLabels);
  }

  /// Log a warning message
  void w(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    log(Level.warning, message, error, stackTrace, customLabels);
  }

  /// Log an error message
  void e(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    log(Level.error, message, error, stackTrace, customLabels);
  }

  /// Log a fatal message
  void f(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    log(Level.fatal, message, error, stackTrace, customLabels);
  }

  /// Log a message at the specified level
  void log(
    Level level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? customLabels,
  ]) {
    final event = LogEvent(
      level: level,
      message: message,
      error: error,
      stackTrace: stackTrace,
      loggerName: name,
      customLabels: customLabels,
    );

    if (filter.shouldLog(event)) {
      List<String> lines = printer.log(event);
      output.output(lines);
    }

    if (multiThreaded && config != null) {
      final port = sendPort;
      if (port == null) {
        throw StateError(
          'Call await logger.init() before logging in multi-threaded mode.',
        );
      }
      final logMessage = <String, Object?>{
        'type': 'log',
        'level': level.toLokiLevel(),
        'message': message,
        'error': error?.toString(),
        'stackTrace': stackTrace?.toString(),
        'time': event.time,
        'loggerName': name,
        'customLabels': event.customLabels,
      };
      _sendIsolateMessage(logMessage);
    } else if (_connectedSendPort != null) {
      _connectedSendPort?.send({
        'type': 'log',
        'level': level.toLokiLevel(),
        'message': message,
        'error': error?.toString(),
        'stackTrace': stackTrace?.toString(),
        'time': event.time,
        'loggerName': name,
        'customLabels': event.customLabels,
      });
    } else if (lokiClient != null) {
      lokiClient!.log(
        level: level.toLokiLevel(),
        message: message,
        error: error,
        stackTrace: stackTrace,
        time: event.time,
        loggerName: name,
        customLabels: event.customLabels,
      );
    }
  }

  /// Adds labels to the logger
  ///
  /// These labels will be included in all subsequent log messages sent to Loki.
  /// Labels can be used to add contextual information like user IDs, session IDs, etc.
  ///
  /// Example:
  /// ```dart
  /// logger.addLabels({
  ///   'user_id': '12345',
  ///   'session_id': 'abc-def-ghi',
  /// });
  /// ```
  void addLabels(Map<String, String> labels) {
    if (_connectedSendPort != null) {
      _connectedSendPort?.send({'type': 'addLabels', 'labels': labels});
    } else if (multiThreaded && config != null) {
      _sendIsolateMessage({'type': 'addLabels', 'labels': labels});
    } else {
      lokiClient?.addLabels(labels);
    }
  }

  /// Removes a specific label from the logger
  ///
  /// The removed label will no longer be included in subsequent log messages.
  ///
  /// Example:
  /// ```dart
  /// logger.removeLabel('user_id');
  /// ```
  void removeLabel(String key) {
    if (_connectedSendPort != null) {
      _connectedSendPort?.send({'type': 'removeLabel', 'key': key});
    } else if (multiThreaded && config != null) {
      _sendIsolateMessage({'type': 'removeLabel', 'key': key});
    } else {
      lokiClient?.removeLabel(key);
    }
  }

  /// Removes all labels from the logger
  ///
  /// This clears all labels that were added via [addLabels] or in the config.
  /// Subsequent log messages will only include labels specified in [customLabels] parameter.
  ///
  /// Example:
  /// ```dart
  /// logger.resetLabels();
  /// ```
  void resetLabels() {
    if (_connectedSendPort != null) {
      _connectedSendPort?.send({'type': 'resetLabels'});
    } else if (multiThreaded && config != null) {
      _sendIsolateMessage({'type': 'resetLabels'});
    } else {
      lokiClient?.resetLabels();
    }
  }

  void _sendIsolateMessage(Map<String, Object?> message) {
    final port = sendPort;
    if (port == null) {
      _pendingIsolateMessages.add(message);
      return;
    }
    port.send(message);
  }

  void _flushPendingMessages() {
    final port = sendPort;
    if (port == null) return;
    for (final message in _pendingIsolateMessages) {
      port.send(message);
    }
    _pendingIsolateMessages.clear();
  }

  /// Waits for the logger isolate (or local Loki client) to flush and close.
  Future<void> close() async {
    if (_ownsIsolate) {
      final connection = _isolateConnection;
      if (connection != null) await connection.close();
      _isolateConnection = null;
      _connectedSendPort = null;
      isolateNameServer?.removePortNameMapping(isolateName);
      _ownsIsolate = false;
      return;
    }
    if (_connectedSendPort != null) return;
    await lokiClient?.close();
  }

  /// Disposes resources used by this logger
  ///
  /// This should be called when the logger is no longer needed
  /// to free up resources and prevent memory leaks.
  void dispose() {
    if (_ownsIsolate) {
      unawaited(_closeAndReportErrors());
    } else if (_connectedSendPort == null && _isolateConnection == null) {
      lokiClient?.dispose();
    }
  }

  Future<void> _closeAndReportErrors() async {
    try {
      await close();
    } catch (error, stackTrace) {
      ConsoleOutput().output(
        PrettyPrinter().log(
          LogEvent(
            level: Level.error,
            message: 'Failed to close logger isolate: $error',
            stackTrace: stackTrace,
          ),
        ),
      );
    }
  }
}
