import 'package:loki_logger/loki_logger.dart';

const host = 'https://loki.smartdata.dev';
const username = 'example';
const password = 'example';

void main() async {
  // Setup the LokiLogger with our new Logger implementation
  final logger = LokiLogger(
    filter: LevelFilter(Level.trace),
    config: const LokiConfig(
      host: host,
      batchQueueOptions: ReliableBatchQueueOptions(
        storagePath: './',
      ),
      // Replace with your Loki server URL
      labels: {
        'app': 'flutter_test_app',
        'tag': 'Onboarding',
        'env': 'dev',
        'version': '1.0.0',
        'user': 'John Doe',
        'device': 'iPhone',
        'os': 'iOS',
        'os_version': '14.5',
      },
      // basicAuth: "$username:$password",
    ),
    // Basic authentication credentials
    name: 'TestApp', // Name for this logger instance
    // Optional: customize the printer
    printer: PrettyPrinter(
      methodCount: 2,
      // Number of method calls to be displayed
      errorMethodCount: 8,
      // Number of method calls if stacktrace is provided
      lineLength: 120,
      // Width of the output
      colors: true,
      // Colorful log messages
      printEmojis: true,
      // Print an emoji for each log message
      printTime: true, // Include timestamp in logs
    ),
  );

  await logger.init();

  // Log messages at different levels using the convenient shorthand methods
  logger.d('This is a debug message');
  logger.i('Application started');
  logger.w('Something might be wrong');

  try {
    // Simulate an error
    throw Exception('Something went wrong');
  } catch (e, stackTrace) {
    // Log the error with stack trace
    logger.e('Oops😳 an error occurred', e, stackTrace, {
      'sessionId': '9999990-09099439-2983727328',
    });
  }

  logger.addLabels({
    'user': 'John Doe',
    'device': 'iPhone',
    'os': 'iOS',
    'os_version': '14.5',
  });
  logger.f('Fatal error occurred, this should carry new labels');
  logger.i('Just for you info here');
  logger.removeLabel('user');
  logger.i('Just for you info here');
  logger.resetLabels();
  logger.i('Now labels are reset');
  logger.i('Now labels are reset 22');

  // Dispose the logger to free up resources
  logger.dispose();
}
