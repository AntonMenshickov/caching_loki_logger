import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

import 'package:loki_logger/loki_logger.dart';
import 'package:loki_logger/src/loki_sender.dart';
import 'package:loki_logger/src/model/event_message.dart';
import 'package:path/path.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

enum CacheStrategy { keepOld, replaceByNew }

class ReliableBatchQueueOptions {
  ///amount of records that can be sent to server in one time
  final int batchSize;

  ///interval when automatically flush logs to server
  final Duration flushInterval;

  ///Directory when events will be stored
  ///for flutter path_provider.getApplicationDocumentsDirectory can be used
  final String storagePath;

  ///Maximum stored records in queue
  final int maxStoredRecords;

  ///Keep old records and stop adding new or remove oldest records
  ///when stored records count reach limit
  final CacheStrategy cacheStrategy;

  const ReliableBatchQueueOptions({
    this.batchSize = 1000,
    this.flushInterval = const Duration(seconds: 10),
    required this.storagePath,
    this.maxStoredRecords = 10000,
    this.cacheStrategy = CacheStrategy.replaceByNew,
  })  : assert(maxStoredRecords > 0, 'Max store records size must be > 0'),
        assert(batchSize > 0, 'Batch size must be > 0'),
        assert(
          !(batchSize > maxStoredRecords),
          'Batch size must be greater than maxStoredRecords',
        );
}

class ReliableBatchQueue {
  static const String _queueStoreName = 'queue_store';
  static const String _processingStoreName = 'processing_store';
  static const int _maxRetryDelaySeconds = 300;

  late final LokiSender _sender;
  late final Database _db;
  late final StoreRef<int, Map> _queueStore;
  late final StoreRef<int, Map> _processingStore;

  final int _batchSize;
  final Duration _flushInterval;
  final String _storagePath;
  final int _maxStoredRecords;
  final CacheStrategy _cacheStrategy;

  int _sequenceKey = 0;
  bool _flushing = false;
  Timer? _flushTimer;

  bool _flushLocked = false;
  int _retryDelay = 0;
  Timer? _retryTimer;

  // Memory buffer for performance optimization
  static const int _bufferSize = 50;
  final List<EventMessage> _memoryBuffer = [];
  bool _bufferFlushInProgress = false;

  ReliableBatchQueue(ReliableBatchQueueOptions options, LokiSender sender)
      : _sender = sender,
        _batchSize = options.batchSize,
        _flushInterval = options.flushInterval,
        _storagePath = options.storagePath,
        _maxStoredRecords = options.maxStoredRecords,
        _cacheStrategy = options.cacheStrategy;

  Future<void> init() async {
    try {
      _db = await databaseFactoryIo.openDatabase(
        join(_storagePath, 'loki_logger.db'),
      );
    } catch (e) {
      ConsoleOutput().output(PrettyPrinter().log(LogEvent(
          level: Level.warning,
          message:
              '[$ReliableBatchQueue] Failed to open database: $e. Recreating...')));
      try {
        final dbPath = join(_storagePath, 'loki_logger.db');
        // Delete corrupted database file
        final file = io.File(dbPath);
        if (await file.exists()) {
          await file.delete();
        }
        // Create fresh database
        _db = await databaseFactoryIo.openDatabase(dbPath);
      } catch (e2) {
        ConsoleOutput().output(PrettyPrinter().log(LogEvent(
            level: Level.error,
            message:
                '[$ReliableBatchQueue] Failed to recreate database: $e2')));
        rethrow;
      }
    }
    _queueStore = intMapStoreFactory.store(_queueStoreName);
    _processingStore = intMapStoreFactory.store(_processingStoreName);
    await _restoreProcessing();
    _flushTimer ??= Timer.periodic(_flushInterval, (_) => _flush());
  }

  Future<void> _restoreProcessing() async {
    try {
      final processingRecords = await _processingStore.find(_db);
      int recoveredCount = 0;

      for (var record in processingRecords) {
        try {
          final queueRecord = await _queueStore.record(record.key).get(_db);
          if (queueRecord == null) {
            await _queueStore.record(record.key).put(_db, record.value);
            recoveredCount++;
          }
        } catch (e) {
          ConsoleOutput().output(PrettyPrinter().log(LogEvent(
              level: Level.warning,
              message:
                  '[$ReliableBatchQueue] Failed to restore record with key ${record.key}: $e')));
        }
      }

      if (recoveredCount > 0) {
        ConsoleOutput().output(PrettyPrinter().log(LogEvent(
            level: Level.debug,
            message:
                '[$ReliableBatchQueue] Recovered $recoveredCount records from processing store')));
      }

      try {
        await _processingStore.delete(_db);
      } catch (e) {
        ConsoleOutput().output(PrettyPrinter().log(LogEvent(
            level: Level.warning,
            message:
                '[$ReliableBatchQueue] Failed to clear processing store: $e')));
      }

      final queueRecords = await _queueStore.find(_db);
      if (queueRecords.isNotEmpty) {
        _sequenceKey = queueRecords.map((r) => r.key).reduce(max);
      } else {
        _sequenceKey = 0;
      }

      if (queueRecords.isNotEmpty || processingRecords.isNotEmpty) {
        await _flush();
      }
    } catch (e) {
      ConsoleOutput().output(PrettyPrinter().log(LogEvent(
          level: Level.error,
          message: '[$ReliableBatchQueue] Error during recovery: $e')));
      rethrow;
    }
  }

  Future<void> addEvent(EventMessage event) async {
    _memoryBuffer.add(event);
    if (_memoryBuffer.length >= _bufferSize) {
      await _flushBufferToDB();
    }
    await _processQueue();
  }

  Future<void> _flushBufferToDB() async {
    // Prevent concurrent buffer flushes
    if (_bufferFlushInProgress || _memoryBuffer.isEmpty) {
      return;
    }

    _bufferFlushInProgress = true;

    try {
      final buffer = List<EventMessage>.from(_memoryBuffer);
      _memoryBuffer.clear();

      await _db.transaction((txn) async {
        final queueRecords = await _queueStore.find(txn);
        int currentQueueSize = queueRecords.length;

        for (var event in buffer) {
          // Check if we've exceeded max records
          if (currentQueueSize >= _maxStoredRecords) {
            switch (_cacheStrategy) {
              case CacheStrategy.keepOld:
                continue; // Skip this event
              case CacheStrategy.replaceByNew:
                // Delete oldest record
                final keys = queueRecords.map((r) => r.key).toList();
                if (keys.isNotEmpty) {
                  final oldestKey = keys.reduce(min);
                  await _queueStore.record(oldestKey).delete(txn);
                  queueRecords.removeWhere((record) => record.key == oldestKey);
                  currentQueueSize--;
                }
            }
          }

          _sequenceKey++;
          await _queueStore.record(_sequenceKey).put(txn, event.toJson());
          currentQueueSize++;
        }
      });
    } finally {
      _bufferFlushInProgress = false;
    }
  }

  Future<void> _processQueue() async {
    final queueRecords = await _queueStore.find(_db);
    final totalSize = _memoryBuffer.length + queueRecords.length;
    if (totalSize >= _batchSize) {
      await _flush();
    }
  }

  Future<Iterable<EventMessage>> _prepareBatch() async {
    // Flush memory buffer to DB first
    await _flushBufferToDB();

    final List<EventMessage> events = [];
    final processingRecords = await _processingStore.find(_db);

    if (processingRecords.isNotEmpty) {
      events.addAll(processingRecords
          .map((r) => EventMessage.fromJson(Map<String, dynamic>.from(r.value)))
          .toList());
    } else {
      final queueRecords = await _queueStore.find(_db);
      final List<int> keys = (queueRecords.map((r) => r.key).toList()
            ..sort((a, b) => a.compareTo(b)))
          .take(_batchSize)
          .toList();

      await _db.transaction((txn) async {
        for (int key in keys) {
          final queueRecord = await _queueStore.record(key).get(txn);
          if (queueRecord != null) {
            await _processingStore.record(key).put(txn, queueRecord);
            await _queueStore.record(key).delete(txn);
          }
        }
      });

      final updatedProcessingRecords = await _processingStore.find(_db);
      events.addAll(updatedProcessingRecords
          .map((r) => EventMessage.fromJson(Map<String, dynamic>.from(r.value)))
          .toList());
    }
    return events;
  }

  void _startRetryTimer() {
    _retryTimer?.cancel();
    _retryDelay = min(max(_retryDelay * 2, 1), _maxRetryDelaySeconds);
    _flushLocked = true;
    ConsoleOutput().output(PrettyPrinter().log(LogEvent(
        level: Level.debug,
        message:
            '[$ReliableBatchQueue] Scheduled flush retry in $_retryDelay seconds')));

    _retryTimer = Timer(Duration(seconds: _retryDelay), () {
      _flushLocked = false;
      _retryTimer = null;
      _flush();
    });
  }

  Future<void> _flush() async {
    if (_flushing || _flushLocked) return;
    _flushing = true;

    try {
      final Iterable<EventMessage> batch = await _prepareBatch();

      if (batch.isEmpty) {
        _flushing = false;
        return;
      }
      await _sender.sendBatch(batch).timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Batch send timeout'),
          );
      await _processingStore.delete(_db);
      _retryDelay = 0;
      _flushing = false;
      await _processQueue();
    } catch (err) {
      ConsoleOutput().output(PrettyPrinter().log(LogEvent(
          level: Level.error,
          message: '[$ReliableBatchQueue] Failed to flush messages\n$err')));
      _flushing = false;
      _startRetryTimer();
    }
  }

  /// Flushes any remaining events in memory buffer to database and ensures pending batches are sent
  Future<void> close() async {
    _flushTimer?.cancel();
    _retryTimer?.cancel();
    // Flush any remaining events in memory buffer
    await _flushBufferToDB();
    // Send any pending batches
    try {
      await _flush();
    } catch (e) {
      ConsoleOutput().output(PrettyPrinter().log(LogEvent(
          level: Level.error,
          message: '[$ReliableBatchQueue] Error during final flush: $e')));
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    await _db.close();
  }
}
