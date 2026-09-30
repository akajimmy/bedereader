import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../errors.dart';

const errorColour = Color(0xFFFF8A80);

/// An error on a screen: the plain message (lib/errors.dart) and a small Details link that shows the raw error and
/// copies it. Recorded in the error log once, when it first shows (not on every rebuild).
class ErrorText extends StatefulWidget {
  const ErrorText(this.message, this.error, {super.key, this.stack, this.centre = false, this.style, this.action});
  final String message;
  final Object error;
  final StackTrace? stack;
  final bool centre;
  final TextStyle? style;
  final Widget? action; // between the message and Details (Retry)

  @override
  State<ErrorText> createState() => _ErrorTextState();
}

class _ErrorTextState extends State<ErrorText> {
  @override
  void initState() {
    super.initState();
    ErrorLog.instance.record(widget.message, widget.error, widget.stack);
  }

  @override
  void didUpdateWidget(ErrorText old) {
    super.didUpdateWidget(old);
    if (!identical(old.error, widget.error)) ErrorLog.instance.record(widget.message, widget.error, widget.stack);
  }

  @override
  Widget build(BuildContext context) {
    final align = widget.centre ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    return Column(crossAxisAlignment: align, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.message, textAlign: widget.centre ? TextAlign.center : TextAlign.start,
          style: widget.style ?? const TextStyle(color: errorColour)),
      if (widget.action != null) widget.action!,
      DetailsLink(message: widget.message, error: widget.error, stack: widget.stack),
    ]);
  }
}

/// "Details": the raw error, selectable, with Copy.
class DetailsLink extends StatelessWidget {
  const DetailsLink({super.key, required this.message, required this.error, this.stack});
  final String message;
  final Object error;
  final StackTrace? stack;
  @override
  Widget build(BuildContext context) => TextButton(
        style: TextButton.styleFrom(foregroundColor: Colors.white38, textStyle: const TextStyle(fontSize: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
        onPressed: () => showErrorDetails(context, message, error, stack),
        child: const Text('Details'),
      );
}

Future<void> showErrorDetails(BuildContext context, String message, Object error, [StackTrace? stack]) {
  final raw = ['${error.runtimeType}: $error', if (stack != null) stack.toString().split('\n').take(6).join('\n')]
      .join('\n\n');
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Details'),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(message),
          const SizedBox(height: 12),
          SelectableText(raw, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70)),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: '$message\n$raw'));
            Navigator.pop(ctx);
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
          },
          child: const Text('Copy'),
        ),
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

/// A failed action as a pop-up message at the bottom, with Details. Recorded in the error log.
void showErrorSnack(BuildContext context, String message, Object error, [StackTrace? stack]) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    ErrorLog.instance.record(message, error, stack);
    return;
  }
  showErrorOn(messenger, message, error, stack);
}

/// [showErrorSnack] through a messenger taken before an await (the screen may have gone since).
void showErrorOn(ScaffoldMessengerState messenger, String message, Object error, [StackTrace? stack]) {
  ErrorLog.instance.record(message, error, stack);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 6),
    action: SnackBarAction(
      label: 'Details',
      onPressed: () {
        final ctx = messenger.context;
        if (ctx.mounted) showErrorDetails(ctx, message, error, stack);
      },
    ),
  ));
}

/// Settings > About > Error log: the last errors shown, newest first, each with its raw text.
class ErrorLogScreen extends StatelessWidget {
  const ErrorLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final log = ErrorLog.instance;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Error log'), actions: [
          if (log.entries.isNotEmpty) ...[
            IconButton(
              tooltip: 'Copy all',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: log.asText));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
            IconButton(tooltip: 'Clear', icon: const Icon(Icons.delete_outline), onPressed: log.clear),
          ],
        ]),
        body: log.entries.isEmpty
            ? const Center(child: Text('No errors recorded', style: TextStyle(color: Colors.white54)))
            : ListView.separated(
                itemCount: log.entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final e = log.entries[i];
                  final t = e.time;
                  String two(int n) => n.toString().padLeft(2, '0');
                  final when = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
                  return ExpansionTile(
                    title: Text(e.message),
                    subtitle: Text(when, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText([e.detail, if (e.stack != null) e.stack!].join('\n\n'),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70)),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
