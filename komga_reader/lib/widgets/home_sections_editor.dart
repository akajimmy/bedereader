import 'package:flutter/material.dart';

import '../home_sections.dart';
import 'setting_rows.dart' show RowNav;

/// Show/hide and order Home's sections: a switch per section, ▲▼ buttons (remote-friendly) and a drag handle
/// (touch). Used in Settings and in the sheet from Home's ⋮ menu (Arrange sections…).
class HomeSectionsEditor extends StatelessWidget {
  const HomeSectionsEditor({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = HomeSections.instance;
    return ListenableBuilder(
      listenable: sections,
      builder: (context, _) {
        final order = sections.order;
        return ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: sections.reorder,
          children: [
            for (var i = 0; i < order.length; i++)
              RowNav(key: ValueKey(order[i]), child: Row(children: [ // one row per section for Up / Down
                Switch(value: sections[order[i]], onChanged: (v) => sections.set(order[i], v)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(HomeSections.names[order[i]]!,
                      style: TextStyle(color: sections[order[i]] ? null : const Color(0xFF8A8A8A))),
                ),
                // at the ends they do nothing but stay focusable, dimmed: a disabled button with the remote's focus
                // drops it - moved to the top with ▲, the focus was gone (code review 2026-10-05, #26)
                IconButton(
                  tooltip: 'Move ${HomeSections.names[order[i]]} up',
                  icon: Icon(Icons.keyboard_arrow_up, color: i == 0 ? _dim : null),
                  onPressed: () { if (i > 0) sections.move(order[i], -1); },
                ),
                IconButton(
                  tooltip: 'Move ${HomeSections.names[order[i]]} down',
                  icon: Icon(Icons.keyboard_arrow_down, color: i == order.length - 1 ? _dim : null),
                  onPressed: () { if (i < order.length - 1) sections.move(order[i], 1); },
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
}

const _dim = Color(0xFF5A5A5A); // an arrow that can't move its section any further

/// Home's ⋮ > Arrange sections…
Future<void> showHomeSectionsEditor(BuildContext context) => showModalBottomSheet<void>(
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
                const Expanded(child: Text('Home sections', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500))),
                TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
              ]),
              const HomeSectionsEditor(),
            ]),
          ),
        ),
      ),
    );
