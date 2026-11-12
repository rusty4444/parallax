import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/call/widget_capabilities.dart';

const _user = '@my_user:my_domain.org';
const _device = 'ABCDEFGHI';
const _room = '!room:my_domain.org';

void main() {
  final allowed = elementCallAllowedCapabilities(
    userId: _user,
    deviceId: _device,
    roomId: _room,
  );

  test('allow-list matches the Element X / Rust SDK capability set', () {
    // Assertions copied from matrix-rust-sdk's
    // element_call_permissions_are_correct test.
    for (final capability in [
      'io.element.requires_client',
      'org.matrix.msc4157.update_delayed_event',
      'org.matrix.msc4157.send.delayed_event',
      'org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member',
      'org.matrix.msc2762.receive.state_event:m.room.name',
      'org.matrix.msc2762.receive.state_event:m.room.member',
      'org.matrix.msc2762.receive.state_event:m.room.encryption',
      'org.matrix.msc2762.receive.event:org.matrix.rageshake_request',
      'org.matrix.msc2762.receive.event:io.element.call.encryption_keys',
      'org.matrix.msc2762.receive.state_event:m.room.create',
      'org.matrix.msc2762.receive.state_event:io.element.functional_members',
      'org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member#$_user',
      'org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member#${_user}_$_device',
      'org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member#${_user}_${_device}_m.call',
      'org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member#_${_user}_$_device',
      'org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member#_${_user}_${_device}_m.call',
      'org.matrix.msc2762.send.event:org.matrix.rageshake_request',
      'org.matrix.msc2762.send.event:io.element.call.encryption_keys',
      'org.matrix.msc2762.receive.event:org.matrix.msc4310.rtc.decline',
      'org.matrix.msc2762.send.event:org.matrix.msc4310.rtc.decline',
      'org.matrix.msc2762.send.event:org.matrix.msc4075.rtc.notification',
      'org.matrix.msc3819.send.to_device:io.element.call.encryption_keys',
      'org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys',
    ]) {
      expect(allowed, contains(capability), reason: capability);
    }
  });

  test('nothing lets the widget read messages or impersonate others', () {
    expect(
      allowed.where(
        (c) =>
            c.contains('m.room.message') ||
            c.contains('m.room.encrypted') ||
            c.contains('m.room.power_levels'),
      ),
      isEmpty,
    );
    // Only this user's own membership keys are writable.
    final stateSends = allowed.where(
      (c) => c.startsWith('org.matrix.msc2762.send.state_event:'),
    );
    expect(stateSends.every((c) => c.contains(_user)), isTrue);
    expect(
      allowed,
      isNot(contains('org.matrix.msc2762.send.state_event:m.room.name')),
    );
    expect(allowed, contains(timelineCapability(_room)));
    expect(allowed, isNot(contains(timelineCapability('*'))));
  });

  test('negotiation grants the requested subset only', () {
    final granted = negotiateCapabilities([
      'io.element.requires_client',
      'org.matrix.msc2762.receive.event:m.room.message',
      'org.matrix.msc2762.send.state_event:org.matrix.msc3401.call.member#@evil:x',
      42,
      null,
      'org.matrix.msc4039.download_file',
    ], allowed);
    expect(granted, {'io.element.requires_client'});
  });

  test('approved capabilities follow MSC2762 filter semantics', () {
    final caps = ApprovedCapabilities({
      readStateCapability('m.room.member'),
      readStateCapability('m.room.name', ''),
      sendStateCapability('org.matrix.msc3401.call.member', '_@me:x_D'),
      readEventCapability('m.reaction'),
      sendEventCapability('m.room.message#m.text'),
      readToDeviceCapability(callEncryptionKeysType),
      capSendDelayedEvent,
    });
    expect(caps.canRead('m.room.member', stateKey: '@anyone:x'), isTrue);
    expect(caps.canRead('m.room.name', stateKey: ''), isTrue);
    expect(caps.canRead('m.room.name', stateKey: 'other'), isFalse);
    expect(caps.canRead('m.room.member'), isFalse, reason: 'not a state read');
    expect(caps.canRead('m.reaction'), isTrue);
    expect(
      caps.canSend('org.matrix.msc3401.call.member', stateKey: '_@me:x_D'),
      isTrue,
    );
    expect(
      caps.canSend('org.matrix.msc3401.call.member', stateKey: '_@you:x_D'),
      isFalse,
    );
    expect(caps.canSend('m.room.message', msgtype: 'm.text'), isTrue);
    expect(caps.canSend('m.room.message', msgtype: 'm.notice'), isFalse);
    expect(caps.canReadToDevice(callEncryptionKeysType), isTrue);
    expect(caps.canSendToDevice(callEncryptionKeysType), isFalse);
    expect(caps.canSendDelayed, isTrue);
    expect(caps.canUpdateDelayed, isFalse);
    expect(caps.hasStateReadFilterFor('m.room.name'), isTrue);
    expect(
      caps.stateReadFilters,
      containsAll([
        (type: 'm.room.member', stateKey: null),
        (type: 'm.room.name', stateKey: ''),
      ]),
    );
    expect(caps.readsAnything, isTrue);
    expect(ApprovedCapabilities.none.readsAnything, isFalse);
  });
}
