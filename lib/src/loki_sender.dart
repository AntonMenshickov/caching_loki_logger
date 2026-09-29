import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:loki_logger/src/model/event_message.dart';

import 'log_event.dart';
import 'log_level.dart';
import 'log_output.dart';
import 'log_printer.dart';
import 'loki_config.dart';

class LokiSender {
  /// Configuration for the logger to connect to Loki Server
  final LokiConfig config;

  LokiSender({required this.config});

  /// Sends a batch of logs to Loki
  Future<void> sendBatch(Iterable<EventMessage> messages) async {
    if (messages.isEmpty) return;

    final batch = List<Map<String, dynamic>>.from(messages.map((e) => e.toJson()));

    await _sendLogs(batch);
  }

  /// Sends logs to Loki server
  Future<void> _sendLogs(List<Map<String, dynamic>> logs) async {
    if (logs.isEmpty) return;

    try {
      // Prepare streams for Loki API
      final streams = logs.fold<Map<String, List<List<String>>>>({}, (
        map,
        log,
      ) {
        final Map<String, String> labelsMap = log['labels'];
        final String labels = labelsMap.entries.map((e) => '${e.key}="${e.value}"').join(',');
        final entry = <String>[log['timestamp'].toString(), log['message']];

        if (!map.containsKey(labels)) {
          map[labels] = [];
        }
        map[labels]!.add(entry);
        return map;
      });

      // Format for Loki API
      final streamsData = streams.entries.map((entry) {
        // Parse the label string into a proper Map
        final labelStr = entry.key.substring(
          0,
          entry.key.length,
        ); // Remove the surrounding braces
        final labelPairs = labelStr.split(',');
        final labelMap = <String, String>{};

        for (final pair in labelPairs) {
          final parts = pair.split('=');
          if (parts.length == 2) {
            // Extract key and value, removing quotes
            final key = parts[0].trim();
            final value = parts[1].trim();
            // Remove surrounding quotes from value
            final cleanValue = value.startsWith('"') && value.endsWith('"')
                ? value.substring(1, value.length - 1)
                : value;
            labelMap[key] = cleanValue;
          }
        }

        return {'stream': labelMap, 'values': entry.value};
      }).toList();

      final payload = {'streams': streamsData};

      // Prepare request
      final headers = <String, String>{'Content-Type': 'application/json'};

      // Authentication headers
      if (config.bearerToken != null) {
        headers['Authorization'] = 'Bearer ${config.bearerToken}';
      }
      if (config.basicAuth != null) {
        final encodedAuth = base64Encode(utf8.encode(config.basicAuth!));
        headers['Authorization'] = 'Basic $encodedAuth';
      }

      // Send to Loki
      final uri = Uri.parse('${config.host}/loki/api/v1/push');
      final response = await http
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(Duration(milliseconds: config.timeout ?? 30000));
      if (response.statusCode >= 400) {
        _printError('LokiLogger: Error sending logs: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      _printError('LokiLogger: Error sending logs: $e');
      rethrow;
    }
  }

  void _printError(String error) {
    ConsoleOutput().output(PrettyPrinter().log(LogEvent(level: Level.error, message: error)));
  }
}
