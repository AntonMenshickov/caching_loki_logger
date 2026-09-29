class EventMessage {
  ///Timestamp in nanoseconds
  final int timestamp;
  final String message;
  final Map<String, String> labels;

  EventMessage({
    required this.timestamp,
    required this.message,
    required this.labels,
  });

  EventMessage clone() => EventMessage(
        timestamp: timestamp,
        message: message,
        labels: labels,
      );

  Map<String, dynamic> toJson() => {
        "timestamp": timestamp,
        "message": message,
        "labels": labels,
      };

  factory EventMessage.fromJson(Map<String, dynamic> json) => EventMessage(
        timestamp: json['timestamp'] as int,
        message: json['message'] as String,
        labels: Map<String, String>.from(json['labels'] as Map? ?? {}),
      );
}
