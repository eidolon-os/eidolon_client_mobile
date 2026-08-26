import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_composition.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_cockpit_page.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_nodes.dart';
import 'package:eidolon_client_mobile/src/features/constellation/polled_cockpit_feed.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The star map, drawn from bytes a Host actually sends.
///
/// Every other test in this feature starts from view objects somebody
/// constructed in Dart. This one starts from JSON on the wire and ends at
/// pixels: the generated `ManagementContextView` / `CompanionRosterView`
/// decoders, the real `ManagementClient`, `CockpitComposer`,
/// `PolledCockpitFeed`, the page. It is the layer where the live attempt
/// actually failed, and the only one that can answer "would a real answer draw".
///
/// Two Host answers are asserted, because both are things this Host does: one
/// that answers, and one that does not. The second is the more important — a
/// screen that says why it is empty is the difference between a bug report and a
/// diagnosis.

final _base = Uri.parse('https://host.invalid');

http.Response _json(Map<String, dynamic> body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );

/// `/context`: the Owner, and which Eidolon answers by default.
Map<String, dynamic> _contextWire() => {
      'contract_version': '1',
      'owner': {
        'owner_id': 'owner-1',
        'display_name': 'Manson',
        'revision': 4,
      },
      'default_companion_id': 'companion-a',
      'capabilities': <String, bool>{},
      'unavailable': <String, String>{},
      'limits': <String, int?>{'max_active_companions': null},
    };

/// The roster: who exists, and the lifecycle vocabulary the producer really
/// sends. `archived` is drawn — it exists — and only `deleting` is not.
Map<String, dynamic> _rosterWire() => {
      'contract_version': '1',
      'default_companion_id': 'companion-a',
      'companions': [
        {
          'companion_id': 'companion-a',
          'display_name': '小忆',
          'kind': 'standard',
          'lifecycle_state': 'active',
          'revision': 2,
          'created_at': '2026-08-26T09:30:00+00:00',
          'updated_at': '2026-08-26T09:30:00+00:00',
        },
        {
          'companion_id': 'companion-b',
          'display_name': '',
          'kind': 'standard',
          'lifecycle_state': 'archived',
          'revision': 5,
          'created_at': '2026-08-26T09:31:00+00:00',
          'updated_at': '2026-08-26T09:40:00+00:00',
        },
      ],
      'next_cursor': null,
    };

/// Answers the two routes the star map is allowed to need, and nothing else.
/// An unexpected path is a 500 with its own path in the body, so a test that
/// starts depending on a third endpoint says which one rather than going quiet.
MockClient _host({
  bool contextAnswers = true,
  int Function()? contextStatus,
}) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/management/v1/context') {
        final status = contextStatus?.call() ?? (contextAnswers ? 200 : 503);
        if (status != 200) {
          return _json(
            {'detail': '主机正在启动，管理面还没有就绪'},
            status: status,
          );
        }
        return _json(_contextWire());
      }
      if (path == '/api/management/v1/companions') {
        return _json(_rosterWire());
      }
      return _json({'detail': '这一屏不该读 $path'}, status: 500);
    });

Future<void> _open(WidgetTester tester, MockClient host) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final client = ManagementClient(httpClient: host);
  addTearDown(client.close);
  final composer = CockpitComposer(
    readContext: () => client.fetchContext(_base, accessToken: 'session-token'),
    readRoster: () => client.fetchRoster(_base, accessToken: 'session-token'),
  );

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: ConstellationCockpitPage(
        openFeed: () => PolledCockpitFeed(
          read: composer.read,
          retryFloor: const Duration(hours: 1),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('主机按契约回答，星图就画出来 —— 从线上的字节到玻璃上', (tester) async {
    await _open(tester, _host());

    // 不再停在首读屏：这一条就是真机上断掉的那一步。
    expect(find.byKey(const Key('constellation-first-read')), findsNothing);
    expect(find.byType(OwnerCore), findsOneWidget);

    // roster 说有两位就画两颗；archived 也存在，只有 deleting 不画。
    expect(find.byType(CompanionPlanet), findsNWidgets(2));
    // 名字空着的那一位不能画成空白。
    expect(find.textContaining('companion-b'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('运行投影没有生产者：伙伴照画，卫星说读不到，而不是装作空闲', (tester) async {
    await _open(tester, _host());

    // 星图在，但运行态必须自称未知 —— 空的域和读不到的域不该长成同一张。
    expect(find.byType(CompanionPlanet), findsNWidgets(2));
    expect(find.textContaining('读不到'), findsWidgets);

    // 记忆域这个字段 roster 根本不带，所以这一屏欠一句「不知道」——
    // 「无空间」/「未开通」是关于这位伙伴的断言，没人问过就不能下。
    expect(find.text('无空间'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('主机自己答的一屏不能被标成 MOCK', (tester) async {
    await _open(tester, _host());

    // 这个角标以前是写死的 —— 于是第一次真实读取一落地就被贴上了演示的标签。
    expect(find.text('MOCK'), findsNothing);
  });

  testWidgets('七条 lane 里六条读不到，顶栏就不许说 ONLINE', (tester) async {
    await _open(tester, _host());

    // 页面曾经在每次 snapshot 上自己造一个 live，把 feed 评定的 degraded 盖掉，
    // 于是满屏「读不到」的上方写着 ONLINE。
    expect(find.text('ONLINE'), findsNothing);
    expect(find.text('UNSTABLE'), findsOneWidget);
  });

  testWidgets('读到一半不等于读到的是旧的：不许说「不是现在」', (tester) async {
    await _open(tester, _host());

    // degraded 和 lost 是两条不同的坏消息。这一次读取五秒前刚成功，身份是现在的，
    // 只有运行态未知 —— 说成「屏幕上是那一次读取的样子，不是现在」是同一类谎的反面。
    expect(find.byKey(const Key('cockpit-read-failure')), findsOneWidget);
    expect(find.text('这一屏有读不到的部分'), findsOneWidget);
    expect(find.textContaining('不是现在'), findsNothing);
    expect(find.textContaining('未知，不是正常'), findsOneWidget);
  });

  testWidgets('主机 500：说出原因并给重试，不是永远转圈', (tester) async {
    var answers = false;
    await _open(tester, _host(contextStatus: () => answers ? 200 : 503));

    // 身份读不到就没有可画的东西 —— 但必须说清是读不到，而不是画一张空图。
    expect(find.byKey(const Key('constellation-first-read')), findsOneWidget);
    expect(find.text('没能读到这台主机的运行投影'), findsOneWidget);
    expect(find.textContaining('管理面还没有就绪'), findsOneWidget);
    expect(find.byType(OwnerCore), findsNothing);
    // 有出路：这一屏必须能自己再试一次。
    expect(find.byKey(const Key('retry-first-read')), findsOneWidget);

    // 主机恢复之后，重试要真的把星图接回来。
    answers = true;
    await tester.tap(find.byKey(const Key('retry-first-read')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('constellation-first-read')), findsNothing);
    expect(find.byType(OwnerCore), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
