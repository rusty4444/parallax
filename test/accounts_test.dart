import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/accounts/account_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default slot keeps original storage names', () {
    const slot = AccountSlot(id: AccountStore.defaultSlotId);
    expect(slot.databaseFileName, 'parallax.db');
    expect(slot.clientName, 'Parallax');
    expect(slot.isDefault, isTrue);
  });

  test('added slots get isolated storage names', () {
    const slot = AccountSlot(id: 'acct_123');
    expect(slot.databaseFileName, 'parallax_acct_acct_123.db');
    expect(slot.clientName, 'Parallax:acct_123');
    expect(slot.isDefault, isFalse);
  });

  test('add, register, switch and remove accounts', () async {
    final store = AccountStore.instance;
    await store.load();
    expect(store.activeSlotId, AccountStore.defaultSlotId);

    final id = await store.beginAddAccount();
    expect(store.addingAccount, isTrue);
    expect(store.activeSlotId, id);

    await store.registerActive(
      userId: '@me:example.org',
      homeserver: 'https://example.org',
    );
    expect(store.addingAccount, isFalse);
    expect(store.activeSlot.userId, '@me:example.org');

    await store.setActive(AccountStore.defaultSlotId);
    expect(store.activeSlotId, AccountStore.defaultSlotId);

    await store.removeSlot(id);
    expect(store.slots.any((s) => s.id == id), isFalse);
  });

  test('cancelling add returns to the previous account', () async {
    final store = AccountStore.instance;
    await store.load();
    await store.beginAddAccount();
    expect(store.addingAccount, isTrue);
    await store.cancelAddAccount();
    expect(store.activeSlotId, AccountStore.defaultSlotId);
    expect(store.slots.where((s) => s.pending), isEmpty);
  });

  test('default slot cannot be removed', () async {
    final store = AccountStore.instance;
    await store.load();
    await store.removeSlot(AccountStore.defaultSlotId);
    expect(store.slots.any((s) => s.isDefault), isTrue);
  });
}
