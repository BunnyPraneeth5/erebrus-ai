enum ToolActivityStatus { running, done, failed }

/// One tool step shown under an assistant message ("Searched the web for …").
class ToolActivity {
  ToolActivity({
    required this.id,
    required this.name,
    required this.label,
    this.status = ToolActivityStatus.running,
    this.summary = '',
  });

  final String id;
  final String name;
  String label;
  ToolActivityStatus status;
  String summary;

  factory ToolActivity.fromJson(Map<String, dynamic> json) => ToolActivity(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    label: json['label'] as String? ?? '',
    status: ToolActivityStatus.values
            .where((value) => value.name == json['status'])
            .firstOrNull ??
        ToolActivityStatus.done,
    summary: json['summary'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'label': label,
    // A step still "running" when persisted was interrupted.
    'status': status == ToolActivityStatus.running
        ? ToolActivityStatus.failed.name
        : status.name,
    if (summary.isNotEmpty) 'summary': summary,
  };
}
