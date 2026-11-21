import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'account_store.dart';

/// Bottom sheet to switch between accounts, add a new one, or remove one.
Future<void> showAccountSwitcher(BuildContext context, AppPalette palette) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: palette.background,
    builder: (_) => const _AccountSwitcherSheet(),
  );
}

class _AccountSwitcherSheet extends StatelessWidget {
  const _AccountSwitcherSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AccountStore.instance,
      builder: (context, _) {
        final store = AccountStore.instance;
        final slots = store.slots.where((s) => !s.pending).toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Accounts',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                for (final slot in slots)
                  ListTile(
                    key: ValueKey('account-slot-${slot.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(
                        slot.displayName.characters.first.toUpperCase(),
                      ),
                    ),
                    title: Text(slot.displayName),
                    subtitle: slot.userId == null ? null : Text(slot.userId!),
                    trailing: slot.id == store.activeSlotId
                        ? const Icon(Icons.check_circle_rounded)
                        : (slot.isDefault
                              ? null
                              : IconButton(
                                  key: ValueKey('account-remove-${slot.id}'),
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    await store.removeSlot(slot.id);
                                  },
                                )),
                    onTap: () async {
                      await store.setActive(slot.id);
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('account-add'),
                  onPressed: () async {
                    await store.beginAddAccount();
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.person_add_alt_rounded),
                  label: const Text('Add account'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
