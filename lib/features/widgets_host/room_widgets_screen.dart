import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'widget_web_view_screen.dart';
import 'widgets_host.dart';

/// Room details → Apps & widgets: list, add, remove and open Matrix widgets.
class RoomWidgetsScreen extends StatefulWidget {
  const RoomWidgetsScreen({
    super.key,
    required this.backend,
    required this.roomId,
    required this.roomName,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final String roomId;
  final String roomName;
  final AppPalette palette;
  final WidgetsFeatures features;

  @override
  State<RoomWidgetsScreen> createState() => _RoomWidgetsScreenState();
}

class _RoomWidgetsScreenState extends State<RoomWidgetsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_changed);
  }

  @override
  void dispose() {
    widget.backend.removeListener(_changed);
    _owner.release();
    super.dispose();
  }

  void _changed() {
    if (mounted && _owner.isCurrent) setState(() {});
  }

  Future<void> _add() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    var personal = false;
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Add widget'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('widget-name'),
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('widget-url'),
                controller: urlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'HTTPS URL',
                  hintText: 'https://example.com/widget',
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: personal,
                title: const Text('Only for me'),
                subtitle: const Text(
                  'Otherwise added for everyone in the room',
                ),
                onChanged: (value) => setDialogState(() => personal = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('widget-add-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (added != true || !mounted) return;
    final url = parseWidgetUrl(urlController.text);
    final name = nameController.text.trim();
    if (url == null || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a name and a valid HTTPS URL.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final id = 'parallax_${DateTime.now().millisecondsSinceEpoch}';
      if (personal) {
        await widget.features.addPersonalWidget(id: id, name: name, url: url);
      } else {
        await widget.features.addRoomWidget(
          widget.roomId,
          id: id,
          name: name,
          url: url,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t add the widget. Check your permissions.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(MatrixWidget w) async {
    setState(() => _busy = true);
    try {
      if (w.personal) {
        await widget.features.removePersonalWidget(w.id);
      } else {
        await widget.features.removeRoomWidget(widget.roomId, w.id);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t remove the widget.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(MatrixWidget w) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => WidgetWebViewScreen(
          backend: widget.backend,
          widget: w,
          palette: widget.palette,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final roomWidgets = widget.features.roomWidgets(widget.roomId);
    final personal = widget.features.personalWidgets();
    final all = [...roomWidgets, ...personal];
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Apps & widgets'),
        backgroundColor: p.background,
        actions: [
          IconButton(
            key: const ValueKey('widget-add'),
            tooltip: 'Add widget',
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: all.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No widgets yet.\nAdd an integration or custom widget with the + button.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                for (final w in all)
                  Card(
                    key: ValueKey('widget-${w.id}'),
                    color: p.surface,
                    margin: const EdgeInsets.only(bottom: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: p.stroke),
                    ),
                    child: ListTile(
                      leading: Icon(
                        w.personal
                            ? Icons.person_outline
                            : Icons.widgets_outlined,
                        color: p.secondary,
                      ),
                      title: Text(
                        w.name,
                        style: TextStyle(color: p.foreground),
                      ),
                      subtitle: Text(
                        '${w.url.host}${w.personal ? ' · only for me' : ''}',
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                      onTap: () => _open(w),
                      trailing: IconButton(
                        key: ValueKey('widget-remove-${w.id}'),
                        icon: Icon(Icons.delete_outline, color: p.muted),
                        onPressed: _busy ? null : () => _remove(w),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
