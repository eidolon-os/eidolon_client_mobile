import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/device_management/device_companion_setup.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:eidolon_client_mobile/src/management/companion_creation_checkpoint.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

MountedDevice device(
        {String? companion = 'old',
        int revision = 1,
        OutputSelection? allowed,
        InputSelection? inputs,
        int outputRevision = 0,
        String state = 'awaiting_outputs'}) =>
    MountedDevice(
        deviceId: 'device',
        label: '桌面伙伴',
        detail: '',
        state: state == 'access_revoked'
            ? MountedDeviceState.accessRevoked
            : MountedDeviceState.awaitingOutputs,
        attachedCompanionId: companion,
        attachedCompanionName: companion ?? '',
        quietBecause: DeviceQuietBecause.unstated,
        revision: revision,
        mountRevision: 1,
        updatedAt: null,
        claimState: 'active',
        claimGeneration: 1,
        trustEpoch: 1,
        ownerDomainGeneration: 1,
        manifestId: 'm',
        outputs: DeviceOutputs(
            capabilities: const OutputSelection(speech: true, expression: true),
            allowed: allowed,
            inputs: inputs,
            revision: outputRevision));
DeviceCompanionSetupStore store(AppPreferences prefs,
        {String host = 'h', String owner = 'o', String target = 'device'}) =>
    DeviceCompanionSetupStore(
        hostId: host,
        controllerId: 'c',
        ownerId: owner,
        deviceId: target,
        preferences: prefs);
const intent = CompanionSetupIntent(
    step: CompanionSetupStep.binding,
    requestId: 'same-operation',
    expectedRevision: 1,
    companionId: 'new',
    companionName: '新伙伴');
void main() {
  test(
      'restart isolates authorities and refuses replacing an unresolved decision',
      () async {
    final prefs = InMemoryAppPreferences();
    await store(prefs).save(intent);
    expect((await store(prefs).load())!.requestId, 'same-operation');
    expect(await store(prefs, owner: 'other').load(), isNull);
    expect(await store(prefs, host: 'other').load(), isNull);
    expect(await store(prefs, target: 'other').load(), isNull);
    await expectLater(
        store(prefs).save(const CompanionSetupIntent(
            step: CompanionSetupStep.binding,
            requestId: 'other',
            expectedRevision: 1)),
        throwsA(isA<CompanionSetupException>()));
  });
  test(
      'binding committed with lost response resumes by reading, without a second write',
      () async {
    final prefs = InMemoryAppPreferences();
    var current = device();
    var writes = 0;
    await store(prefs).save(intent);
    DeviceCompanionSetup flow() => DeviceCompanionSetup(
        store: store(prefs),
        loadDevice: () async => current,
        bind: (i) async {
          writes++;
          expect(i.requestId, 'same-operation');
          current = device(companion: 'new', revision: 2);
          throw TimeoutException('lost response');
        },
        setOutputs: (_, __, ___) async => fail('not yet authorized'));
    await expectLater(
        flow().finishBinding(intent), throwsA(isA<TimeoutException>()));
    await flow().finishBinding((await store(prefs).load())!);
    expect(writes, 1);
    expect((await store(prefs).load())!.step, CompanionSetupStep.outputs);
  });
  test('outputs committed with lost response survive restart and finish once',
      () async {
    final prefs = InMemoryAppPreferences();
    var current = device(companion: 'new', revision: 2);
    var writes = 0;
    final pending = intent.at(CompanionSetupStep.savingOutputs,
        allowed: const OutputSelection(speech: true), inputs: const InputSelection(microphone: false), outputRevision: 0);
    await store(prefs).save(pending);
    DeviceCompanionSetup flow() => DeviceCompanionSetup(
        store: store(prefs),
        loadDevice: () async => current,
        bind: (_) async => fail('binding must not repeat'),
        setOutputs: (allowed, inputs, revision) async {
          writes++;
          expect(revision, 0);
          expect(inputs?.microphone, false);
          current = device(
              companion: 'new',
              revision: 2,
              inputs: inputs,
              allowed: const OutputSelection(
                  speech: true,
                  dialogueText: false,
                  expression: false,
                  audioCue: false,
                  motion: false),
              outputRevision: 1);
          throw TimeoutException('lost response');
        });
    await expectLater(
        flow().finishOutputs(pending), throwsA(isA<TimeoutException>()));
    await flow().finishOutputs((await store(prefs).load())!);
    expect(writes, 1);
    expect(await store(prefs).load(), isNull);
  });
  test('concurrent binding or output edits never get overwritten on recovery',
      () async {
    final prefs = InMemoryAppPreferences();
    final flow = DeviceCompanionSetup(
        store: store(prefs),
        loadDevice: () async =>
            device(companion: 'other', revision: 8, outputRevision: 7),
        bind: (_) async => fail('would overwrite'),
        setOutputs: (_, __, ___) async => fail('would overwrite'));
    await store(prefs).save(intent);
    await expectLater(
        flow.finishBinding(intent), throwsA(isA<CompanionSetupException>()));
    final pending = intent.at(CompanionSetupStep.savingOutputs,
        allowed: const OutputSelection(speech: true), outputRevision: 0);
    await store(prefs).save(pending);
    await expectLater(
        flow.finishOutputs(pending), throwsA(isA<CompanionSetupException>()));
    expect(await store(prefs).load(), isNotNull);
  });
  test('a watched creation completed from another entry preserves its receipt',
      () async {
    final prefs = InMemoryAppPreferences();
    CompanionCreationCheckpointStore creation() =>
        CompanionCreationCheckpointStore(
            hostId: 'h', controllerId: 'c', ownerId: 'o', preferences: prefs);
    await creation().watch('op');
    await creation()
        .save(CompanionCreationSubmission('op', '伙伴', null, null, null));
    await creation().complete(
        'op',
        const CreatedCompanion(
            companionId: 'actual-id',
            displayName: '伙伴',
            created: true,
            memoryReady: true));
    await creation().clear('op');
    expect(await creation().load(), isNull);
    expect((await creation().result('op'))!.companionId, 'actual-id');
    await creation().acknowledge('op');
    expect(await creation().result('op'), isNull);
  });
  test('unknown or incomplete progress is not silently thrown away', () {
    expect(() => CompanionSetupIntent.decode('{"version":8}'),
        throwsFormatException);
  });
}
