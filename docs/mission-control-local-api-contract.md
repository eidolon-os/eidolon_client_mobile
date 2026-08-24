# Mission Control 契约（提案 v1）

状态：**提案**。消费侧（Mobile）已按此形状定型；生产侧尚未实现。

> **平面已纠正（2026-08-24）**：本文最初把端点写在 `/api/local/v1/mission-control/*`。
> 那是错的——[多 Companion 方案](../../docs/跨系统/EidolonOS多Companion统一管理架构方案.md)
> §2.3 规定 `/api/local/v1` 上的 Owner 产品端点要迁入 `/api/management/v1` 后**删除**，
> 「收敛是删除，不是并存」。正确端点是
> `GET /api/management/v1/mission-control/snapshot` 与 `GET /api/management/v1/events?cursor=…`，
> 由 management OpenAPI 文档（从路由导出）描述，两个客户端从它生成。
> 本文其余部分描述的载荷形状、lane 规则、在场权威与游标语义都不受平面影响，仍然有效。
基线：2026-08-24，对照 `eidolon_admin/server/eidolon_admin_server/local_api/`
与 `app/mission_control/`（Console 侧现有投影）。

这份文档只定一件事：**Mobile 星图要读什么，谁有资格回答，读不到的时候长什么样。**
它不发明新能力 —— 每一个字段下面都指名了今天已经在生产这份事实的权威。

---

## 1. 端点

```
GET /api/management/v1/mission-control/snapshot
GET /api/management/v1/events?after_ingest_seq=<int>
```

认证：`Authorization: Bearer <controller session token>`，与现有 Local API 一致。

**Owner scope 由服务端从 Controller principal 推导**（`_owner_principal`），
请求里没有 `owner_id`。Console 的 `/api/mission-control/snapshot?owner_id=…` 是控制面
的能力，Mobile 不得拥有它 —— App 不能自报它在看谁的域。

只读。这两个端点不接受任何 mutation，也不承载任何 mutation 的结果。

---

## 2. 四条贯穿全文的规则

### 规则一：每个投影块自带健康状态（lane 封套）

每一块都是同一个形状：

```jsonc
{ "state": "ok" | "degraded" | "unavailable",
  "detail": "",                  // 非 ok 时说明是谁没答、为什么
  "observed_at": "…" | null,
  "latency_ms": 12 | null,
  "items": [ … ] }               // 或标量块的 "value"
```

「读到了，是空的」= `state: ok, items: []`。「没读到」= `state: unavailable, items: []`
**外加一句 detail**。两者不能混 —— 这个项目已经为它付过一次代价：一次上游失败到达
界面时长得和「什么都没发生」一模一样，有人花了一整天找一台其实早就到了的设备。
现有 `GET /api/local/v1/devices` 已经在守这条（权威不可用 → 503，不是 200 加空列表）。

**为什么是 lane 封套，而不是「块可为 null + 平行的 `sources[]`」**（我最初的提案）：
后者把同一个事实编码在两个地方，两个地方就会漂移 —— 总有一天出现一个 `null` 块
配着一条 `ok` 的 source，而读代码的人无法判断哪个是真的。lane 封套让它**不可能
不一致**。

它还刚好是消费侧已有的形状：`runtime_cockpit_page.dart` 里的
`_Lane.loading / value / failed` 就是这个概念，每条 lane 独立失败、在自己的位置
说话。契约和界面用同一个词，是因为它们本来就是同一件事。

### 规则二：在场（presence）必须带上它的权威和新鲜度

Console 侧的 `_device_presence` 已经定好了优先级，这份契约照抄，不重新发明：

| 优先 | 来源 | 判定 |
|---|---|---|
| 1 | `runtime_blackboard`（Owner-scoped NATS KV） | `is_online()`，**看租约**（lease 过期即不在线，即使 status 还写着 online） |
| 2 | `hub` | 逐设备 status：`online / degraded / offline / unknown` |
| — | `data` | **永远不参与**。生命周期状态（如 `active`）不是在场 |

两个权威都没答 → `unknown`。**`unknown` 不是 offline，也不是 online。**

> 更正：我先前说过「Local API 拿不到设备在场」。那话只对现有的
> `/devices` 端点成立（它只读 Kernel mount + Hub 目录元数据）。在场是**可得的** ——
> Console 每天都在用同一批权威读它。所以这份契约要求 snapshot 带上在场，
> 而不是省略它。

### 规则三：状态码只描述请求，永不编码部分数据缺失

`200` = 「这是我能读到的，逐 lane 标好了」。`401 / 403 / 409` = 请求本身的问题。
`503` = 这个端点自己没法工作（比如 Owner scope 都解析不出来）。

**一个源坏了不该让整屏黑。** 记忆服务抖一下就把整张星图变成一句「读不到」，
是把可用性拱手让人 —— 主人的设备和伙伴明明还读得到。

### 规则四：截断必须看得见

每个列表都有上界。到界时同一个块里的 `truncated: true`。**静默截断读起来就是
「全部就这些」**，这在观测面上是谎。

---

## 3. Snapshot 载荷

```jsonc
{
  "contract_version": "1",
  "coverage": "owner-runtime",
  "generated_at": "2026-08-24T05:16:18Z",
  "cursor": { "ingest_seq": 10493 } | null,

  // 每一块都是同一个 lane 封套（规则一）
  "owner":      { "state": "ok", "detail": "", "observed_at": "…", "value": { … } },
  "companions": { "state": "ok", "detail": "", "observed_at": "…", "truncated": false, "items": [ … ] },
  "devices":    { … "items": [ … ] },
  "activities": { … "items": [ … ] },
  "turns":      { … "items": [ … ] },
  "jobs":       { … "items": [ … ] },
  "memory":     { … "value": { … } },
  "services":   { … "items": [ … ] },
  "events":     { … "items": [ … ] }
}
```

`extra = forbid`，与现有 Local API 模型一致：多出来的字段是契约违反，不是向前兼容。

没有平行的 `sources[]` —— 健康状态在它描述的那一块里（规则一）。真正跨块的观测
事实（例如「blackboard 整体不可用，所有设备的在场都退到 hub」）由各 lane 的
`detail` 各自说明，因为**受影响的范围本来就是逐块不同的**。

### 3.1 `owner`

| 字段 | 类型 | 权威 | 缺失语义 |
|---|---|---|---|
| `owner_id` | str ≤64 | data | 必填 |
| `display_name` | str ≤128 | data | **空字符串就留空** —— 不用标识符顶替名字 |

### 3.2 `companions[]`（≤32）

| 字段 | 类型 | 权威 | 说明 |
|---|---|---|---|
| `companion_id` | str ≤64 | **data** | |
| `display_name` | str ≤128 | **data** | 空即空，不用标识符顶替名字 |
| `is_primary` | bool | **data** | |
| `lifecycle_state` | `active \| pending \| suspended \| removed` | **data** | 不是在场 |
| `genome_id` | str \| null | **data** | `null` = 未绑定人格。这是**归属**，不是「已装载」 |
| `memory_realm_id` | str \| null | **data** | `null` = 未开通记忆空间 |

**伙伴的身份权威是 `eidolon_data`，一个。** `eidolon_agent` 运行人格，但伙伴的名字
与身份存在 data —— 这是既有事实（见 Console 侧对 agent 的描述：「伙伴的名字与身份
存在 eidolon_data，不在这里」）。所以 companions lane 只有一个权威，不需要合并两家
的答复。

「人格是否已装载」是 agent 的运行时事实，与归属是两件事。**这一版契约不带它**：
星图今天不画它，而一个没人喂的字段迟早会被误读成在场。要的时候它属于一条独立的
`agent` lane，不是塞进 companion。

**伙伴没有在场字段。** 这套系统从未为伙伴发布过心跳，契约里也不给它留位置 ——
留了位置，早晚有人填。

**没有逐伙伴的记忆细节。** 召回命中从这个伙伴最近一次 turn 上读（`turns` lane
已经带 `memory_hits`），这也正是 Console 今天的做法 —— 它的 `last_recall_hits`
就是从 turns 算出来的，不是逐伙伴问记忆服务。所以：记忆 lane 保持**逐 Owner**
一份（realms 总数、活跃 realm、runners、写入策略），伙伴的记忆卫星显示
「已配置 / 未开通」+ 来自它自己 turn 的召回数。**零次额外跨服务读取。**

### 3.3 `devices[]`（≤100）

| 字段 | 类型 | 权威 | 说明 |
|---|---|---|---|
| `device_id` | str ≤128 | kernel | |
| `display_name` | str ≤128 | hub | 空即空（沿用 `LocalDeviceView` 的理由） |
| `device_kind` | str ≤96 | hub | 硬件类别，**不是**逻辑角色 |
| `role` / `role_kind` | str / `guard\|persona\|unbound` | data（绑定的 companion） | 角色来自绑定关系，不从硬件猜 |
| `companion_id` | str \| null | kernel mount | `null` = 未绑定 |
| `presence` | 见下 | runtime_blackboard → hub | 规则二 |
| `capabilities` | str[] ≤32 | hub / blackboard | |

```jsonc
"presence": {
  "state": "online" | "offline" | "degraded" | "unknown",
  "source": "runtime_blackboard" | "hub" | "none",
  "observed_at": "…" | null,
  "lease_expires_at": "…" | null
}
```

不透出：mount revision、fingerprint、request id、participant sid、房间名 ——
运维面的东西，`LocalDeviceView` 已经剔过一遍，这里同样剔。

### 3.4 `activities[]`（≤64）· `turns[]`（≤32）· `jobs[]`（≤32）

星图最有说服力的部分全靠这三块 —— 活动珠、循环光点、阶段跟随、事件飞镖。

`activity`：`activity_id`、`kind`(`voice_turn|guard_event|device_command|device_event|background_job`)、
`companion_id|null`、`status`、`outcome`(`success|failure|denied|deferred`)、`summary`、
`turn_id|null`、`origin_device_id|null`、`target_device_ids[]`、`current_hop_id|null`、
`started_at|updated_at|finished_at`、`route[]`。

`route[]` 一跳：`hop_id`、`node_type`(`device|companion|service|memory|tool|provider`)、
`node_id`、`label`、`stage`、`status`、`direction`(`in|out|internal`)、`ts|null`、
`latency_ms|null`。

`turn`：`turn_id`、`companion_id`、`device_id|null`、`status`、`trigger`、`latency_ms|null`、
`memory_hits`、`tool_names[]`、`stages[]`（`key/label/status/latency_ms`）。

**`stage.key` 是受控词表**，因为星图、背板波前和路由三处必须指向同一个瞬间：
`input · speech · duck · eot · commit · memory_recall · agent_turn · brain · response ·
tools · tts · playback · memory_write`。生产侧新增阶段是兼容的（消费侧不认识的阶段
不点灯、也不报错），但**改已有 key 的含义不是**。

### 3.5 `services[]`（≤16）

`service_id`、`display_name`、`code`、`mode`、`tier`(`service|middleware|external`)、
`online: bool`、**`checked: bool`**、`latency_ms|null`、`detail`。

`checked=false` 的服务是「未探测」，**不是「正常」**。这一位必须在线上，不能靠
`online=true` 默认。

## 4. 事件流

```
GET /api/management/v1/events?after_ingest_seq=<int>
Accept: text/event-stream
```

### 4.1 事件就是审计封套的投影，不是另一套词表

`eidolon_sdk/contracts/audit/envelope.schema.json`（`eidolon.audit.v1`）已经定义了
这套事实的形状，`eidolon_admin` 的 audit index 表已经在逐行持久化它。星图的事件
**是它的投影**，字段一一对应，枚举**逐字复用**：

| 星图字段 | 审计封套 | 说明 |
|---|---|---|
| `event_id` | `event_id` | 唯一，去重键 |
| `ts` | `occurred_at` | |
| `source` | `producer` | |
| `type` | `action` | |
| `severity` | `severity` | `info \| warn \| error \| critical` —— **复用四值，不裁成三值** |
| `outcome` | `outcome` | `success \| failure \| denied \| deferred` |
| `privacy` | `data_classification` | `safe \| sensitive \| restricted` |
| `companion_id` / `device_id` / `turn_id` / `job_id` | `subject_type` + `subject_id`（+ payload） | 主体引用，投影时展开成具名字段 |
| `trace_id` | `trace_id` | |
| `summary` | 由 `action` + subject + payload 组成 | 人可读，服务端组，客户端不拼 |

消费侧的 `outcome` 枚举今天就已经和封套一致 —— 这不是巧合，是它们本来就该是同一套词。
**新增枚举值必须先进封套**，不能在这个端点上私自扩。

### 4.2 游标是 `ingest_seq`，不是时间窗

> **越界声明（2026-08-24）**：本节是**提案，不是结论**。多 Companion 方案
> **Phase 6** 第 1 条的职责就是「定义 Owner event envelope、cursor、at-least-once、
> 去重规则」，第 2 条还立了顺序:「**先接通 producer，再谈 projection**」——
> 治理事件的唯一 producer 是 Data 的 `audit_outbox` + `AuditOutboxDispatcher`
> （当前没有被任何 entrypoint 接线），且 Admin 直读 authority 库是 PROHIBITED。
> 我下面把游标定在 `eidolon_admin` audit index 的 `ingest_seq` 上，那是 Admin
> 自己的 ingest 投影，**不是 canonical producer 的序**。Phase 6 若把游标定在
> outbox 侧，本节按它改。保留在这里是因为它记录了一个有用的事实（表上已有全序
> 整数与 unique event_id），不是因为它有权决定。

`eidolon_admin` 的 audit index 表主键就是 `ingest_seq: Integer autoincrement` ——
**一台主机上一个全序的整数**。于是：

- 客户端提交 `after_ingest_seq`，服务端从它之后重放。不存在「从现在开始」。
- 客户端按 `event_id` 去重（表上 unique），双端都做 —— 重连时既不重放飞镖也不静默丢事件。
- `producer_seq`（每个生产者单调）随事件透出，客户端可以据此发现某个生产者的缺口，
  而不必信任全序里没有洞。
- **游标只有两种失效方式**：这一行被保留策略清掉了，或者数据库换了（`reset_epoch`
  变了 —— Local API 的 Controller session 里已经有这个数）。两种都发一条
  `stream.reset` 控制事件，客户端丢弃本地游标并重拉一次 snapshot。

所以「游标保留窗口多长」这个问题不需要拍一个数：**它等于 audit index 的保留策略**，
本来就该由那一处决定，端点不再自定义一个平行的窗口。

其余：keepalive ≤5s（沿用现有 SSE comment 实现）；`retry:` 给建议重连间隔，客户端
另有有界退避；`origin` 里**没有 `mock`**（演示数据只存在于客户端）；**流断只表示
观测降级**，不能推导主机、伙伴、设备或语音轮次停了 —— 这条写进契约，因为它是界面
语义，不是实现细节。

## 5. 错误模型

| 情况 | 状态码 | 语义 |
|---|---|---|
| 会话无效/过期 | 401 | 客户端做有界重认证（已有实现） |
| Controller 无此 scope | 403 | 不重试 |
| Owner scope 与权威答复不一致 | 409 | **立刻停止渲染**，不显示别人的域 |
| 某个权威不可用 | 503 | 仅当**整份** snapshot 都读不到时用；部分失败走块级 `null` + `sources` |
| 契约被违反（多字段/类型不符） | 502 | 生产侧自己发现时用 |

响应体：`{ "contract_version": "1", "error": "<code>", "detail": "<人可读>" }`。

**永远不用 200 加空载荷表示失败。**

---

## 6. 消费侧已经按这个形状定型

`lib/src/features/constellation/cockpit_feed.dart`：

```dart
abstract class CockpitFeed {
  CockpitSnapshot? get snapshot;          // 第一次读到之前是 null
  CockpitObservation get observation;     // 观测自身的状态，与事实分开
  Stream<CockpitSnapshot> get updates;
  Stream<CockpitPulse> get pulses;
  Stream<CockpitObservation> get observations;
  Future<void> refresh();                 // 失败必须抛，不许吞
  void pause();                           // App 切后台
  void resume();
  void dispose();
}
```

四个刻意的形状：

1. **`snapshot` 可空。** 真 adapter 在第一个 HTTP 往返之前没有事实。给它一个空
   snapshot 顶上，就等于让「还没读到」长成「什么都没有」。
2. **`observation` 与事实分开**（`connecting / live / degraded / lost` + 原因 +
   最后一次成功读取时间 + 游标）。传输失败有自己的通道，不用伪造一份 snapshot
   来表达。
3. **`pause` / `resume` 在接口里**，因为消费者真的会调它 —— 页面挂在
   `AppLifecycleState` 上。
4. **`refresh()` 失败必须抛。** 静默失败的刷新按钮是最坏的一种按钮。

Local API 落地后要写的就只有一个 adapter：走现成的 `local_api_client` +
`pinned_http_client` + Controller session，把 JSON 填进现有视图模型，由
`HostProductController` 构造并持有生命周期（换主机 / reset epoch 时销毁）。
画的部分一行不动。

## 7. 四个分歧点的结论

上一版留了四个待拍板的点。逐个查过生产侧之后，**四个里有三个不需要拍板 ——
这套代码里已经有答案，只是没人把它们接起来。**

### 7.1 块级失败 vs 整体 503 → **lane 封套**（比我原来的提案更进一步）

原提案是「块可为 null + 平行 `sources[]`」。它对，但不够：同一个事实编码在两处，
两处就会漂移。lane 封套把健康状态放进它描述的那一块，**让不一致不可能发生**，
并且刚好复用消费侧已有的 `_Lane` 概念。

代价说清楚：载荷层要 lane 化（消费侧约 6 处解析 + 3 处渲染），换来的是「一个源坏了
不整屏黑」和「读不到永远不长成空」。

### 7.2 游标保留窗口 → **不需要这个数**

audit index 表的主键就是 `ingest_seq` 全序整数，`event_id` 表上 unique，
`producer_seq` 逐生产者单调。游标用 `ingest_seq`，失效只有两种：行被保留策略清掉，
或数据库换了（`reset_epoch` 变）。**保留窗口 = audit index 的保留策略**，
本来就该由那一处决定，端点不该自定义一个平行的窗口。

### 7.3 记忆细节的跨服务代价 → **零次额外读取**

召回从 turn 上读（Console 今天就是这么算的），记忆 lane 保持逐 Owner 一份。
问题消失，不是被优化掉的，是本来就问错了。

### 7.4 伙伴列表的权威 → **`data`，一个**

伙伴的名字与身份存在 `eidolon_data`；`eidolon_agent` 运行人格但不拥有身份。
「人格是否已装载」是另一件事，属于将来一条独立的 agent lane，这一版不带。

---

## 8. 契约文件应该放哪

**放 `eidolon_sdk/contracts/`，因为那里已经是跨仓契约的家，而且已经有强制机制。**

既有事实：
- `eidolon_sdk/contracts/audit/envelope.schema.json`、
  `contracts/device_foundation/v1/**/schemas.schema.json` —— schema 已经在 SDK；
- `contracts/device_foundation/v1/golden/*.json` —— 黄金向量也在 SDK；
- `eidolon_sdk/tests/contracts/test_client_contract_mirrors.py` —— **SDK 的测试读兄弟
  仓的 checkout**（`eidolon_client_mobile/lib/src/protocol/eidolon_protocol.dart`、
  `eidolon_admin/web/src/protocol/eidolonContract.ts`），断言各语言的镜像常量与 SDK
  定义一致，仓不在就 skip。

所以建议的落法（三件，都沿用既有机制）：

1. `eidolon_sdk/contracts/local_api/v1/mission-control-snapshot.schema.json`
   与 `mission-control-event.schema.json` —— 唯一真源。事件 schema **`$ref` 审计
   封套**，不复制枚举。
2. `eidolon_sdk/contracts/local_api/v1/golden/*.json` —— 若干整份载荷样例，
   含刻意的降级样例（一条 lane `unavailable`）。生产侧和消费侧各自在自己的测试里
   解析同一批文件：Python 用 schema 校验，Dart 在 `test/` 里喂给解析器。
3. 在 `test_client_contract_mirrors.py` 里加一条，断言 mobile 的受控词表
   （stage keys、presence states、lane states、outcome、severity）与 SDK 定义逐字
   一致 —— 这类漂移是静默的，正是那个测试存在的理由。

**注意 SDK 是 Python 包，mobile 不依赖它。** 所以 SDK 里的 schema 对 Dart 不会自动
生效 —— 生效靠的是上面第 2、3 条（黄金文件 + 镜像测试），而不是「放进去就同步了」。
这一点必须说清楚，否则会误以为放对了地方就安全。
