# Session Trace 在 Mobile 上的呈现：判断与计划

状态：**提案**，其中 M1 已实施（2026-09-15）。
日期：2026-09-15
基线：本仓 `claude/strange-ardinghelli-2fbf80`（工作树干净）；对照
`eidolon_channel`、`eidolon_admin`、`eidolon_agent` 的当前本地源码。
上游方案：`eidolon_channel/docs/analysis/会话链路追踪方案-2026-09-10.md`（P0/P1/P2 已完成，P3 阻塞）。

---

## 0. 结论

**候选 A（把驾驶舱现有事件流改接到 trace 读取路径）不做。** 它基于一个不成立的前提。
驾驶舱现在吃的**不是** Tier B，而是 Tier A（Agent 的 turn 日志）；它的事件 lane 吃的是
审计索引。而它**早就为 Tier B 写好了**——`eventToPulse` 里逐字写着 Channel 的 milestone
名。驾驶舱缺的不是一条读取路径，是 Channel 那条**发布**路径（上游 §6.1，未定）。把 Tier C
接进去，等于用一份没有全局序、没有游标、单会话 135KB 的工程数据，去替换一份有 `ingest_seq`
全序、可续读、一行一时刻的事件流——而后者正是驾驶舱那套「不凭快照差分造光点」纪律的地基。

**候选 B 做，但要收窄：不是「浏览所有 trace，分页加载」，而是「一次会话的瀑布图」。**
入口从用户手里已经有的那条交互往下钻（活动历史 → 轮次 → 工程细节），只用
`GET /v1/session-traces/{session_id}`。**这样根本不需要分页**，用户提的游标问题连同
`TraceQuery` 没有 cursor 这件事一起消失。

**但 B 排在第三位，不是第一位。** 前面两步分别是 Channel 的归属修复（否则这块屏一定是
空的）和 `runtime_session_id` 贯通（否则 Mobile 根本说不出要看哪次会话的名字）。而且
B 必须经过 `eidolon_admin`——这一条见 §6，是需要机主裁决的冲突。

---

## 1. 驾驶舱现在的事件流是什么、从哪来、给谁看

去读了代码，不是猜的。结论与原始假设不同，所以先把链路摊开。

### 1.1 链路

```text
Mobile ConstellationCockpitPage
  └─ PolledCockpitFeed(read: CockpitComposer.read)        每 900ms 一次快照读
       ├─ /context            → Owner 是谁            （权威字段）
       ├─ /companions         → 有哪些伙伴            （权威字段）
       └─ /api/management/v1/mission-control/snapshot → 观测到了什么（投影，分 lane）
            ↓ local-api（admin 仓）→ admin-api /api/internal/v1/management/...
            ├─ turns lane     ← Agent  GET /api/admin/conversations/turns   ← Tier A
            ├─ events lane    ← 审计索引 store.tail_for_owner(owner_id)      ← Tier B 的形状
            ├─ devices lane   ← Hub 列表 + 运行黑板 + channel presence
            └─ jobs/memory/services lane ← Data / Memory / 服务注册表
```

关键落点：

- `PolledCockpitFeed` 构造于 `lib/src/features/host_setup/host_local_connection_page.dart:633`，
  入口标题就叫「驾驶舱 · 伙伴、设备与活动关系」（`:908`）。
- 快照解析唯一入口 `parseMissionControlRuntime`（`lib/src/features/constellation/cockpit_wire.dart`），
  七条 lane，每条自带 `state/detail/observed_at`。
- Host 侧投影 `eidolon_admin/server/eidolon_admin_server/app/management/mission_control.py:52`
  `owner_runtime_projection()`；路由 `app/management/mission_control_router.py:99`。

### 1.2 turns lane 是 Tier A，不是 Tier B

`turns` 的每一行来自 `app/mission_control/service.py:596` `_agent_turns()`，它打的是
Agent 的 `GET /api/admin/conversations/turns`。驾驶舱里那个「时间去哪了」瀑布
（`lib/src/features/constellation/cockpit_details.dart:300`、`:513` `_Breakdown`）画的是
Agent 测的五个脑内阶段，标签在 `app/mission_control/service.py:1421` `_BREAKDOWN`：

> `guard` 检查这句话能不能处理 · `triage` 判断这轮怎么走 · `compile` 组装上下文 ·
> `first_delta` 等到第一个字 · `output` 把话说完

Channel 的事实确实有一条合并路径——`_project_runtime_turns()`
（`app/mission_control/service.py:1187`），它按 `event.source == "channel"` 分组
（`:1216`）。**但它现在吃不到任何东西**，而且是两处独立断开：

1. `service.py:139` —— 它的输入 `data_events` 被硬编码成
   `_unexposed(ledger, "hub.event_feed", ...)`，恒返回 `[]`。
2. 上游方案 §0 结论 2 已写明：Channel 至今一条审计事件都没发过。

所以 `grouped` 恒空，`projected` 就是那句兜底
`projected.extend(turn for turn in agent_turns if ...)`（`service.py:1321`）——**纯 Agent 行**。

### 1.3 events lane 是 Tier B 的形状，但没有 Channel 生产者

`events` 走的是另一条线：`mission_control_router.py` 的 `_owner_audit_tail()` 读审计索引，
`mission_control.py:299` `_event()` 做重命名投影——`source = envelope.producer`、
`milestone = payload["milestone"]`。

而 Mobile 侧 `lib/src/features/constellation/cockpit_models.dart:960` `eventToPulse()`
**已经逐字写着 Channel 的词表**：

```dart
if (event.source == 'channel') {
  if (const ['generating', 'brain_request_sent'].contains(semantic)) ...
  if (const ['brain_first_delta','brain_done','brain_cancelled',
             'brain_error','llm_error'].contains(semantic)) ...
  if (const ['tts_provider_first_audio','first_audio','playback_done'].contains(semantic)) ...
  if (event.type == 'channel.turn.completed') ...
```

这些正是 `ChannelTurnEventSink` 产出的 milestone 名。**从 Channel 的
`audit_sink.to_envelope()` 一直到 Mobile 画光点的这根管子是通的，只缺中间那段 outbox
发布**（上游 §6.1，三个方案 A/B/C，未定）。

### 1.4 给谁看

给机主。证据是词表本身，不是我的判断：

- `cockpit_models.dart:659` `activityKindLabel`：对话 / 守护 / 指令 / 设备 / 任务
- `cockpit_models.dart:668` `activityStatusLabel`：进行中 / 已完成 / 已打断 / 已拒绝
- 上面 `_BREAKDOWN` 那五句中文
- `docs/product-surface-plan.md` §1：「Mobile 是普通用户访问 Eidolon OS 的本地产品入口，
  不是缩小版 Admin Web」

Tier C 的一条记录里是 `duck_events[]`、`eot_score`、`superseded_by_new_acoustic_generation`、
逐包音频状态。这套东西没有、也不应该有对应的机主句子。

---

## 2. 为什么不是 A

三条独立理由，任何一条单独成立即可否掉 A。

**其一，会破坏驾驶舱赖以成立的排序契约。** `PolledCockpitFeed` 不凭快照差分造光点，只凭
「上次没有、这次有、且 Host 给了序号」的事件行造（`cockpit_wire.dart` 的 `eventsAfter` /
`highestSequence`，两条铁律：首次读取不放光点、无序号的行跳过）。Tier C 没有跨会话全序、
没有 `ingest_seq`、没有游标——目录即索引，`_iter_paths()` 按 mtime 排
（`eidolon_channel/eidolon/channel_provider/session_traces.py:131`）。用它喂驾驶舱，那两条
铁律当场失效。

**其二，量级差两个数量级。** Owner 投影的 lane 上限写在
`app/management/mission_control.py:42`：`turns: 24`、`events: 120`，注释说得很直白——
「a phone drawing a constellation needs the shape of what is happening, not an archive of
it」。机主实测一次 90 秒会话 = 9 条记录 / 135KB。一次会话就顶穿整条 lane 的预算。

**其三，A 真正想要的东西不叫 A。** 「驾驶舱的事件流是空的」这个症状，根因是 Channel 没有
outbox，不是 Mobile 读错了地方。修 outbox，光点就会飞，`source == 'channel'` 分支就会走到，
而这**不需要动 Mobile 一行代码**。把 Tier C 接进去只会掩盖这个根因，并且掩盖得很像：屏幕上
有东西在动了，但动的是错的那一层。

---

## 3. 为什么是 B，以及 B 的边界

### 3.1 两块屏各自回答什么

| | 驾驶舱 | 会话链路（新） |
|---|---|---|
| 问题 | 我的域怎么样、刚刚发生了什么 | **这一次对话为什么慢 / 为什么被打断** |
| 读者 | 机主 | 排障的人（机主戴工程帽时也算） |
| 层 | Tier A + Tier B | Tier C |
| 形状 | 一直开着的地图，采样 900ms | 打开一次、看完就走的瀑布图 |
| 数据量 | 每 lane ≤ 24/120 行 | 一次会话 9 条记录 / 135KB |
| 入口 | 主机连接页 | 从一条已有的交互往下钻 |

两者之间没有重叠，也不该有跳转以外的耦合。

### 3.2 收窄成「单会话」，而不是「浏览所有」

用户原话是「浏览所有 trace，分页加载」。建议改成按 id 取单会话，理由三条：

1. **这类数据没人浏览。** Tier C 回答的问题永远是「**那一次**为什么」。先有一次可疑的对话，
   才有看 trace 的动机。一个「所有 trace」列表是在为不存在的行为造承载面。
2. **入口已经有了。** `activity_history_sheet.dart` 的「这里发生过的事」已经在分页
   （`next_cursor`，滚到底自动取下一页，三种空状态分得很清），轮次详情 sheet 已经在画
   `_Breakdown`。Tier C 是**这条已有下钻的更深一层**，不是一块平行的新屏。
3. **游标问题直接消失。** `GET /v1/session-traces/{session_id}` 按 id 取，不分页。

兜底的「最近会话」列表（当手里没有轮次时）可以用列表接口，但**必须叫「最近 N 次会话」而不是
「全部」**——见 §4 关于 `since` 的那条。

### 3.3 Tier C 的呈现形态

一屏，从上到下：一句判词（这次会话多久、有没有异常）→ 会话尺度的六个 mark
（`room_joined → runtime_participant_resolved → warmup_done → avatar_ready →
session_started → first_turn`，缺哪个显式标出，`session_trace.py:61` 的
`SESSION_MARKS` 就是按「缺席可见」设计的）→ 每轮的阶段瀑布。

阶段词表**不新造**：直接用 `PROVIDER_LATENCY_SEGMENTS` 的 30 个定义，与
`eidolon_channel/scripts/report_session_trace.py` 同源。

**一个必须钳住的语义陷阱**（上游 §3.2.1，已经害过一次）：算「播放恢复」只读
`attrs.duck_events[]` 里 `output_resumed_pending_evidence` 的 `at`，**不能**读
`interruption_verdict`。两者差约 6 秒，`45d5f6e` 修的就是这个 bug。Mobile 侧如果自己算
这个数，就是在重蹈覆辙——所以**不算**，只画 Host 已经给出的 `session_marks_ms` 和
`attrs`，不做任何派生。这也正好落在机主那句约束上：不在 mobile 侧另写一份解析/聚合。

---

## 4. 改动清单

### 4.1 eidolon_channel

| # | 改动 | 量级 | 备注 |
|---|---|---|---|
| C1 | **修 owner/companion 归属**（阻塞，见 §5） | 待定 | `eidolon/livekit/agent/observability/turn_events.py:295` `resolve_event_context()`，`kind == "device"` 分支缺 `companion_id` 时直接 raise（`:307`）→ `sink.context` 为 None → `lifecycle.py:64` 传空串 → `session_trace.py:446` 落成 `unknown-owner__unknown-companion` |
| C2 | 打开开关 + 重启 provider | 运维 | `observability.session_trace` 默认关；且上游 P1 写明「跑着的 provider 进程是改动前的代码」，新路由要重启才可用（会短暂中断设备 channel provision） |
| C3 | 列表游标 | ~30 行 | **只在保留「最近会话」列表且要翻过 200 条时才需要**。按 §3.2 收窄后建议不做 |

**关于 C3 必须说清楚的一件事**：`TraceQuery` 的 `since` 是**下界**，不是游标——
`session_traces.py:202` `if started < since: return False`。列表按 mtime 倒序、取满
`limit` 就 break（`:97`）。所以：

- `since` 调大 → 结果是第一页的子集
- `since` 调小 → 结果是第一页的超集，但仍被截到最新的 `limit` 条

**结论：靠 `since` 往前翻是翻不动的，一条都翻不动。** 要真游标，必须给
`TraceQuery`/`SessionTraceReader` 加 `before`（上界）或不透明 cursor。
现状能力上限：`_DEFAULT_LIMIT = 50`、`_MAX_LIMIT = 200`（`:40-41`）——
「最近 200 次会话」是诚实的天花板，写在界面上即可。

### 4.2 management 契约（全部在 eidolon_admin 仓 —— 见 §6）

| # | 改动 | 量级 | 备注 |
|---|---|---|---|
| M1 | **把 `runtime_session_id` 送到 Mobile 的线上** | 4 处加法 | ✅ **已完成 2026-09-15**，见 §8 |
| M2 | 两条只读透传路由 | ~80 行 | `GET /api/management/v1/session-traces[/{session_id}]`，**纯转发**，不解析不聚合 |
| ~~M3~~ | ~~重新生成 Dart 客户端~~ | — | **不需要**。快照路由在 OpenAPI 里是 untyped by design（响应体的权威是 SDK schema），生成的 Dart 客户端只回一个 raw Map，所以加字段不产生契约漂移。`generate.py --check` 实测 clean |

**M1 是这份清单里最便宜、也最值得先做的一条。** 连接 Channel session trace 与一条交互的
钥匙是 `runtime_session_id`（= trace 文件里的 `session_id`），而**它已经在 Agent 的 API 上了**：
`eidolon_agent/app/admin/routers/conversations.py:280` 的 `TurnSummary` 有
`runtime_session_id` 字段，与 `conversation_id` 并列（两者不是一回事，上游 §1.2 专门区分过；§7.2 给出了它在代码里的确切样子——
用错会把同一台设备的所有历史会话糊成一条）。

它在紧接着的第一跳就被丢掉了：`eidolon_admin/.../app/mission_control/service.py:1385`
`_turn(row)` 没有读这个字段（全仓 grep `runtime_session_id` 在 admin 的 mission_control
下零命中），Owner 投影 `app/management/mission_control.py:236` `_turn()` 自然也没有。

所以 M1 = 在 `_turn(row)` 读一次、`RuntimeTurn` 加一个字段、Owner 投影带出来、
OpenAPI 加一个 property。**纯加法，不动任何既有语义**，而且它本身就有独立价值：
有了它，「这条交互」和「那次会话」才第一次能互相指认。

### 4.3 eidolon_client_mobile

| # | 改动 | 备注 |
|---|---|---|
| A1 | 轮次详情 sheet 加一个「工程细节」入口 | 只在 `runtime_session_id` 非空时出现 |
| A2 | 新屏 `SessionTracePage` | 单会话瀑布，只渲染 Host 给出的数，不做任何派生（§3.3） |
| A3 | 入口 gating | 参照已有的 `development_only` 先例（`lib/src/features/setup/development_lan_commissioning.dart:467`） |

Mobile 侧不新增任何解析/聚合逻辑：provider 已经把 `session_marks_ms`、`duration_ms`、
`missing_session_marks` 算好放在 summary 里（`session_traces.py:173-188`）。

---

## 5. 前置依赖与顺序

```text
第 0 步（阻塞一切）  C1 owner/companion 归属修复  ← 在 eidolon_channel，被在途的
                     + C2 打开开关、重启 provider     presentation 工作线挡着
      ↓
第 1 步（不动 Mobile） Channel outbox（上游 §6.1，倾向方案 A：spool + provider 发布）
                     → 驾驶舱的 channel 光点开始飞；这才是 A 真正想要的东西
                     ⚠ turns lane 的阶段合并还额外需要解开 admin service.py:139 的 _unexposed
      ↓
第 2 步（最便宜）     M1 runtime_session_id 贯通 + M3 重新生成客户端
      ↓
第 3 步（本文的 B）   M2 透传路由 + A1/A2/A3
```

**C1 为什么必须在 M2 之前完成，说死一点：**

现在所有设备会话的 trace，`owner_id` / `companion_id` 都是 `None`，文件名是
`unknown-owner__unknown-companion__…`。而 `_matches()`（`session_traces.py:197`）对
`owner_id` 做的是**精确相等**比较。Mobile 的 management 平面**又强制 owner scope**
——`docs/mission-control-local-api-contract.md` §1：「Owner scope 由服务端从 Controller
principal 推导，请求里没有 `owner_id`」，App 不能自报它在看谁的域。

两条一叠：**按 owner 过滤的 trace 列表现在恒为空。** 在 C1 落地之前上 B，做出来的就是
一块永远显示「这台主机没有记录」的屏——而真相是记录就在磁盘上、只是没人认领。这正是那种
「读不到」和「本来就没有」长得一模一样的失效形状，本仓已经为它付过一次代价
（`mission-control-local-api-contract.md` 规则一那段：有人花了一整天找一台其实早就到了的设备）。

**C2 里有一个已知的静默失效形状值得记住**（上游 §3.4.1）：worker 在
`ProtectSystem=strict` 下写不进 provider 的 StateDirectory，`SessionTraceWriter.open`
吞掉异常、记 warning、返回 disabled——真机上语音一切正常、trace 一个字没有、provider
答 `recording: false`，与「追踪本来就没开」**完全同形**。路径已订正到
`$EIDOLON_LOG_ROOT/channel/traces`，但验收时要盯着 `recording` 字段，不能只看界面。

---

## 6. 冲突已裁决（2026-09-15）

> **机主裁决**：「我不想动 admin 的演示，目前主要想把 mobile 当作演示。admin 主要提供接口。」
>
> 冻结的是 admin 的**演示层**（`eidolon_admin/web/`，那个 vite 控制台），不是它的 API。
> admin 作为接口提供方、mobile 作为呈现面，正是 M1/M2 需要的分工。**本节原先描述的冲突
> 不成立**，下面的链路事实仍然有效，作为「为什么必须过 admin-api」的依据保留。
>
> 由此确立的边界，后续都按它走：
> - ✅ `server/…/app/management/*`、`server/…/local_api/*`、`contracts/management/v1/*`
> - ✅ `server/…/app/mission_control/*` 的服务端数据管道（不是控制台 UI）
> - ❌ `eidolon_admin/web/` —— 一行都不碰

### 6.1 为什么必须经过 admin-api（原 §6 的链路事实）

去验证了，没有绕开的可能：

- Mobile 的全部 management 读取走 `/api/management/v1/*`
  （`lib/src/generated/management_v1.dart`，头两行写着它由
  `eidolon_admin/contracts/management/v1/management-v1.openapi.json` 生成）。
- 承载它的 `eidolon-local-api` 在
  `eidolon_admin/server/eidolon_admin_server/local_api/`。
- 而 local-api **只是一层认证壳**：`local_api/management/backend.py:77`
  `AdminManagementClient` 把每一个 management 读取都转成
  `/api/internal/v1/management/*` 打到 admin-api。`host_services.py:164` 的
  `AdminHostServicesClient` 同理。**local_api 没有任何一条绕开 admin-api 直连权威的路径。**
- channel-provider 只听 `127.0.0.1:8767`（`eidolon/channel_provider/config.py:24-25`），
  且 `eidolon_channel/docs/channel-provider.md` 明写「不接受 Mobile 直连」。

所以：**任何把 Tier C 放上 Mobile 的做法，都要在 eidolon_admin 里加代码，并且要求
admin-api 进程在线。** 这与「eidolon_admin 这个项目暂时不想推进」直接冲突。

给一个建议，不是给一个菜单：

**先做第 0/1/2 步，把第 3 步压后。** 理由是这三步的性价比完全不同：

- 第 0 步在 eidolon_channel 内闭环，且它是**所有**后续路径的共同前置。
- 第 1 步同样在 eidolon_channel 内闭环（admin 侧零改动即可让 events lane 见到 channel
  事件，因为审计索引这条线是通的），而它点亮的是机主真正会看的那块屏。
- 第 2 步是四处加法，独立有价值。
- 只有第 3 步需要真正动 admin，而**它服务的是排障，不是机主**。排障的人有终端，
  `eidolon_channel/scripts/report_session_trace.py` 已经能出完整瀑布图（本地文件或
  provider HTTP 两种来源）。在六寸屏上重做一遍，换来的是一个更差的瀑布图，代价是撬动一个
  被明确冻结的仓。

**什么条件下第 3 步值得做：** 当 admin 因为别的原因已经在被改动时顺带做；或者当
「不在现场的人要看某次会话为什么卡」成为反复出现的真实场景时。在那之前，把 M1 做掉就够了
——它让「哪次会话」这个名字第一次能被说出口，而说出口是所有后续的前提。

---

## 7. 已核实（2026-09-15 补，原「未验证」三条中的两条已关闭）

### 7.1 ✅ `runtime_session_id` 就是 trace 的 `session_id` —— 同一个变量，不是两个碰巧相等的值

原本标为「M1 动手前必须先拿真机会话比一次」。**不用比了**，静态就能走完，而且比对一次值
更强：它是同一个变量一路流下去的。

```text
Hub SessionRequest.conversation_id
  → LiveKit named dispatch metadata
  → Channel  _resolve_runtime_session_id(ctx)        eidolon/livekit/agent/server.py:278
  → SharedStageFactory.runtime_session_id            eidolon/livekit/agent/factory.py:211
  ├─→ trace session_id                               eidolon/livekit/agent/shared/pipeline.py:135
  │      （open_session_trace(session_id=getattr(self._factory,"runtime_session_id","")）
  └─→ 设备 token 的 session_id claim                 eidolon/livekit/agent/factory.py:122,133
         → Agent AuthInterceptor.verify(raw)         app/transport/grpc/interceptors.py:35
         → identity.session_id
         → TurnInput.session_id                      app/transport/grpc/chat_servicer.py:216
         → _runtime_session_id(ti)                   infra/persistence/agent_runtime.py:763
         → turns.runtime_session_id 列               infra/persistence/runtime_store.py:111
         → TurnSummary.runtime_session_id            app/admin/routers/conversations.py:280
```

Channel 侧那句 guard 把这件事说死了（`factory.py:123`）：

> `runtime_session_id is empty — the named dispatch must bind the Agent credential to one interaction session.`

**结论：M1 的形状成立，可以按原计划做。**

### 7.2 ⚠️ 顺带挖出一个必须避开的坑：`conversation_id` 绝不能当 join key

Channel 发给大脑的那个 gRPC `conversation_id` 是 `<prefix>:<participant identity>`
（`factory.py:338-372`），并且**故意跨会话长寿**——注释写着「every JOIN from the same
device continues one conversation」。它和 `runtime_session_id` 是两个东西，共用一个名字。

上游 §1.2 提醒过这个陷阱，这里是它在代码里的确切样子。**谁要是用 `conversation_id` 去
join session trace，会把同一台设备所有历史会话糊成一条。** M1 只认 `runtime_session_id`。

### 7.3 ✅ Local API 没有可用的旁路 —— 而且理由比原先判断得更硬

原本标为「没有逐行通读 router.py 全部 1900 行」。读完了边界定义。Local API 上确实存在
两个**不经过** `ManagementBackendPort` 的 Port，但它们绕开的理由都不适用于本例：

| Port | 位置 | 绕开的理由 |
|---|---|---|
| `OwnerDevicePort` | `management/router.py:1532` | 「已认证的 Controller 只存在于这个边界」——组合需要 Controller 身份本身 |
| `ControllerDirectoryPort` | `management/router.py:1558` | 「这是本机自己的授权记录，不是某个权威的数据」，走本进程已认证的控制 socket |

而 `ManagementBackendPort` 那条边界的存在理由写在 `local_api/management/backend.py:5`：

> the boundary is *for* credential isolation … the Data/Hub/Kernel credentials stay in that service

channel-provider 的 bearer（`EIDOLON_CHANNEL_PROVIDER_TOKEN`）**正是一个权威凭据**。把
session-traces 直接挂在 Local API 上，等于让 LAN 面进程持有权威凭据——**破坏的正是这条
边界存在的唯一理由**。

**结论：§6 的冲突不能靠「只改 Local API」绕过，它比原先写的更硬。** M2 必须过 admin-api。

### 7.4 仍未验证

- **一次会话 9 条记录 / 135KB、一轮 26~30 个 mark** 仍是机主实测数字，本机 trace 目录为空
  （在 Pi / dev host 上），没有复核。已核对的只有 `record_kind` 词表与六个会话尺度 mark。

---

## 8. M1 实施记录（2026-09-15）

`runtime_session_id` 现在从 Agent 一路走到 Mobile 的 `CockpitTurn`。**这一步不新增任何
端点、不改任何既有语义，全是加法。**

### 8.1 改了什么

| 仓 | 文件 | 改动 |
|---|---|---|
| eidolon_sdk | `contracts/mission_control/v1/mission-control-snapshot.schema.json` | turn item 加 `runtime_session_id`（`["string","null"]`，maxLength 128，非 required） |
| eidolon_sdk | `contracts/.../golden/snapshot-healthy.json` | 黄金载荷带上该字段 |
| eidolon_admin | `app/mission_control/schemas.py` | `RuntimeTurn.runtime_session_id: str \| None` |
| eidolon_admin | `app/mission_control/service.py` | `_turn(row)` 读取；`_project_runtime_turns` 的 channel 分支从 agent 半边带出 |
| eidolon_admin | `app/management/mission_control.py` | Owner 投影 `_turn()` 输出该字段 |
| eidolon_client_mobile | `cockpit_models.dart` | `CockpitTurn.runtimeSessionId` |
| eidolon_client_mobile | `cockpit_wire.dart` | 解析 `runtime_session_id` |

**没有碰 `eidolon_admin/web/`。**

`maxLength: 128` 不是拍的：Agent 自己的列就是 `String(128)`
（`infra/persistence/runtime_store.py:111`），跟着权威的存储宽度走。

### 8.2 顺序是被测试强制的，不是靠自觉

SDK schema 的 turn item 是 `additionalProperties: false`。**先发 producer 再发 schema，
admin 有 7 条测试当场变红** —— 实测过：把 schema 里的字段删掉再跑
`test_owner_runtime_projection.py`，`7 failed, 5 passed`。所以 SDK 必须先落。

（这正是 `snapshot-fields-forbid-extras` 那条教训的同一个形状。）

### 8.3 每一跳都做了变异验证

「测试通过」不算数，得证明它在对的地方会红：

| 跳 | 变异 | 结果 |
|---|---|---|
| SDK schema ← golden | golden 值撑到 129 字符 | ✅ 红（越过 maxLength） |
| SDK schema → admin | schema 删掉该字段 | ✅ 红（7 条） |
| Agent row → `RuntimeTurn` | `_turn(row)` 写死 `None` | ✅ 红（`test_live_turn_projection`） |
| `RuntimeTurn` → wire | Owner 投影删掉该字段 | ✅ 红（2 条） |
| wire → `CockpitTurn` | 解析写死 `''` | ✅ 红（`cockpit_wire_test`） |

第三跳是变异验证救回来的：最初只加了投影侧的断言，改坏 `_turn(row)` **测试依然全绿** ——
因为那两条测试直接构造 `RuntimeTurn` 对象，根本没经过 ingest 那一跳。补了
`test_live_turn_projection.py` 里的两条才真正盖住。

### 8.4 ⚠️ 顺带修掉一个一直在静默跳过的守卫

`test/cockpit_wire_test.dart` 的 `_golden()` 往上找旁边的 `eidolon_sdk`，注释写着
「worktree 比正常深一级，静默跳过的测试就不再守任何东西」—— 但它只走 4 层，而
worktree 在 `.claude/worktrees/<name>`，是**深三级**，差两层够不着。

**后果：在 worktree 里跑，这个文件的黄金测试全部跳过并报绿。** 修之前 `4 passed, 10
skipped`，改成走到文件系统根之后 `14 passed, 0 skipped`。注释所担心的事情，正是它自己
一直在发生的事情。

`test/constellation_wire_to_screen_test.dart:91` 同一个 bug，一并修了（它读的是同一份
黄金、同一条 lane）。`test/companion_lifecycle_test.dart:19` 也有，但属于另一块，
已另开任务，没有并进这次改动。

### 8.5 验证

| 套件 | 结果 |
|---|---|
| eidolon_sdk `tests/contracts/test_mission_control_contract.py` | 8 passed |
| eidolon_admin `server/tests/` 全量 | **879 passed, 5 skipped** |
| eidolon_client_mobile 全量 | **1009 passed, 10 skipped**（改动前 1006 / 13） |
| `dart analyze lib test` | No issues found |
| `contracts/management/v1/generate.py --check` | clean（契约无漂移） |

**一条既有红线，与本次改动无关**：eidolon_sdk 的
`tests/contracts/test_esp32_contract_mirror.py::test_esp32_canonical_claim_consumer_and_roll_call_handler_match_contract`
在**干净工作树上**同样失败（把本次改动全部还原后复验：仍然 1 failed / 2 passed）。
已另开任务，没有在这里顺手改绿。

### 8.6 下一步

M1 落地后，`runtimeSessionId` 现在是 `CockpitTurn` 上一个**还没有人读**的字段。这是
有意的：它本身就有价值（「这条交互」与「那次会话」第一次能互相指认），而消费它的
那块屏属于第 3 步。

按 §5，真正的下一个前置仍然是 **C1 归属修复**（eidolon_channel）：在它落地之前，
provider 的列表接口按 owner 过滤恒为空。M1 不依赖它，第 3 步依赖它。

---

## 9. C1 实施记录（2026-09-15）

设备会话的 trace 现在按「主人 + 挂载应答的 Companion」命名，不再是
`unknown-owner__unknown-companion`。落在 `eidolon_channel`，分支
`claude/c1-trace-owner`（提交 `4c3dd32`）。

### 9.1 根因，和为什么显而易见的那个修法是错的

`resolve_event_context` 要求参与者元数据里有 `companion_id`。**设备 token 故意不带**
—— provider 的原话是「server-side orchestration is declared where the room is declared,
never routed through a credential handed to the device」。

所以看起来最直接的修法（把 `companion_id` 塞进设备 token）**恰恰是错的**：那等于把
服务端编排决定交给一份发到设备 flash 里、能用好几个小时的凭据。

正确的来源就在旁边：设备 token 自己的解析器早就在读 Kernel mount 的
`answering_companion_id`（`runtime/resolver.py:221`，
`metadata.companion_id or connection.answering_companion_id`）。C1 只是让
`resolve_event_context` 问同一个人 —— 而且问的是 `ChannelRuntimeServices.resolve_room`，
它按会话记忆答案，所以 trace 命名的那一对，**就是凭据被签发时的那一对**，不是可能
和它不一致的第二次查询。

### 9.2 这个 bug 的形状：和「压根没开追踪」完全同形

context 解析失败 → sink 记一行 warning 后自我关闭 → writer 回落到占位符。
真机上语音一切正常、trace 文件在磁盘上、但按 owner 过滤查不到任何东西
（`_matches` 对 owner_id 做精确相等）。

和 §3.4.1 记的那个 systemd 路径问题是同一类：**失败和「本来就没开」长得一模一样。**

### 9.3 改了什么

| 文件 | 改动 |
|---|---|
| `observability/turn_events.py` | `resolve_event_context(room, *, context_resolver=None)`；device 分支回落到 mount；`sink.start` 透传 |
| `full_duplex/lifecycle.py` | 抽出 `begin_session_observation(room)`，并传入 `factory.runtime_context_resolver` |
| `half_duplex/pipeline.py` | PTT 调用点同样传入 |

**抽出那个方法是为了能测。** 原先这段内联在 `run()` 里，只有立起一整个 AgentSession
才够得着 —— 而这正是「忘了传 resolver」能不被发现的原因：解析本身的单测照样全绿，
真机上每一次会话却依然无归属。

### 9.4 变异验证

| 变异 | 结果 |
|---|---|
| 新增测试（修复前） | ✅ 红（3 条） |
| full_duplex 调用点删掉 `context_resolver=` | ✅ 红 —— 且日志里打出的正是线上那句 `Channel turn events disabled: device event context requires...` |
| PTT 调用点删掉 `context_resolver=` | ✅ 红 |

### 9.5 验证

| 套件 | 结果 |
|---|---|
| `tests/agent/` 全量 | **1048 passed, 2 skipped, 11 xfailed** |
| `tests/agent/test_channel_turn_events.py` + `test_session_trace.py` | 31 passed |
| `ruff check`（5 个改动文件） | All checks passed |
| `mypy turn_events.py` | 仅一条既有的 SDK 缺 stub 提示，非本次引入 |

**一条既有红线，与本次改动无关**：`tests/scenarios/test_human_ptt.py` 全部 18 条在
`main`（`de5ef01`）上就是红的 —— `half_duplex/pipeline.py:192` 读
`self._factory.outputs`，而 scenario harness 的 `SimpleNamespace` 替身没有这个属性
（近期 outputs/presentation 那条线造成的替身漂移）。把本次改动全部还原后复验：**同样 18 条红**。
已另开任务，没有顺手改绿。

### 9.6 关于「在途工作线」

开工前核对过：那条 presentation/channel-provider 工作线**仍未落地**（worktree
`amazing-ramanujan-7bdf5d`，24 个文件未提交），它在给 dispatch metadata 加
`session_intent`。但它碰的是 `adapters/livekit/adapter.py`、`server.py`、
`runtime/interaction_mode.py`；C1 碰的是 `observability/turn_events.py` 与两条管线
—— **零重叠**，所以没有等它。

顺带一提，它给出的理由和 C1 的约束是同一条：「intent 骑在 dispatch 上而不是设备 token 上，
因为 dispatch 是唯一既按会话又不可被设备改写的东西」。

### 9.7 下一步

C1 落地后，§5 的第 0 步只剩运维部分：打开 `observability.session_trace` 开关，
并**重启 `eidolon-channel-provider`**（P1 写明跑着的进程是加路由之前的代码）。
验收时盯 `recording` 字段，别只看界面 —— 见 §9.2。

之后就能按 owner 过滤查到真实会话，第 3 步（单会话瀑布屏）才有东西可显示。

---

## 10. 上线清单（运维，2026-09-15）

> **先更正 §9.7 的一句话。** 那里写「打开 `observability.session_trace` 开关（默认关）」，
> **不准确**：没有布尔开关，`session_trace_path` 本身就是开关（空串 = 关），而
> `eidolon_channel/config/settings.yaml:199` 已经把它设成
> `"$EIDOLON_LOG_ROOT/channel/traces"`。产品 Host 读的就是组件自己的这份
> `config/settings.yaml`（`eidolon_ops/src/eidolon_ops/product_settings.py:57`），
> 而 `PRODUCT_OVERLAY` 没有改这一项。
>
> **所以追踪本来就是开的。** 空的是 `settings.example.yaml`，不是产品配置。
> 真正要做的只有「让新代码上机」和「重启 provider」两件。

### 10.0 名词对照

| 东西 | 值 | 出处 |
|---|---|---|
| 产品 log root | `/var/log/eidolon` | `eidolon_ops/src/eidolon_ops/paths.py:92` |
| trace 落盘 | `/var/log/eidolon/channel/traces/<date>/<owner>__<companion>__<session>.ndjson` | `settings.yaml:199` |
| provider 读的目录 | 同上，**只读** | `config/channel-provider.yaml:15` |
| provider 监听 | `127.0.0.1:8767`（**不对外**） | `channel_provider/config.py:24` |
| bearer | `EIDOLON_CHANNEL_PROVIDER_TOKEN` | `config/channel-provider.yaml:2` |
| env 文件 | `/etc/eidolon/channel.env` | `eidolon_kernel/eidolon_deploy/manifest.py:200` |
| worker 单元 / service_id | `eidolon-channel.service` / `channel` | `eidolon_kernel/config/system-services.yaml:250` |
| provider 单元 / service_id | `eidolon-channel-provider.service` / `channel-provider` | 同上 `:259` |
| dev（Mac/supervisord） | `channel:channel-worker`、`channel-provider:channel-provider` | 同上 |

### 10.1 第一步：让 C1 的代码上机（**不能只重启**）

C1 是代码改动（`ebf8f0f`），不是配置。Host 按 pin 住的 source revision 安装
（`eidolon_ops/config.py:263`），所以**必须走一次部署**把 `eidolon_channel` 的 revision
推到含 `ebf8f0f` 的提交，否则重启只是把旧代码再跑一遍。

具体的发布命令按你这台 Host 的既有流程走（`eidolon-ops install --release-id ...`
配合 inputs 里的 source pin）——**这一步我没有替你验证过**，因为它取决于这台机器当前
pin 的是哪个 revision。

上机后确认跑的是新代码：

```bash
ssh <host> "cd /opt/eidolon/current/eidolon_channel && git log --oneline -1"
```

### 10.2 第二步：重启 worker 和 provider

两个都要，理由不同：

- **worker**（`channel`）—— 装上 C1 的新代码
- **provider**（`channel-provider`）—— P1 的两个只读路由是 2026-09-11 加的，而
  跑着的进程是那之前的代码。**重启会短暂中断设备 channel provision。**

从手机上做（Owner 自己就有这个能力，`MutationOperation = Literal["restart", ...]`，
`eidolon_admin/.../local_api/host_services.py:33`）：

> 主机运行状态 → 底座 → 找到 `channel` 与 `channel-provider` → 各自那一行上的重启

或者 SSH：

```bash
ssh <host> "sudo systemctl restart eidolon-channel.service eidolon-channel-provider.service"
```

dev（Mac / supervisord）：

```bash
supervisorctl restart channel:channel-worker channel-provider:channel-provider
```

### 10.3 第三步：验收 —— **盯 `recording`，别只看界面**

provider 只监听 127.0.0.1，所以这条必须在 Host 上跑：

```bash
ssh <host> 'curl -s -H "Authorization: Bearer $EIDOLON_CHANNEL_PROVIDER_TOKEN" http://127.0.0.1:8767/v1/session-traces?limit=5'
```

三种答案，含义完全不同：

| 回答 | 含义 |
|---|---|
| HTTP 404 | **provider 还是旧代码**，路由不存在 → 第二步没生效 |
| `{"recording": false, ...}` | 路由在了，但 **trace 目录不存在** → 追踪没在写（配置或权限） |
| `{"recording": true, "sessions": [...]}` | 正常 |

`recording: false` 与「一次会话都没发生过」**长得几乎一样**，这正是 §9.2 和 §3.4.1
两次踩过的坑：失败和「本来就没开」同形。所以先看 `recording`，再看 `sessions`。

### 10.4 第四步：确认 C1 真的生效 —— 看文件名

跑一轮**设备**语音对话（不是手机），然后：

```bash
ssh <host> "ls /var/log/eidolon/channel/traces/$(date +%F)/"
```

- 出现 `unknown-owner__unknown-companion__*.ndjson` → **C1 没生效**（旧代码，回到 10.1）
- 出现 `<owner_id>__<companion_id>__*.ndjson` → 成立

这是唯一能区分「C1 上了没」的现场证据 —— 因为在此之前，语音一切正常、文件也照写，
只是名字是占位符。

再验按 owner 能查到（这是 mobile 第 3 步的前提）：

```bash
ssh <host> 'curl -s -H "Authorization: Bearer $EIDOLON_CHANNEL_PROVIDER_TOKEN" "http://127.0.0.1:8767/v1/session-traces?owner_id=<owner_id>&limit=5"'
```

返回非空才算通过。在 C1 之前这里**恒为空**（`_matches` 对 owner_id 精确相等）。

### 10.5 一次会话的瀑布图（排障用，不需要 mobile）

```bash
ssh <host> "cd /opt/eidolon/current/eidolon_channel && .venv/bin/python scripts/report_session_trace.py --session <session_id>"
```

这就是 §6 说「第 3 步可以压后」的依据：排障要的东西，终端上已经有了。

### 10.6 做完之后

10.1–10.4 全过，才谈得上做第 3 步（mobile 的单会话瀑布屏）。在此之前那块屏即使做出来，
列表也是空的。

M1 已经把 `runtime_session_id` 送到了 `CockpitTurn` 上（§8），所以第 3 步一旦开工，
「这条交互 → 那次会话」的跳转是现成的。

---

## 11. 实测 Host 状态（2026-09-15 18:20，eidolon-pi5）

> **§10 开头那句更正，本身也是错的 —— 就当前 Host 而言。** 我当时读
> `config/settings.yaml:199` 看到 `session_trace_path` 是设好的，据此断定「追踪本来就是
> 开的」。但 `679bc4a fix(config): hold new settings keys back a release so rollback
> survives` 之后把这四个键**注释掉了**，而部署到 Host 上的正是注释掉的那一版。
>
> **同一个判断我错了两次**：第一次说它默认关（错，因为 repo 里当时是开的），第二次说
> 它本来就开（错，因为 main 随后把它关了，而且是**故意**的）。教训是这类「开关在哪」的
> 结论必须以**部署产物**为准，不是以仓库里那一行为准 —— 两者可以合法地不一致。

### 11.1 逐条对照 §10

| 步 | 状态 | 证据 |
|---|---|---|
| 10.1 C1 代码上机 | ✅ **已完成** | release `20260915-observed-host-address-2`，18:16 激活；`context_resolver` 在部署产物的三个文件里都在（8 / 4 / 2 处），`begin_session_observation` 也在 |
| 10.2 重启 worker + provider | ✅ **已完成** | 两者今天 18:16:30 / 18:16:40 启动；`eidolon-hub` 18:16:56 |
| 10.2 P1 路由生效 | ✅ **已验证** | `GET /v1/session-traces` → **401**，而不存在的路由 → **404**。401 证明路由在，且不需要任何密钥就能证明 |
| 10.3 `recording` | ❌ **会是 false** | `/var/log/eidolon/channel/traces/` **不存在** |
| 10.4 文件名检查 | ⏸ 无从做起 | 没有 trace 文件 |

**一个方法上的收获**：用「401 vs 404」判断路由是否存在，**不需要 bearer**。
这比「拿 token 调一次」既安全又更早可做。

### 11.2 唯一剩下的阻塞：那四行注释

部署产物 `config/settings.yaml:222-236` 把话说得很清楚：

> Per-session link trace (room join -> leave) waits for the next release …
> **this is the release that adds the fields, so this is the release that may not name them.**
> … Until then the schema default holds and **no trace is written anywhere**. That costs
> this release the diagnosis, not the feature: the writer, the Provider endpoint that
> serves the files and `scripts/report_session_trace.py` all ship here and **turn on with
> one line in the release after**.

这是一条**有意的分级发布约束**：引入新 schema 键的那个 release 不能同时使用它，否则回滚
到上一版会遇到它不认识的键。

**而引入这些字段的 release 已经部署了**（就是今天 18:16 这个）。所以「the release
after」的条件从现在起成立 —— 把那四行取消注释、发下一个 release，追踪就开了。

### 11.3 所以还缺什么

**一行配置 + 一次发布。** 不是代码。

- 不要在 Host 上手改 `/opt/eidolon/current/.../settings.yaml`：那是 release 产物，
  下次发布就被覆盖，而且绕过了 reversible 发布的整个约束
- 改在 `eidolon_channel/config/settings.yaml`（取消 227–230 行的注释），随下个 release 走

**这件事本身归另一条工作线**（会话「修复 channel settings 字段挡住 reversible 发布」），
所以本文只记录条件已成立，不代劳。

### 11.4 顺带记下的现场事实

- Host 在 18:16 前后整体重启过一轮；**18:15:51 那一刻去看，channel 与 hub 都是
  `inactive`** —— 不是故障，是还没起完。**几十秒的差别足以把一次正常启动读成一次事故。**
  下次判断服务状态，先看 `ActiveEnterTimestamp` 再下结论。
- 台面直连（bench cable）这条链路：Host 侧按设计回落到 169.254/16，但这台 Mac 的 `en7`
  被静态配成了 `10.42.0.1/24`，**没有 169.254 地址，所以 IPv4 走不通**（`10.42.0.2`
  ARP incomplete）。
  **IPv6 link-local 可以直接用**，不需要改任何网络设置：
  `ping6 ff02::1%en7` 找到邻居，`ndp -an` 按 MAC 认出板子，然后
  `ssh ... eidolon-pi5@fe80::<pad>%en7`，配合 ops 自己的
  `HostKeyAlias=eidolon-pi5.local` + `known_hosts_file` 做信任固定。

---

## 12. 上线结果（2026-09-15 23:35，eidolon-opi5max）

**追踪已经开了，C1 也在板子上。** 但最后一步（真机设备对话验证命名）还没做，见 §12.4。

### 12.1 我用错了命令，被守卫拦下

我跑的是 `eidolon-ops … install --apply`。**`install` 是给新板子做初装的，不是给已装好的 Host 发版的。** 正确的动词是 `deploy` / `update`。

它失败了，而且失败得很干净：

```
used legacy identity has no hardware delivery evidence;
use ordinary deploy to preserve the installed Host,
or initialize independent inputs for a new board
```

这是**预检守卫**，在动板子之前就拒绝了 —— 事后核对 releases 目录、current 链接、服务状态，板子没有被我改动过一个字节。守卫写得好：错误信息直接说了该用哪个命令，以及另一条路（新板子初始化）是什么。

### 12.2 目标是别人顺带带上去的

23:32 另一个操作者发了 `rk3588-observed-host-address-2`。那一版从 main HEAD 构建，而我的
`fa67925` 当时已经合进 main —— **所以配置是跟着他们那一版上去的，不是我发上去的。**

这也说明 §10.1 那句「必须走一次部署」成立，但「必须由谁来走」不成立：在一个所有人都从
main 打包的仓里，你的提交合进 main 之后，**下一个发版的人就会替你带上去。**

### 12.3 已验证（实测，非推断）

| 检查 | 结果 |
|---|---|
| release 里的 `config/settings.yaml` | 四个键都在，无 `#` |
| **`/etc/eidolon/channel.yaml`（worker 真正读的那份）** | `session_trace_path` 在 |
| C1 | `context_resolver` 8 处、`begin_session_observation` 2 处 |
| worker | 23:34:19 带新版本起来 |
| `GET /v1/session-traces` | **`recording: true`**，3 条会话 |

**第三行是关键。** release 目录里的 settings.yaml 只是素材，Ops 渲染出来的
`/etc/eidolon/channel.yaml` 才是 worker 读的那一份 —— 只看前者会得到一个看似成立、
其实没验证到位的结论。

### 12.4 唯一没做的：命名要靠一次真机对话

磁盘上现在三条 trace，全是 `unknown-owner__unknown-companion__esp32-*`，时间是
09-14 23:32 / 09-15 00:01 / 09-15 01:02 —— **全都早于 C1 上板**。所以它们证明不了 C1。

C1 的效果只有**新的一次设备会话**才看得见：

```bash
ssh -i ~/.ssh/id_ed25519_eidolon_opi5max eidolon-opi5max@10.42.0.2 \
  "sudo ls -t /var/log/eidolon/channel/traces/*/ | head -3"
```

- 还是 `unknown-owner__…` → C1 没生效，回到 §9 查 `resolve_event_context`
- 变成 `<owner_id>__<companion_id>__…` → 整条线走通

这一步需要有人对着设备说话，我做不了。

### 12.5 记下来的两件事

- **`install` ≠ `deploy`。** 对一台已经装好的 Host，`install` 会在预检处失败并告诉你用
  `deploy`。先跑不带 `--apply` 的计划预览没能暴露这一点 —— 计划阶段通过了，守卫在
  apply 时才跑。**计划成功不等于 apply 会成功。**
- **release 按各仓 HEAD 打包，没有 pin**（`eidolon-rk3588.toml`:「A release is defined by
  what the repositories hold」）。所以「只发我这一个提交」做不到，除非用
  `--revision <source>=<40hex>` 把其余仓钉住。本次就是这么钉住 `eidolon_hub` 的 ——
  当时它正在崩溃重启（几分钟内 `NRestarts` 144 → 153），而 pending 的两个 hub 提交
  正是在修它。

---

## 13. C1 在真机上没生效（2026-09-16 00:26）—— 以及 §9/§12 的更正

> **更正 §9 与 §12。** 两节都写着 C1 会让设备会话的 trace 变成
> `<owner>__<companion>__…`。**实测没有。** 一次真实设备对话（00:26，72 秒，一个完整
> 轮次）写出的仍然是
> `unknown-owner__unknown-companion__esp32-9feaa164-9e0fcb8f-00000001.ndjson`。
>
> C1 的**代码**在板子上（`context_resolver` 8/4/2 处），配置也在（`recording: true`）。
> 不生效的是**逻辑**，不是部署。

### 13.1 证据链：相差一毫秒

| 时刻 | 事件 |
|---|---|
| 00:26:38 | Kernel `GET /body-endpoints/<device>` → **200 OK** |
| 00:26:39,017 | Data `GET /companions/c_1291536…/runtime-snapshot` → **200 OK** |
| 00:26:39,**018** | `WARNING agent.observability.turn_events Channel turn events disabled: device event context requires an owner and a Companion mounted…` |

解析器拿到了正确的 Companion，**下一毫秒** C1 判定「没有 Companion」。

Kernel 侧数据是齐的（带 `X-Eidolon-Owner` 头查得到；不带头会拿到
`{"detail":"trusted local owner hint is required"}` —— 我第一次就是把这个错误体当成
文档读了，一度误判为「没有 assignment」）：

```
spec.companion_id             c_129153685f855ff3b2062301fb3ceda0
status.effective_companion_id c_129153685f855ff3b2062301fb3ceda0
conditions                    ["Realized"]
```

### 13.2 最可能的根因（未最终确认）

`_resolve_context` 拿到 companion 之后有一道身份互校：

```python
context = await runtime.resolve_companion(companion_id, device_id=device_id)
if (context.owner_id != owner_id
    or context.companion_id != companion_id
    or context.device_id != device_id):        # ← 嫌疑在这
    raise DeviceTokenResolverError("Companion runtime does not match mounted Device owner/target")
```

而 `runtime-snapshot` 的返回**不含 `device_id`**（实测）：

```
owner_id     'owner_129153685f855ff3b2062301fb3ceda0'
companion_id 'c_129153685f855ff3b2062301fb3ceda0'
device_id    None          ← payload 里没有这个键
```

**一处没解释通**：同一个 `resolve_room` 也是设备 token 的来源，而这次对话是成功的。
若互校真的抛了，token 路径也该失败。所以要么 token 走了别的分支，要么抛的是别的条件。
**没有继续猜，改成让错误自己说话。**

### 13.3 这是 C1 自己造成的：我把原因扔了

```python
except Exception as exc:
    logger.debug("mounted Companion unresolved: %s", exc)   # DEBUG，线上不可见
    return ""
```

当时的理由是「让调用方只报一个清晰的拒绝，而不是两种不同的错误」。**这个理由是错的** ——
它丢掉了唯一能定位故障的信息，于是「mount 没挂人」「Kernel 连不上」「互校不匹配」
三种完全不同的故障在日志里是同一句话，且与「追踪根本没开」同形。

**这份文档从头到尾在骂的就是这个形状，而 C1 自己又造了一个。**

已修（channel `claude/trace-why` → main）：`_mounted_companion` 改为返回
`(companion_id, reason)`，拒绝信息指名缺的是哪一半、以及找它的过程怎么结束的：

```
device event context incomplete: missing companion_id
  (the runtime resolver refused: Companion runtime does not match mounted Device owner/target)
device event context incomplete: missing companion_id
  (no runtime resolver was handed to this observation)
```

三条原因各有一条测试，并做了变异验证（把 reason 清空 → 三条全红）。
`tests/agent/` 全量 1065 passed，ruff 干净。**除消息外无行为变化。**

### 13.4 下一步

发一版带这个改动的 release，再说一轮话。日志会直接写明是哪一半、为什么 ——
不用再推理。届时再回来改 §9 / §12 / 本节。

---

## 14. 走通了（2026-09-16 01:30）—— 兼 §9 / §12 / §13 的结论

一次真机设备对话，写出的文件是：

```
owner_129153685f855ff3b2062301fb3ceda0__c_129153685f855ff3b2062301fb3ceda0__esp32-a3c0b315-84cf554b-00000004.ndjson
```

`session_open` 记录里 `owner_id` / `companion_id` 都在，部署后**再没有一条拒绝告警**。

### 14.1 §5 的那个前置依赖已经解除

```
GET /v1/session-traces?owner_id=owner_129153685f855ff3b2062301fb3ceda0
→ recording: true, matched: 1
```

§5 写的「在 C1 落地之前，按 owner 过滤的列表恒为空，这时候做第 3 步就是一块永远显示
『没有记录』的屏」—— **这一条现在不成立了**，按 owner 能查到真实会话。第 3 步（单会话
瀑布屏）的前置齐了。

### 14.2 真正的根因：我读错了对象的形状

C1 第一版在真机上完全不生效，三轮对话都写成 `unknown-owner__unknown-companion`。
根因不是 Kernel、不是部署、不是配置：

`_resolve_context` 的最后一行是 `return resolved.runtime` —— 它**把 wrapper 拆掉**
再返回。所以 `resolve_room` 交给观测侧的是一个裸的 `ResolvedRuntimeIdentity`
（pydantic），字段是 `['companion_id', 'device_id', 'owner_id', …]`：

- 没有 `.runtime`
- 没有 `.answering_companion_id`
- `companion_id` 就摊在对象上

而 C1 只认前两个形状，两个都落空，于是走兜底分支，**指着一个完好的 Kernel mount 说它
没挂 Companion**。

我是照着 `resolve_channel_context` **内部**返回的形状写的提取逻辑。
**一个函数内部返回什么，和它的调用方往下传什么，是两件事。**

### 14.3 为什么测试没拦住：假对象附和了错误

C1 的测试用 `SimpleNamespace` 构造解析结果，而我给它戴上了 `.runtime` ——
**那个替身是按我的误解捏的，所以它当然同意我**。真机上那个类型根本不是这个形状。

修复后的测试改用**真的 `ResolvedRuntimeIdentity`** 构造。这是手搓替身给不了的唯一事实：
调用方实际交出来的类型。把直读 `companion_id` 的两行删掉 → 该测试变红，精确复现线上故障。

**教训**：替身可以证明逻辑自洽，证明不了它面对的是真实形状。跨模块边界的提取，
至少要有一条测试拿对面真正的类型来构造。

### 14.4 诊断本身是这轮最值钱的改动

三轮里前两轮各废掉一次真机对话：第一轮代码没上板（`install` 用错，见 §12.1），
第二轮上了但消息还是旧的。真正让事情结束的是 `eb79e63` —— 让拒绝说出**是哪一半缺了、
以及找它的过程怎么结束的**。它一上线，一行日志就把范围从「整条链路」缩到「某个分支」，
再一次真机探针（拿部署代码打真 Kernel）就锁死了根因。

对照 §13.3：C1 原来把异常降到 DEBUG 吞掉，三种故障在日志里长得一模一样、且与
「追踪根本没开」同形。**把原因说出来，比把失败藏干净，值钱得多。**

### 14.5 现在的状态

| | |
|---|---|
| 板子 | `eidolon-opi5max`，release `rk3588-trace-shape-1` |
| 追踪 | `recording: true`，按 owner 可查 |
| C1 | 生效，文件名带主人与 Companion |
| M1 | `runtime_session_id` 已在 `CockpitTurn` 上（§8），还没人读 |

**下一步是第 3 步**（mobile 单会话瀑布屏），它的所有前置现在都成立了。

---

## 15. 第 3 步已实现（2026-09-16）—— 尚未在真机上点过

§0 的结论现在是可运行的代码。**但没有在 Host 上走通过一次**，见 §15.4。

### 15.1 M2：管理面透传（eidolon_admin `c86aed5`）

`GET /api/management/v1/session-traces[/{session_id}]`，纯转发，不解析不聚合。

**唯一增加的是 provider 不可能知道的事：谁在问。** provider 的详情接口不带 owner
（只听 loopback、信任调用方），原样转发等于「报一个 id 就能读别人的会话」。所以这条
路由核对返回摘要里的 owner，不匹配答 **404 —— 与 id 不存在完全同一个回答**，
否则它就变成一个「探测某会话是否存在」的接口。

两处被既有守卫逼着收窄，都没有绕过：

| 守卫 | 反应 |
|---|---|
| `test_no_operation_accepts_an_owner` 不认 `kinds` 查询参数 | **删掉 `kinds`**，而不是加白名单。瀑布图本来就要全部记录；CLI 直连 provider 仍可用它 |
| `test_no_management_mutation_depends_on_mission_control` 拦下我从 Mission Control 借的私有 `_service_json` | **在本模块内实现那 15 行**。session trace 与运行投影无关，为省十五行撑大那份名单等于把守卫花在便利上 |

### 15.2 A1–A3：Mobile（eidolon_client_mobile `c8a44fb`）

- **入口是下钻**：活动 → 轮次 → 「工程细节 →」，按 id 读一次会话。**不分页** ——
  这也是 provider 缺游标从头到尾没成为问题的原因（§3.2 早就预言了这一点）
- **没有会话 id 时按钮不画**，而不是画一个灰的。按不动的按钮是同一个死屏，只是多一步
- **屏幕上没有一个数是客户端算的**。耗时、会话 mark、没走到的环节，全是写入方测的
- 没测到的阶段显示 **未测到** 且**不画条** —— 零宽的条读起来是「瞬间完成」，
  那恰恰是它唯一不是的意思
- **用写入方的词表**（`commit_to_llm_first_delta`），不翻译：看这块屏的人正在 grep
  这个字符串，再起一套名字会让日志和屏幕对不上

### 15.3 解析器是照着真实录音写的

动手前先从板子上拉了一份真 trace 看结构：`session` 摘要 + 五种 `record_kind`，
每条 `turn_final` 带 28 个 `durations_ms`（含 null）。

**这是上一个 bug 的直接教训**（§14.3）：那次的替身是按我的误解捏的，所以它附和我。
测试 fixture 用合成值 —— 真记录的 `attrs` 里有对话正文，不该进仓库。

### 15.4 ⚠️ 尚未验证的部分

**代码通了、测试绿了（mobile 1028 passed / admin 887 passed），但没有在真机上点过一次。**

原因：M2 只在 main 上，**没有部署到任何 Host**。2026-09-16 10:48 实测台面上是
`eidolon-pi5`（跑着 09-11 的 release），opi5max 不在本机可达的任何网络上
（MAC `c0:74:2b:…` 不在任何接口的 ARP 里；`192.168.100.19` 无路由）。

所以下一步是**部署 admin 到手机正在用的那台 Host**，然后：

1. 打开驾驶舱 → 点一条 `voice_turn` 活动
2. 看是否出现「工程细节 →」（出现 = `runtime_session_id` 一路走通了，§8 的 M1 生效）
3. 点进去，确认瀑布图有数

第 2 步本身就是 M1 的真机验证 —— 在此之前 `runtimeSessionId` 是一个**还没有人读过**
的字段（§8.6）。

---

## 16. 真机跑通（2026-09-17 00:28，eidolon-opi5max + PHK110）

§0 那个判断，现在是一块在手机上显示真实数据的屏。

### 16.1 屏幕上的东西

一次真实设备对话（00:08:15，70.95s）产生的记录：

```
这次会话持续 70.95s，以 session_ended 结束。
会话   esp32-67931301-18aa2b1f-00000001
伙伴   c_129153685f855ff3b2062301fb3ceda0
模式   full_duplex

会话建立
  room_joined                  -87.7ms
  runtime_participant_resolved   1.1ms
  warmup_done                  177.0ms
  session_started              315.7ms
  first_turn                     5.00s
没走到：avatar_ready

轮次 1 · 事件 14
91243950f06f4c50 · agent_audio_playback_done
  speech_stop_to_commit           368.0ms  ▬
  commit_to_llm_first_delta       634.2ms  ▬▬
  commit_to_tts_first_audio         1.08s  ▬▬▬
  vad_start_to_interrupt_resolved  未测到   （不画条）
```

设计里的每条纪律都在屏幕上成立：没测到的**说「未测到」且不画条**；用**写入方的词表**不翻译；
条长按**最长的已测阶段**而非总时长；`没走到` 是主机给的名单，不是客户端算的。

`first_turn 5.00s` —— 会话建立到第一轮花了五秒。这块屏存在的理由就是让这种数字有地方显形。

### 16.2 为什么第一次没看到按钮：装的 App 比功能老

第一次点没有「工程细节」。不是代码、不是主机：

```
手机上 App  lastUpdateTime = 2026-09-16 00:02:30
下钻提交     c8a44fb        = 2026-09-16 01:57
```

**装机比功能早 1 小时 55 分。** 重新 `flutter build apk --debug` + `adb install -r`
（`firstInstallTime` 不变 = 覆盖安装，配对与 Controller 会话保留）之后，一次就出来了。

**记下来**：验证「功能在手机上有没有」之前，先核对 `lastUpdateTime` 和那个提交的时间。
这和 §12.1 是同一类错误 —— 我当时也是对着一台没装新代码的 Host 反复验证。

### 16.3 验证顺序：先核对进程，再信功能

opi5max 部署完，先跑的是**进程 / release 一致性核对**，16 个单元全部 OK，然后才看功能。

这个顺序是 §15 那次事故换来的：pi5 上 provider 跑着一个**已被删除的 release**，
接口答 404，而 `systemctl`、`/health`、`current` 链接、`eidolon-ops pending`
（"every source matches it"）**全部是绿的**。当时差点把它误判成「M2 没部署」。
那个部署缺陷已另开任务。

### 16.4 一处自己造的瑕疵，当场修掉

长键名在 190px 标签列里从单词中间断行：`commit_to_brain_request_starte` / `d`。

这块屏的读者正拿着日志逐字比对这些标识符，**把一个名字劈成两半的代价，高于这个布局
省下的纵向空间**；截断加省略号更糟 —— 这些名字的区别正在尾部。改成
**键名独占一行、条与数值在下一行**，任何长度都不再断。真机复验：
`stt_speech_to_evidence_sufficient_transcript`（44 字符）与
`interrupt_actionable_transcript_to_cancel_resolved`（49 字符）都在一行内。

**残留一处，没修**：未测到的行没有条，于是 `未测到` 独自落在第二行，视觉上容易被读成
下一个键名的值。节奏是一致的（键在上、值在下），可以学会，但不是一眼就对。
下次做这块屏时值得再看一眼。

### 16.5 完整链路

| 环节 | 提交 | 真机验证 |
|---|---|---|
| C1 会话归属 | `ebf8f0f` → `d622069` | ✅ 文件名带主人与 Companion |
| 诊断可读 | `eb79e63` | ✅ 一行日志定位到分支 |
| 配置放开 | `fa67925` | ✅ `recording: true` |
| M1 join key | `fe7cf1d` + `208703a` | ✅ turns lane 的 id 与 trace 文件名逐字相同 |
| M2 透传路由 | `c86aed5` | ✅ Owner 面 401 / 假路由 404 / 内部面 200 |
| A1–A3 下钻与瀑布 | `c8a44fb` | ✅ 手机截图 |

四个仓，全部在 main。**§5 的前置依赖清单已全部解除。**
