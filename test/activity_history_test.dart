/// Everything that has happened here, a page at a time.
///
/// The map's activity list is a bounded now — the Host trims it per Companion —
/// and it was being read as a history. This is the history, and what these
/// tests hold is the three states a person can actually be in when they open it:
///
///   * there is more, and scrolling gets it, without a button;
///   * there is nothing, and that is said plainly;
///   * the Host could not read it, and that says the Host's own sentence with a
///     way to ask again. Absent and unreadable arrive in the same shape on the
///     wire and must never read the same on a screen.
library;

import 'package:eidolon_client_mobile/src/features/constellation/activity_history_sheet.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CockpitActivity _activity(String id) => CockpitActivity(
      activityId: id,
      kind: 'voice_turn',
      companionId: 'eidolon-1',
      status: 'ok',
      outcome: 'success',
      summary: '第 $id 次交互',
      startedAt: DateTime.utc(2026, 8, 27, 9),
    );

ActivityPage _page(List<String> ids, {String? next, String detail = ''}) =>
    ActivityPage(
      items: ids.map(_activity).toList(),
      nextCursor: next,
      detail: detail,
    );

Future<void> _open(
  WidgetTester tester,
  ActivityPageReader read, {
  void Function(CockpitActivity)? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showActivityHistory(
                context,
                read: read,
                companionName: (_) => '砚舟',
                onTap: onTap ?? (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('第一页一打开就读，不用先点什么', (tester) async {
    await _open(tester, (cursor) async => _page(['1', '2']));

    expect(find.text('第 1 次交互'), findsOneWidget);
    expect(find.text('第 2 次交互'), findsOneWidget);
    // 到底了就说到底了 —— 空白的底部会让人以为还在加载。
    expect(find.text('到这里为止了'), findsOneWidget);
  });

  testWidgets('主机给的游标被原样带回去，不被解读；装得下也继续读', (tester) async {
    // 第一页装得下一屏时，列表没有可滚的余量，也就永远收不到滚动事件 —— 一段
    // 还有后续的历史会就停在第一页。所以「读到内容尽头」本身就算「接近尽头」。
    final asked = <String?>[];
    await _open(tester, (cursor) async {
      asked.add(cursor);
      return asked.length == 1
          ? _page(['1'], next: 'opaque-cursor-1')
          : _page(['2']);
    });

    // 第一页不带游标；后续带回主机给的那个字符串本身，不做任何解读。
    expect(asked, [null, 'opaque-cursor-1']);
    expect(find.text('第 1 次交互'), findsOneWidget);
    expect(find.text('第 2 次交互'), findsOneWidget);
  });

  testWidgets('什么都没发生过，和读不到，是两句话', (tester) async {
    await _open(tester, (cursor) async => _page(const []));

    expect(find.text('这里还没有发生过什么。'), findsOneWidget);
    expect(find.text('再试一次'), findsNothing);
  });

  testWidgets('读不到时说出主机自己的那句话，并且能再试', (tester) async {
    var attempts = 0;
    await _open(tester, (cursor) async {
      attempts += 1;
      return attempts == 1
          ? _page(const [], detail: '这台主机的智能体没有应答')
          : _page(['1']);
    });

    expect(find.text('这台主机的智能体没有应答'), findsOneWidget);
    // 不是「还没有发生过什么」 —— 那会把一次读取失败说成一个空荡的家。
    expect(find.text('这里还没有发生过什么。'), findsNothing);

    await tester.tap(find.text('再试一次'));
    await tester.pumpAndSettle();

    expect(find.text('第 1 次交互'), findsOneWidget);
  });

  testWidgets('点一条历史，交给同一个详情', (tester) async {
    final opened = <String>[];
    await _open(
      tester,
      (cursor) async => _page(['1']),
      onTap: (activity) => opened.add(activity.activityId),
    );

    await tester.tap(find.text('第 1 次交互'));
    await tester.pumpAndSettle();

    expect(opened, ['1']);
  });

  testWidgets('读失败以后不自己重试 —— 已经不行的主机不该被反复敲', (tester) async {
    var attempts = 0;
    await _open(tester, (cursor) async {
      attempts += 1;
      return _page(const [], detail: '智能体没有应答');
    });

    // 滚动、重建都不该再触发一次读取。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.text('智能体没有应答'), findsOneWidget);
  });
}
