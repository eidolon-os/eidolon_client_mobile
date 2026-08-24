import 'dart:io';

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_geometry.dart';
import 'package:eidolon_client_mobile/src/protocol/companion_contract.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Companion lifecycle vocabulary, checked against its single definition.
///
/// This test exists because the drift it now catches got all the way in: this
/// app's mirror invented `pending / suspended / removed`, none of which the
/// Companion authority publishes, and with no value at all for an archived
/// Companion. Four repositories had been hand-spelling the set. The SDK now
/// holds the one definition, and the SDK's own tests check this file — but only
/// once it is on the main branch, so this checks from the other side too, where
/// it guards a feature branch as well.
File? _sdkVocabulary() {
  var directory = Directory.current;
  for (var depth = 0; depth < 4; depth += 1) {
    final file = File(
      '${directory.path}/eidolon_sdk/eidolon_sdk/biz/contracts/companion.py',
    );
    if (file.existsSync()) return file;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}

Set<String> _producerStates(File file) {
  final source = file.readAsStringSync();
  final block = RegExp(
    r'COMPANION_LIFECYCLE_STATES[^=]*=\s*\(([^)]*)\)',
    dotAll: true,
  ).firstMatch(source);
  expect(block, isNotNull, reason: 'SDK 里找不到 COMPANION_LIFECYCLE_STATES');

  // The tuple is composed from named constants, not spelled out — so resolve
  // them. Reading only quoted literals here returns an empty set, which is the
  // exact mistake the SDK-side mirror test made in its first version and passed
  // on. An empty result is a failure, never a pass.
  final scalars = <String, String>{
    for (final match
        in RegExp(r'^(LIFECYCLE_[A-Z]+)\s*=\s*"([a-z_]+)"', multiLine: true)
            .allMatches(source))
      match.group(1)!: match.group(2)!,
  };
  final members = <String>{};
  for (final match
      in RegExp(r'[A-Z_]{4,}|"([a-z_]+)"').allMatches(block!.group(1)!)) {
    final token = match.group(0)!;
    if (token.startsWith('"')) {
      members.add(token.replaceAll('"', ''));
      continue;
    }
    final resolved = scalars[token];
    expect(resolved, isNotNull, reason: '$token 不是 SDK 里的生命周期常量');
    members.add(resolved!);
  }
  expect(members, isNotEmpty, reason: '没读出任何值 —— 这条测试没有真的在比');
  return members;
}

void main() {
  test('Dart 镜像与 SDK 的唯一定义逐字一致', () {
    final file = _sdkVocabulary();
    if (file == null) {
      markTestSkipped('eidolon_sdk checkout 不在旁边');
      return;
    }
    expect(companionLifecycleStates, _producerStates(file));
  });

  test('同一套词有两种语域:句子给行,短标给徽标', () {
    // management 的行和星图的徽标不是两套词,是同一套词的两种长度。
    expect(companionLifecycleSentence('archived'), '你已归档，记忆还留着');
    expect(companionLifecycleLabel('archived'), '已归档');
    for (final state in companionLifecycleStates) {
      expect(companionLifecycleLabel(state).length, lessThanOrEqualTo(4),
          reason: '$state 的短标塞不进徽标');
      expect(companionLifecycleSentence(state), isNotEmpty);
    }
  });

  test('这四个值都能被说成人话，并且各有自己的色调', () {
    // 三个「不在运行」不能都塌成同一片灰：正在退役、已经归档、正在删除，
    // 对主人是三件不同的事。
    expect(companionLifecycleLabel('active'), '在册');
    expect(companionLifecycleLabel('retiring'), '退役中');
    expect(companionLifecycleLabel('archived'), '已归档');
    expect(companionLifecycleLabel('deleting'), '删除中');

    expect(companionLifecycleTone('active'), CockpitTone.ok);
    expect(companionLifecycleTone('retiring'), CockpitTone.warn);
    expect(companionLifecycleTone('deleting'), CockpitTone.warn);
    expect(companionLifecycleTone('archived'), CockpitTone.off);

    // 不认识的值:两种语域都说「不认识」,既不原样显示也不当成 active ——
    // 这条规则是 management 那条线定的,这里跟着它,不另立一套。
    expect(companionLifecycleLabel('something-new'), '未知状态');
    expect(
      companionLifecycleSentence('something-new'),
      '这台 Host 说的状态，这个版本还不认识',
    );
    expect(companionLifecycleTone('something-new'), CockpitTone.idle);
    expect(isCompanionActive('something-new'), isFalse);
  });

  test('已归档的伙伴不会显示成「空闲」', () {
    CompanionUnit unit(String lifecycle) => CompanionUnit(
          companion: CockpitCompanion(
            companionId: 'c',
            displayName: '临渊',
            status: lifecycle,
          ),
          devices: const <CockpitDevice>[],
          activities: const <CockpitActivity>[],
          turns: const <CockpitTurn>[],
          jobs: const <CockpitJob>[],
        );

    // 空闲是「在册但没事做」。归档的伙伴根本不在跑,两者不能穿同一件衣服。
    expect(runtimeBadge(unit('active')).text, '空闲');
    expect(runtimeBadge(unit('archived')).text, '已归档');
    expect(runtimeBadge(unit('archived')).tone, CockpitTone.off);
    expect(runtimeBadge(unit('retiring')).text, '退役中');
    expect(runtimeBadge(unit('deleting')).tone, CockpitTone.warn);
  });

  test('镜像里没有任何一个生产者发不出的值', () {
    // 这一条钉住那次漂移本身:`pending` 是两份 golden 曾经断言过、
    // 而任何 Host 都发不出的值。
    for (final invented in const ['pending', 'suspended', 'removed']) {
      expect(
        companionLifecycleStates,
        isNot(contains(invented)),
        reason: '$invented 不是 Companion authority 发布的值',
      );
    }
  });
}
