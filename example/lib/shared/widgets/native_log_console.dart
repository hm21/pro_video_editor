import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// Live console that displays native logs forwarded through
/// [ProVideoEditor.logStream].
///
/// Demonstrates how a host app can capture renderer diagnostics in Dart. The
/// widget subscribes to [logStream] itself, buffers the most recent entries
/// (capped by [maxEntries]) and renders them color-coded by [NativeLogLevel].
///
/// Emit the rich renderer output by running the operation with
/// `nativeLogLevel: NativeLogLevel.debug` (or higher).
class NativeLogConsole extends StatefulWidget {
  /// Creates a [NativeLogConsole].
  const NativeLogConsole({
    super.key,
    required this.logStream,
    this.maxEntries = 200,
  });

  /// Stream of native log entries to display, e.g.
  /// `ProVideoEditor.instance.logStream`.
  final Stream<NativeLogEntry> logStream;

  /// Caps the in-memory buffer so the console cannot grow unbounded.
  final int maxEntries;

  @override
  State<NativeLogConsole> createState() => _NativeLogConsoleState();
}

class _NativeLogConsoleState extends State<NativeLogConsole> {
  final List<NativeLogEntry> _logs = [];
  StreamSubscription<NativeLogEntry>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(NativeLogConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.logStream != widget.logStream) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _subscription = widget.logStream.listen((entry) {
      if (!mounted) return;
      setState(() {
        _logs.add(entry);
        if (_logs.length > widget.maxEntries) {
          _logs.removeRange(0, _logs.length - widget.maxEntries);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('Native Logs'),
            subtitle: Text('${_logs.length} entries · from logStream'),
            trailing: IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_outline),
              onPressed: _logs.isEmpty ? null : () => setState(_logs.clear),
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: _logs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No native logs yet. Start a render to see entries '
                      'forwarded from the native renderer.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    reverse: true,
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      final entry = _logs[_logs.length - 1 - index];
                      return _NativeLogTile(entry: entry);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// A single row in the [NativeLogConsole].
class _NativeLogTile extends StatelessWidget {
  const _NativeLogTile({required this.entry});

  final NativeLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = _levelColor(entry.level);
    final time = entry.timestamp;
    final stamp = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.level.name.toUpperCase(),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$stamp  ',
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  if (entry.tag != null)
                    TextSpan(
                      text: '${entry.tag}: ',
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  TextSpan(
                    text: entry.message,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _levelColor(NativeLogLevel level) {
    switch (level) {
      case NativeLogLevel.error:
        return Colors.red;
      case NativeLogLevel.warning:
        return Colors.orange;
      case NativeLogLevel.info:
        return Colors.blue;
      case NativeLogLevel.debug:
        return Colors.green;
      case NativeLogLevel.verbose:
        return Colors.grey;
      case NativeLogLevel.none:
        return Colors.grey;
    }
  }
}
