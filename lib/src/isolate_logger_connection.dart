import 'dart:async';
import 'dart:isolate';

import 'package:loki_logger/src/log_event.dart';
import 'package:loki_logger/src/log_level.dart';
import 'package:loki_logger/src/log_output.dart';
import 'package:loki_logger/src/log_printer.dart';
import 'package:loki_logger/src/loki_client.dart';
import 'package:loki_logger/src/loki_config.dart';

class IsolateLoggerConnection {
  final SendPort sendPort;
  final Isolate _isolate;
  bool _closed = false;

  IsolateLoggerConnection._(this.sendPort, this._isolate);

  static Future<IsolateLoggerConnection> spawn() async {
    final bootstrap = ReceivePort();
    final isolate = await Isolate.spawn(
      _lokiLoggerIsolate,
      bootstrap.sendPort,
    );

    try {
      final sendPort = await bootstrap.first as SendPort;
      return IsolateLoggerConnection._(sendPort, isolate);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      bootstrap.close();
    }
  }

  Future<void> initialize(LokiConfig config) {
    return _request({'type': 'init', 'config': config});
  }

  void send(Map<String, Object?> message) {
    if (_closed) {
      throw StateError('The logger isolate has already been closed.');
    }
    sendPort.send(message);
  }

  Future<void> close() async {
    if (_closed) return;
    await _request({'type': 'close'});
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
  }

  void terminate() {
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
  }

  Future<void> _request(Map<String, Object?> message) async {
    if (_closed) {
      throw StateError('The logger isolate has already been closed.');
    }
    final reply = ReceivePort();
    try {
      sendPort.send({...message, 'replyTo': reply.sendPort});
      final response = await reply.first as Map;
      _throwIfError(response);
    } finally {
      reply.close();
    }
  }

  static void _throwIfError(Map response) {
    if (response['ok'] != true) {
      throw StateError(
        'Logger isolate request failed: ${response['error']}\n'
        '${response['stackTrace']}',
      );
    }
  }
}

void _lokiLoggerIsolate(SendPort bootstrapPort) {
  final inbox = ReceivePort();
  LokiClient? client;
  Future<void> requests = Future<void>.value();
  final pendingMessages = <Map<String, dynamic>>[];
  var initialized = false;
  bootstrapPort.send(inbox.sendPort);

  void enqueue(Map<String, dynamic> message) {
    requests = requests.then((_) async {
      final replyTo = message['replyTo'] as SendPort?;
      try {
        switch (message['type'] as String) {
          case 'init':
            client = LokiClient(config: message['config'] as LokiConfig);
            await client!.init();
            initialized = true;
            for (final pending in pendingMessages) {
              enqueue(pending);
            }
            pendingMessages.clear();
          case 'log':
            client!.log(
              level: message['level'] as String,
              message: message['message'] as String,
              error: message['error'] as String?,
              stackTrace: message['stackTrace'] == null
                  ? null
                  : StackTrace.fromString(message['stackTrace'] as String),
              time: message['time'] as DateTime,
              loggerName: message['loggerName'] as String?,
              customLabels:
                  (message['customLabels'] as Map?)?.cast<String, String>(),
            );
          case 'addLabels':
            client?.addLabels(
              (message['labels'] as Map).cast<String, String>(),
            );
          case 'removeLabel':
            client?.removeLabel(message['key'] as String);
          case 'resetLabels':
            client?.resetLabels();
          case 'close':
            await client?.close();
            client = null;
            replyTo?.send({'ok': true});
            inbox.close();
            return;
          default:
            throw StateError('Unknown logger isolate message type.');
        }
        replyTo?.send({'ok': true});
      } catch (error, stackTrace) {
        if (replyTo != null) {
          replyTo.send({
            'ok': false,
            'error': error.toString(),
            'stackTrace': stackTrace.toString(),
          });
        } else {
          ConsoleOutput().output(
            PrettyPrinter().log(
              LogEvent(
                level: Level.error,
                message: 'Logger isolate request failed: $error',
                stackTrace: stackTrace,
              ),
            ),
          );
        }
      }
    });
  }

  inbox.listen((dynamic rawMessage) {
    final message = Map<String, dynamic>.from(rawMessage as Map);
    if (!initialized &&
        message['type'] != 'init' &&
        message['type'] != 'close') {
      pendingMessages.add(message);
      return;
    }
    enqueue(message);
  });
}
