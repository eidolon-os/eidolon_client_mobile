import 'dart:convert';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:eidolon_client_mobile/src/management/memory_library_page.dart';
import 'package:eidolon_client_mobile/src/management/memory_library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 记忆库 — what an Eidolon remembers, and the three ways this screen could lie
/// about it: hiding what was withheld, presenting a partial read as the whole
/// memory, and showing a machine identifier where a category name belongs.

Map<String, dynamic> libraryWire({
  int withheld = 1,
  bool truncated = false,
  String materializationState = 'ready',
  int projectionPending = 0,
  List<Map<String, dynamic>>? wings,
}) =>
    {
      'contract_version': '1',
      'memory_realm_id': 'realm-owner-1',
      'audience_scope': 'companion:companion-a',
      'materialization': {
        'ready': materializationState == 'ready',
        'data_readable': materializationState != 'unavailable',
        'materialization_state': materializationState,
        'projection_pending': projectionPending,
        'last_materialized_at': '2026-08-29T12:00:00Z',
        'degraded_reason': materializationState == 'degraded' ? 'KG 暂不可读' : '',
      },
      'wings': wings ??
          [
            {
              'wing_id': 'Wing_Life',
              'display_name': '生活',
              'description': '日常起居与习惯',
              'entry_count': 3,
              'rooms': [
                {
                  'room_id': '饮食',
                  'entry_count': 3,
                  'titles': ['乌龙茶', '不吃香菜'],
                  'more': true,
                },
              ],
            },
          ],
      'entry_count': 3,
      'withheld_count': withheld,
      'truncated': truncated,
    };

MemoryLibraryView library({
  int withheld = 1,
  bool truncated = false,
  String materializationState = 'ready',
  int projectionPending = 0,
  List<Map<String, dynamic>>? wings,
}) =>
    MemoryLibraryView.fromJson(
      libraryWire(
        withheld: withheld,
        truncated: truncated,
        materializationState: materializationState,
        projectionPending: projectionPending,
        wings: wings,
      ),
    );

http.Response _hostAnswer(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  group('the memory library client', () {
    test('asks the generated path and names no Owner', () async {
      Uri? asked;
      String? token;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          token = request.headers['authorization'];
          return _hostAnswer(libraryWire());
        }),
      );

      final view = await client.fetchMemoryLibrary(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
      );

      expect(asked?.path, '/api/management/v1/memory/library');
      expect(asked?.queryParameters.containsKey('owner_id'), isFalse);
      expect(token, 'Bearer session-token');
      expect(view.entryCount, 3);
    });

    test('names a Companion as an audience when asked to', () async {
      // One physical Owner Realm, with a private logical audience per Eidolon.
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(libraryWire());
        }),
      );

      await client.fetchMemoryLibrary(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
      );

      expect(asked?.queryParameters['companion_id'], 'companion-a');
    });

    test('sends no audience when none was named', () async {
      // Not an empty one — `companion_id=` would name an Eidolon with no id.
      Uri? asked;
      final client = ManagementClient(
        httpClient: MockClient((request) async {
          asked = request.url;
          return _hostAnswer(libraryWire());
        }),
      );

      await client.fetchMemoryLibrary(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
      );

      expect(asked?.queryParameters.containsKey('companion_id'), isFalse);
    });
  });

  group('the memory library page', () {
    testWidgets(
      'shows the Realm materialization rather than process liveness',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryPage(
              library: library(
                materializationState: 'materializing',
                projectionPending: 3,
              ),
            ),
          ),
        );

        expect(
          find.byKey(const Key('memory-materialization-status')),
          findsOneWidget,
        );
        expect(find.textContaining('记忆正在整理 · 3 项待同步'), findsOneWidget);
        expect(find.textContaining('realm-owner-1'), findsOneWidget);
      },
    );

    testWidgets('says how much was withheld rather than hiding it', (
      tester,
    ) async {
      // The total and the listed entries differ on purpose. A screen that
      // dropped the difference would look like a bug in the person's memory.
      await tester.pumpWidget(
        MaterialApp(home: MemoryLibraryPage(library: library(withheld: 2))),
      );

      expect(find.text('共 3 条'), findsOneWidget);
      expect(find.text('可见记忆'), findsOneWidget);
      expect(find.text('另有 2 条没有在这个视角展开'), findsOneWidget);
      expect(find.text('它们可能属于其他 Eidolon，或已被设为不再提及。'), findsOneWidget);
    });

    testWidgets('says nothing about withholding when nothing was withheld', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: MemoryLibraryPage(library: library(withheld: 0))),
      );

      expect(find.textContaining('没有在这个视角展开'), findsNothing);
    });

    testWidgets('refuses to present a partial read as the whole memory', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: MemoryLibraryPage(library: library(truncated: true))),
      );

      expect(find.text('这次只读了一部分，下面不是全部'), findsOneWidget);
    });

    testWidgets('shows a shelf is deeper than the titles it lists', (
      tester,
    ) async {
      // The Host sends a few titles, not the contents; "等" is how a person
      // knows there is more behind them.
      await tester.pumpWidget(
        MaterialApp(home: MemoryLibraryPage(library: library())),
      );

      expect(find.text('乌龙茶、不吃香菜 等'), findsOneWidget);
      expect(find.text('饮食'), findsOneWidget);
    });

    testWidgets('uses its own word for a category the Host cannot name', (
      tester,
    ) async {
      // display_name is empty when this Host has never heard of the wing.
      // Nobody ever called a memory "Wing_FromALaterRelease".
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryPage(
            library: library(
              wings: [
                {
                  'wing_id': 'Wing_FromALaterRelease',
                  'display_name': '',
                  'description': '',
                  'entry_count': 1,
                  'rooms': [
                    {
                      'room_id': '?',
                      'entry_count': 1,
                      'titles': [],
                      'more': false,
                    },
                  ],
                },
              ],
            ),
          ),
        ),
      );

      expect(find.text('其他'), findsOneWidget);
      expect(find.text('Wing_FromALaterRelease'), findsNothing);
    });

    testWidgets('an Eidolon that has not remembered anything says so plainly', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryPage(library: library(withheld: 0, wings: [])),
        ),
      );

      expect(find.byKey(const Key('memory-library-empty')), findsOneWidget);
      // The front door remains useful while empty: it still explains the
      // model, lets the Owner switch Eidolons and offers the ways to explore.
      expect(find.byKey(const Key('memory-library-list')), findsOneWidget);
      expect(find.text('和它聊聊，或者直接说“请记住……”。'), findsOneWidget);
    });

    testWidgets(
      'puts named exploration in the page, not icon-only app actions',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryPage(
              library: library(),
              onSearch: () {},
              onOpenToday: () {},
              onOpenGraph: () {},
              onExport: () {},
              onForget: () {},
            ),
          ),
        );

        expect(find.text('你的记忆'), findsOneWidget);
        expect(find.text('浏览和理解'), findsOneWidget);
        expect(find.text('搜索记忆'), findsOneWidget);
        expect(find.text('最近记下'), findsOneWidget);
        expect(find.text('关系图谱'), findsOneWidget);
        expect(find.text('完整副本'), findsOneWidget);
        expect(find.byType(IconButton), findsNothing);

        await tester.scrollUntilVisible(
          find.byKey(const Key('memory-library-forget')),
          200,
        );
        expect(find.text('记忆纠错与隐私'), findsOneWidget);
        expect(find.text('仅在内容不准确或涉及隐私时使用；日常记忆由伙伴自动整理。'), findsOneWidget);
      },
    );

    testWidgets('never exposes a machine-generated room id', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryPage(
            library: library(
              wings: [
                {
                  'wing_id': 'Wing_Profile',
                  'display_name': '个人画像与价值观',
                  'description': '关于你的稳定信息',
                  'entry_count': 1,
                  'rooms': [
                    {
                      'room_id': 'userconfirm:a7e75e91b75e38c9',
                      'entry_count': 1,
                      'titles': ['我喜欢在雨天读纸质书'],
                      'more': false,
                    },
                  ],
                },
              ],
            ),
          ),
        ),
      );

      expect(find.text('你明确让它记住的'), findsOneWidget);
      expect(find.text('userconfirm:a7e75e91b75e38c9'), findsNothing);
      expect(find.text('关于你的背景、身份和重要价值观'), findsOneWidget);
      expect(find.textContaining('MBTI'), findsNothing);
    });
  });

  group('the memory library screen', () {
    ManagementContextView context({bool canGovern = true}) =>
        ManagementContextView.fromJson({
          'contract_version': '1',
          'owner': {
            'owner_id': 'owner-1',
            'display_name': 'Manson',
            'revision': 3,
          },
          'default_companion_id': 'companion-a',
          'capabilities': {'memory.read': true, 'memory.govern': canGovern},
          'limits': {'max_active_companions': null},
        });

    List<CompanionSummaryView> companions() => [
          CompanionSummaryView.fromJson({
            'companion_id': 'companion-a',
            'display_name': '小忆',
            'kind': 'conversational',
            'lifecycle_state': 'active',
            'revision': 1,
            'created_at': '2026-08-28T08:00:00Z',
            'updated_at': '2026-08-28T08:00:00Z',
            'genome_id': 'genome-a',
            'memory_realm_id': 'realm-owner-1',
            'running': true,
            'last_active_at': '2026-08-28T08:00:00Z',
          }),
          CompanionSummaryView.fromJson({
            'companion_id': 'companion-b',
            'display_name': '阿力',
            'kind': 'conversational',
            'lifecycle_state': 'active',
            'revision': 1,
            'created_at': '2026-08-28T08:01:00Z',
            'updated_at': '2026-08-28T08:01:00Z',
            'genome_id': 'genome-b',
            'memory_realm_id': 'realm-owner-1',
            'running': true,
            'last_active_at': '2026-08-28T08:01:00Z',
          }),
        ];

    testWidgets(
      'defaults to one Companion and switches the private memory read',
      (tester) async {
        final asked = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              load: () async => library(),
              loadForCompanion: (companionId) async {
                asked.add(companionId);
                return library();
              },
              loadContext: () async => context(),
              loadCompanions: () async => companions(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(asked, ['companion-a']);
        await tester.tap(find.byKey(const Key('memory-companion-selector')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('阿力'));
        await tester.pumpAndSettle();

        expect(asked, ['companion-a', 'companion-b']);
        expect(find.text('阿力的视角'), findsOneWidget);
      },
    );

    testWidgets(
      'a Companion route opens the shared library in that perspective',
      (tester) async {
        final asked = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              initialCompanionId: 'companion-b',
              load: () async => library(),
              loadForCompanion: (companionId) async {
                asked.add(companionId);
                return library();
              },
              loadContext: () async => context(),
              loadCompanions: () async => companions(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(asked, ['companion-b']);
        expect(find.text('阿力的视角'), findsOneWidget);
        expect(find.text('你的记忆'), findsOneWidget);
      },
    );

    testWidgets('opens scoped search from the overall memory front door', (
      tester,
    ) async {
      String? askedCompanion;
      String? askedQuery;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryScreen(
            load: () async => library(),
            loadForCompanion: (_) async => library(),
            loadContext: () async => context(),
            loadCompanions: () async => companions(),
            searchRecollections: (companionId, query) async {
              askedCompanion = companionId;
              askedQuery = query;
              return RecollectionsView(
                query: query,
                recollections: const [RecollectionView(text: '你喜欢在雨天读纸质书')],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('memory-library-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recollections-page')), findsOneWidget);
      expect(find.text('搜索 小忆 的记忆'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('recollection-question')),
        '雨天读书',
      );
      await tester.tap(find.byKey(const Key('ask-recollections')));
      await tester.pumpAndSettle();

      expect(askedCompanion, 'companion-a');
      expect(askedQuery, '雨天读书');
      expect(find.text('你喜欢在雨天读纸质书'), findsOneWidget);
    });

    testWidgets(
      'recent entries and the full copy keep the selected perspective',
      (tester) async {
        String? dayCompanion;
        String? copyCompanion;
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              load: () async => library(),
              loadForCompanion: (_) async => library(),
              loadContext: () async => context(),
              loadCompanions: () async => companions(),
              loadDay: (_, companionId) async {
                dayCompanion = companionId;
                return MemoryDayView.fromJson({
                  'contract_version': '1',
                  'since': '2026-08-28T00:00:00+08:00',
                  'entries': [],
                  'entry_count': 0,
                  'more_in_window': false,
                  'undated_count': 0,
                  'truncated': false,
                });
              },
              loadCopy: (companionId) async {
                copyCompanion = companionId;
                return MemoryCopyView.fromJson({
                  'contract_version': '1',
                  'taken_at': '2026-08-28T12:31:00+08:00',
                  'records': [],
                  'record_count': 0,
                  'undated_count': 0,
                  'truncated': false,
                });
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('memory-library-today')));
        await tester.pumpAndSettle();
        expect(dayCompanion, 'companion-a');

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('memory-library-export')));
        await tester.pumpAndSettle();
        expect(copyCompanion, 'companion-a');
      },
    );

    testWidgets('offers forgetting only where the Host says it can govern', (
      tester,
    ) async {
      // A visible dead control is a promise the Host has not made.
      for (final allowed in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              key: ValueKey(allowed),
              load: () async => library(),
              loadContext: () async => context(canGovern: allowed),
              previewForget: (_) async => throw StateError('not asked'),
              confirmForget: (_) async => throw StateError('not asked'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('memory-library-forget')),
          allowed ? findsOneWidget : findsNothing,
          reason: 'capability was $allowed',
        );
      }
    });

    testWidgets('offers today only when something can load it', (tester) async {
      // Null hides the way in rather than opening a screen that cannot fill
      // itself.
      for (final wired in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              key: ValueKey(wired),
              load: () async => library(),
              loadContext: () async => context(),
              loadDay: wired
                  ? (_, __) async => MemoryDayView.fromJson({
                        'contract_version': '1',
                        'since': '2026-08-24T00:00:00.000',
                        'entries': [],
                        'entry_count': 0,
                        'more_in_window': false,
                        'undated_count': 0,
                        'truncated': false,
                      })
                  : null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('memory-library-today')),
          wired ? findsOneWidget : findsNothing,
          reason: 'loadDay wired: $wired',
        );
      }
    });

    testWidgets('offers the copy only when something can load it', (
      tester,
    ) async {
      // Same rule as the day page, and it matters more here: a way into an
      // export that cannot fill itself would offer someone a copy of nothing.
      for (final wired in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              key: ValueKey('copy-$wired'),
              load: () async => library(),
              loadContext: () async => context(),
              loadCopy: wired
                  ? (_) async => MemoryCopyView.fromJson({
                        'contract_version': '1',
                        'taken_at': '2026-08-24T12:31:00+00:00',
                        'records': [],
                        'record_count': 0,
                        'undated_count': 0,
                        'truncated': false,
                      })
                  : null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('memory-library-export')),
          wired ? findsOneWidget : findsNothing,
          reason: 'loadCopy wired: $wired',
        );
      }
    });

    testWidgets('opens the copy as its own screen', (tester) async {
      // Not a sheet beside the roll-up: this is the one page that must not
      // shorten anything, and a page sharing room with a summary is under
      // pressure to.
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryScreen(
            load: () async => library(),
            loadContext: () async => context(),
            loadCopy: (_) async => MemoryCopyView.fromJson({
              'contract_version': '1',
              'taken_at': '2026-08-24T12:31:00+00:00',
              'records': [
                {
                  'entry_id': 'drawer_1',
                  'recorded_at': '2026-08-24T09:05:00+00:00',
                  'recorded_at_source': 'occurred_at',
                  'wing_id': 'Wing_Life',
                  'room_id': '饮食',
                  'memory_type': 'preference',
                  'value': '他喜欢喝乌龙茶',
                },
              ],
              'record_count': 1,
              'undated_count': 0,
              'truncated': false,
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-library-export')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-copy-page')), findsOneWidget);
      expect(find.text('他喜欢喝乌龙茶'), findsOneWidget);
    });

    testWidgets('re-reads the library after something is forgotten', (
      tester,
    ) async {
      // A stale library after a deletion is the moment a person stops trusting
      // this screen, so the Host is asked again rather than the list patched.
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryScreen(
            load: () async {
              reads++;
              return library();
            },
            loadContext: () async => context(),
            previewForget: (_) async => ForgetProposalView.fromJson({
              'contract_version': '1',
              'status': 'preview',
              'target': 'x',
              'action': 'delete',
              'entries': [
                {'entry_id': 'drawer_1', 'preview': 'x', 'score': 1.0},
              ],
              'needs_confirmation': false,
              'confirmation_token': 'opaque',
              'expires_at': 1900000000,
              'detail': '',
            }),
            confirmForget: (_) async => ForgetResultView.fromJson({
              'contract_version': '1',
              'action': 'delete',
              'target': 'x',
              'entry_count': 1,
              'status': 'applied',
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);

      await tester.tap(find.byKey(const Key('memory-library-forget')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(reads, 2);
    });

    testWidgets(
      'a memory that could not be read is not shown as an empty one',
      (tester) async {
        // "它还没记下什么" and "我读不到" are different sentences, and only one of
        // them is about the person.
        await tester.pumpWidget(
          MaterialApp(
            home: MemoryLibraryScreen(
              load: () => Future.error(
                const ManagementRequestException(
                  '读取失败',
                  statusCode: 503,
                  refusal: Refusal(
                    kind: 'not_running',
                    reason: 'memory is unavailable',
                    retryable: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('memory-library-error')), findsOneWidget);
        expect(find.byKey(const Key('memory-library-empty')), findsNothing);
        expect(find.textContaining('memory is unavailable'), findsOneWidget);
      },
    );

    testWidgets('retrying after a refusal asks again', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLibraryScreen(
            load: () async {
              attempts++;
              if (attempts == 1) {
                throw const ManagementRequestException('读取失败', statusCode: 503);
              }
              return library();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-library-retry')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.byKey(const Key('memory-wing-Wing_Life')), findsOneWidget);
    });
  });
}
