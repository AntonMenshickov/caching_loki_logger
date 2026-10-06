import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:loki_logger/loki_logger.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

@GenerateMocks([LogOutput, LogFilter, LokiClient])
import 'logger_test.mocks.dart';

void main() {
  group('LokiLogger', () {
    late MockLogOutput mockOutput;
    late MockLogFilter mockFilter;
    late LokiLogger logger;

    setUp(() {
      mockOutput = MockLogOutput();
      mockFilter = MockLogFilter();
      logger = LokiLogger(
        name: 'TestLogger',
        filter: mockFilter,
        output: mockOutput,
      );
    });

    test('should not log when filter returns false', () {
      // Arrange
      when(mockFilter.shouldLog(any)).thenReturn(false);

      // Act
      logger.d('Test message');

      // Assert
      verifyNever(mockOutput.output(any));
    });

    test('should log when filter returns true', () {
      // Arrange
      when(mockFilter.shouldLog(any)).thenReturn(true);

      // Act
      logger.d('Test message');

      // Assert
      verify(mockOutput.output(any)).called(1);
    });

    test('should log with correct level', () {
      // Arrange
      when(mockFilter.shouldLog(any)).thenReturn(true);

      // Act
      logger.d('Debug message');
      logger.i('Info message');
      logger.w('Warning message');
      logger.e('Error message');
      logger.f('Fatal message');

      // Assert
      verify(mockOutput.output(any)).called(5);

      // Capture the log event to verify level
      final logEventCaptor = verify(mockFilter.shouldLog(captureAny)).captured;
      expect(logEventCaptor[0].level, equals(Level.debug));
      expect(logEventCaptor[1].level, equals(Level.info));
      expect(logEventCaptor[2].level, equals(Level.warning));
      expect(logEventCaptor[3].level, equals(Level.error));
      expect(logEventCaptor[4].level, equals(Level.fatal));
    });

    test('should include error and stack trace in log event', () {
      // Arrange
      when(mockFilter.shouldLog(any)).thenReturn(true);
      final error = Exception('Test error');
      final stackTrace = StackTrace.current;

      // Act
      logger.e('Error occurred', error, stackTrace);

      // Assert
      final logEventCaptor =
          verify(mockFilter.shouldLog(captureAny)).captured.single;
      expect(logEventCaptor.error, equals(error));
      expect(logEventCaptor.stackTrace, equals(stackTrace));
    });

    test('should include custom labels in log event', () {
      // Arrange
      when(mockFilter.shouldLog(any)).thenReturn(true);
      final customLabels = {'key1': 'value1', 'key2': 'value2'};

      // Act
      logger.i('Info with labels', null, null, customLabels);

      // Assert
      final logEventCaptor =
          verify(mockFilter.shouldLog(captureAny)).captured.single;
      expect(logEventCaptor.customLabels, equals(customLabels));
    });

    test('should use LokiClient when config is provided', () async {
      when(mockFilter.shouldLog(any)).thenReturn(true);
      const config = LokiConfig(
        host: 'http://localhost:3100',
        batchQueueOptions: ReliableBatchQueueOptions(
          storagePath: './',
        ),
      );
      final loggerWithConfig = LokiLogger(
        name: 'LoggerWithConfig',
        filter: mockFilter,
        output: mockOutput,
        config: config,
      );

      await loggerWithConfig.init();

      // Just verify it doesn't throw an exception
      expect(() => loggerWithConfig.i('Test with config'), returnsNormally);
    });

    test('should add labels through logger', () async {
      when(mockFilter.shouldLog(any)).thenReturn(true);
      const config = LokiConfig(
        host: 'http://localhost:3100',
        batchQueueOptions: ReliableBatchQueueOptions(
          storagePath: './',
        ),
      );
      final loggerWithConfig = LokiLogger(
        name: 'LoggerWithConfig',
        filter: mockFilter,
        output: mockOutput,
        config: config,
      );

      await loggerWithConfig.init();

      // Should not throw when adding labels
      expect(
        () => loggerWithConfig.addLabels({'key': 'value'}),
        returnsNormally,
      );
    });

    test('should remove label through logger', () async {
      when(mockFilter.shouldLog(any)).thenReturn(true);
      const config = LokiConfig(
        host: 'http://localhost:3100',
        batchQueueOptions: ReliableBatchQueueOptions(
          storagePath: './',
        ),
      );
      final loggerWithConfig = LokiLogger(
        name: 'LoggerWithConfig',
        filter: mockFilter,
        output: mockOutput,
        config: config,
      );

      await loggerWithConfig.init();

      // Should not throw when removing labels
      expect(() => loggerWithConfig.removeLabel('key'), returnsNormally);
    });

    test('should reset labels through logger', () async {
      when(mockFilter.shouldLog(any)).thenReturn(true);
      const config = LokiConfig(
        host: 'http://localhost:3100',
        batchQueueOptions: ReliableBatchQueueOptions(
          storagePath: './',
        ),
      );
      final loggerWithConfig = LokiLogger(
        name: 'LoggerWithConfig',
        filter: mockFilter,
        output: mockOutput,
        config: config,
      );

      await loggerWithConfig.init();

      // Should not throw when resetting labels
      expect(() => loggerWithConfig.resetLabels(), returnsNormally);
    });

    test('should handle label operations when lokiClient is null', () {
      // Logger without config (no lokiClient)
      expect(() => logger.addLabels({'key': 'value'}), returnsNormally);
      expect(() => logger.removeLabel('key'), returnsNormally);
      expect(() => logger.resetLabels(), returnsNormally);
    });
  });

  group('LevelFilter', () {
    test('should filter based on level', () {
      final infoFilter = LevelFilter(Level.info);

      final traceEvent = LogEvent(level: Level.trace, message: 'Trace');
      final debugEvent = LogEvent(level: Level.debug, message: 'Debug');
      final infoEvent = LogEvent(level: Level.info, message: 'Info');
      final warningEvent = LogEvent(level: Level.warning, message: 'Warning');
      final errorEvent = LogEvent(level: Level.error, message: 'Error');

      expect(infoFilter.shouldLog(traceEvent), isFalse);
      expect(infoFilter.shouldLog(debugEvent), isFalse);
      expect(infoFilter.shouldLog(infoEvent), isTrue);
      expect(infoFilter.shouldLog(warningEvent), isTrue);
      expect(infoFilter.shouldLog(errorEvent), isTrue);
    });
  });

  group('multi-threaded LokiLogger', () {
    test('reuses a logger isolate registered by another logger', () async {
      final nameServer = _TestIsolateNameServer();
      final tempDirectory = await Directory.systemTemp.createTemp(
        'loki_logger_isolate_',
      );
      final config = LokiConfig(
        host: 'http://localhost:3100',
        batchQueueOptions: ReliableBatchQueueOptions(
          storagePath: tempDirectory.path,
        ),
      );
      final logger = LokiLogger(
        multiThreaded: true,
        isolateNameServer: nameServer,
        config: config,
      );
      final secondLogger = LokiLogger(
        multiThreaded: true,
        isolateNameServer: nameServer,
        config: config,
      );

      try {
        await logger.init();
        await secondLogger.init();

        expect(secondLogger.sendPort, same(logger.sendPort));
      } finally {
        await logger.close();
        await tempDirectory.delete(recursive: true);
      }
    });

    test('routes connected logger facades through the same isolate', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final tempDirectory = await Directory.systemTemp.createTemp(
        'loki_logger_isolate_',
      );
      final request = server.first.then((request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return jsonDecode(body) as Map<String, dynamic>;
      });
      final logger = LokiLogger(
        multiThreaded: true,
        config: LokiConfig(
          host: 'http://${server.address.address}:${server.port}',
          batchQueueOptions: ReliableBatchQueueOptions(
            storagePath: tempDirectory.path,
            batchSize: 1,
            flushInterval: const Duration(hours: 1),
          ),
        ),
      );

      try {
        await logger.init();
        final connectedLogger = LokiLogger.connect(
          logger.sendPort!,
          name: 'background-worker',
          filter: LevelFilter(Level.trace),
          printer: SimplePrinter(),
          output: _NoopOutput(),
        );
        connectedLogger.addLabels({'worker': 'workmanager'});
        connectedLogger.i('message from background isolate');

        final payload = await request.timeout(const Duration(seconds: 5));
        final streams = payload['streams'] as List<dynamic>;
        final labels = streams.single['stream'] as Map<String, dynamic>;

        expect(labels['worker'], 'workmanager');
        expect(labels['logger'], 'background-worker');
        expect(
          streams.single['values'].single[1],
          'message from background isolate',
        );
      } finally {
        await logger.close();
        await server.close(force: true);
        await tempDirectory.delete(recursive: true);
      }
    });
  });
}

class _NoopOutput extends LogOutput {
  @override
  void output(List<String> lines) {}
}

class _TestIsolateNameServer implements LokiIsolateNameServer {
  final Map<String, SendPort> _ports = {};

  @override
  SendPort? lookupPortByName(String name) => _ports[name];

  @override
  bool registerPortWithName(SendPort port, String name) {
    if (_ports.containsKey(name)) return false;
    _ports[name] = port;
    return true;
  }

  @override
  bool removePortNameMapping(String name) => _ports.remove(name) != null;
}
