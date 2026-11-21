// Hook implementations for the multiple-accounts module.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'account_store.dart';
import 'account_switcher.dart';

/// Settings → Account → "Switch or add account".
List<Widget> accountsSettingsRows(
  BuildContext context,
  SettingsHookContext ctx,
) {
  return [
    ListenableBuilder(
      listenable: AccountStore.instance,
      builder: (context, _) {
        final count = AccountStore.instance.slots
            .where((s) => !s.pending)
            .length;
        return ListTile(
          key: const ValueKey('accounts-switch-row'),
          leading: const Icon(Icons.switch_account_outlined),
          title: const Text('Switch or add account'),
          subtitle: Text(
            count <= 1
                ? 'Sign in to another Matrix account'
                : '$count accounts on this device',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showAccountSwitcher(context, ctx.palette),
        );
      },
    ),
  ];
}
