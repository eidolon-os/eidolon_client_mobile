import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/theme/eidolon_theme.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/persons_page.dart';

void main() {
  testWidgets('personal memory management preserves authority revision',
      (tester) async {
    var memoryState = 'unbound';
    var revision = 1;
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        calls.add('$method $suffix');
        if (suffix.endsWith('/memory-state')) {
          return {
            'state': memoryState,
            'person_status': 'active',
            'person_revision': revision
          };
        }
        if (method == 'PUT' && suffix.endsWith('/memory-realm'))
          memoryState = 'active';
        if (method == 'POST') {
          memoryState = suffix.contains('/suspend') ? 'inactive' : 'active';
          revision++;
        }
        return {
          'persons': [
            {
              'person_id': 'p',
              'owner_id': 'owner',
              'display_name': '甲',
              'revision': revision,
              'status': 'active',
              'profile': <String, dynamic>{}
            }
          ]
        };
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    expect(find.text('未录入'), findsOneWidget);
    expect(find.text('尚未开启'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      final toggle = find.byKey(const ValueKey('memory-p'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<Switch>(toggle).value, i != 1);
    }
    expect(calls, contains('PUT /p/memory-realm'));
    expect(calls, contains('POST /p/memory-realm/suspend?expected_revision=1'));
    expect(calls, contains('POST /p/memory-realm/restore?expected_revision=2'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed toggle retains authority state and voice status is visible',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        if (method == 'POST') throw StateError('offline');
        if (suffix.endsWith('/memory-state'))
          return {
            'state': 'active',
            'person_revision': 1,
            'person_status': 'active'
          };
        return {
          'persons': [
            {
              'person_id': 'p',
              'owner_id': 'owner',
              'display_name': '甲',
              'revision': 1,
              'status': 'active',
              'profile': <String, dynamic>{}
            }
          ]
        };
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async => {
        'profiles': [
          {
            'person_id': 'p',
            'profile_id': 'v',
            'enrollment_id': 'e',
            'display_name': '甲',
            'revision': 1
          }
        ]
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('已录入'), findsOneWidget);
    final toggle = find.byKey(const ValueKey('memory-p'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(find.text('操作未确认，请刷新或重试'), findsOneWidget);
  });

  testWidgets(
      'unavailable memory status disables switch instead of assuming off',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        if (suffix.endsWith('/memory-state')) throw StateError('offline');
        return {
          'persons': [
            {
              'person_id': 'p',
              'owner_id': 'owner',
              'display_name': '甲',
              'revision': 1,
              'status': 'active',
              'profile': <String, dynamic>{}
            }
          ]
        };
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    expect(find.text('状态暂不可用，请刷新'), findsWidgets);
    expect(
        tester.widget<Switch>(find.byKey(const ValueKey('memory-p'))).onChanged,
        isNull);
  });

  testWidgets('OS person can be managed and open voiceprints without Companion',
      (tester) async {
    final requests = <String>[];
    var status = 'active';
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        requests.add('$method $suffix');
        if (method == 'PUT') status = body!['status'] as String;
        final person = {
          'person_id': 'person',
          'owner_id': 'owner',
          'display_name': '甲',
          'revision': 1,
          'status': status,
          'profile': <String, dynamic>{}
        };
        return method == 'GET'
            ? {
                'persons': [person]
              }
            : person;
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    await tester.tap(find.byTooltip('甲的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(find.text('已停用 · 不参与辅助识别'), findsOneWidget);
    expect(requests, contains('PUT /person'));
    await tester.tap(find.text('声纹管理'));
    await tester.pumpAndSettle();
    expect(find.text('声纹用于辅助识别用户，不限制对话。'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('narrow phone with large text keeps person actions reachable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const name = '一个比较长的用户姓名用于检查手机布局';
    await tester.pumpWidget(MaterialApp(
      theme: EidolonTheme.dark(),
      builder: (context, child) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!),
      home: PersonsPage(
        call: ({method = 'GET', suffix = '', body}) async => {
          'persons': [
            {
              'person_id': 'person',
              'owner_id': 'owner',
              'display_name': name,
              'revision': 1,
              'status': 'active',
              'profile': <String, dynamic>{},
            }
          ]
        },
        voiceprints: ({method = 'GET', suffix = '', body}) async =>
            {'profiles': []},
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('删除用户'), findsNothing);
    await tester.ensureVisible(find.text('个人资料'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人资料'));
    await tester.pumpAndSettle();
    expect(find.text('编辑用户资料'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('声纹管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('声纹管理'));
    await tester.pumpAndSettle();
    expect(find.text('关联此用户'), findsNothing);
    expect(find.text('先录入此用户的声纹，即可测试匹配。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uncertain creation retries the same person id and profile',
      (tester) async {
    final creates = <Map<String, dynamic>>[];
    final people = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: PersonsPage(
      call: ({method = 'GET', suffix = '', body}) async {
        if (method == 'GET') return {'persons': people};
        creates.add(Map<String, dynamic>.from(body!));
        if (creates.length == 1) throw Exception('reply lost');
        people.add(
            {...body, 'owner_id': 'owner', 'status': 'active', 'revision': 1});
        return people.last;
      },
      voiceprints: ({method = 'GET', suffix = '', body}) async =>
          {'profiles': []},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加用户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Alice');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('重试确认添加用户'), findsOneWidget);
    await tester.tap(find.text('重试确认添加用户'));
    await tester.pumpAndSettle();
    expect(creates.length, 2);
    expect(creates[0], creates[1]);
    expect(creates.first['person_id'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('重试确认添加用户'), findsNothing);
  });
}
