import 'package:flutter/material.dart';

import '../pins.dart';
import 'setting_rows.dart' show RowNav;

/// The order of Home's pins (user, 2026-10-28: "reorder pins" - a sheet as Arrange sections): ▲▼ buttons
/// (remote-friendly) and a drag handle (touch), one row per pin. Komga's pins keep their order on every device; this
/// device's own (local libraries) keep their place among them here.
class PinsEditor extends StatelessWidget {
  const PinsEditor({super.key});

  @override
  Widget build(BuildContext context) {
    final pins = Pins.instance;
    return ListenableBuilder(
      listenable: pins,
      builder: (context, _) {
        final items = pins.items;
        if (items.isEmpty) {
          return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Nothing pinned yet'));
        }
        return ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: pins.reorder,
          children: [
            for (var i = 0; i < items.length; i++)
              RowNav(key: ObjectKey(items[i]), child: Row(children: [
                Icon(_icon(items[i]), size: 20, color: const Color(0xFF8A8A8A)),
                const SizedBox(width: 12),
                Expanded(child: Text(items[i].name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                // at the ends they stay focusable, dimmed (a disabled button with the remote's focus drops it - as
                // Arrange sections, code review 2026-10-05, #26)
                IconButton(
                  tooltip: 'Move ${items[i].name} up',
                  icon: Icon(Icons.keyboard_arrow_up, color: i == 0 ? _dim : null),
                  onPressed: () => pins.move(items[i], -1),
                ),
                IconButton(
                  tooltip: 'Move ${items[i].name} down',
                  icon: Icon(Icons.keyboard_arrow_down, color: i == items.length - 1 ? _dim : null),
                  onPressed: () => pins.move(items[i], 1),
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle, color: Color(0xFF8A8A8A))),
                ),
              ])),
          ],
        );
      },
    );
  }

  static IconData _icon(Pin p) => switch (p.kind) {
        'book' => Icons.menu_book_outlined,
        'series' => Icons.collections_bookmark_outlined,
        'readlist' => Icons.format_list_numbered,
        'collection' => Icons.folder_copy_outlined,
        _ => Icons.local_library_outlined,
      };
}

const _dim = Color(0xFF5A5A5A); // an arrow that can't move its pin any further

/// Home's ⋮ > Arrange pins…, and a pin's dialog's Arrange.
Future<void> showPinsEditor(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141416),
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Expanded(child: Text('Pins', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500))),
                TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
              ]),
              const PinsEditor(),
            ]),
          ),
        ),
      ),
    );
