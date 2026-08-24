# Mission Control · Local API 契约（提案 v1）

状态：**提案**。消费侧（Mobile）已按此形状定型；生产侧（`eidolon_admin` Local API）
尚未实现。
基线：2026-08-24，对照 `eidolon_admin/server/eidolon_admin_server/local_api/`
与 `app/mission_control/`（Console 侧现有投影）。

这份文档只定一件事：**Mobile 星图要读什么，谁有资格回答，读不到的时候长什么样。**
它不发明新能力 —— 每一个字段下面都指名了今天已经在生产这份事实的权威。

---

## 1. 端点

```
GET /api/local/v1/mission-control/snapshot
GET /api/local/v1/mission-control/events?after_event_id=<id>&after_ts=<iso8601>
```

认证：`Authorization: Bearer <controller session token>`，与现有 Local API 一致。

**Owner scope 由服务端从 Controller principal 推导**（`_owner_principal`），
请求里没有 `owner_id`。Console 的 `/api/mission-control/snapshot?owner_id=…` 是控制面
的能力，Mobile 不得拥有它 —— App 不能自报它在看谁的域。

只读。这两个端点不接受任何 mutation，也不承载任何 mutation 的结果。

---

## 2. 三条贯穿全文的规则

### 规则一：读不到的块是 `null`，不是 `[]`

每一个投影块都可以是 `null`。`null` 的意思是「这一块没读到」，`[]` 的意思是
「读到了，是空的」。**两者不能混**。

这不是洁癖。这个项目已经为它付过一次代价：一次上游失败到达界面时，长得和
「什么都没发生」一模一样，于是有人花了一整天找一台其实早就到了的设备。现有的
`GET /api/local/v1/devices` 已经在守这条规则 —— 设备权威不可用时它返回 503
「Device authority is unavailable」，而不是 200 加一个空列表。

每个 `null` 块必须在 `sources[]` 里有一条对应的 `unavailable`，说明是谁没答。

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

### 规则三：截断必须看得见

每个列表都有上界。到界时同一个块里的 `truncated: true`。**静默截断读起来就是
「全部就这些」**，这在观测面上是谎。

---

## 3. Snapshot 载荷

```jsonc
{
  "contract_version": "1",
  "coverage": "owner-runtime",
  "generated_at": "2026-08-24T05:16:18Z",

  "owner":       { … } | null,
  "companions":  { "items": [ … ], "truncated": false } | null,
  "devices":     { "items": [ … ], "truncated": false } | null,
  "activities":  { "items": [ … ], "truncated": false } | null,
  "turns":       { "items": [ … ], "truncated": false } | null,
  "jobs":        { "items": [ … ], "truncated": false } | null,
  "memory":      { … } | null,
  "services":    { "items": [ … ], "truncated": false } | null,
  "events":      { "items": [ … ], "truncated": false } | null,

  "sources": [ { "source": "hub", "state": "ok", "detail": "", "observed_at": "…", "latency_ms": 12 }, … ],
  "cursor":  { "event_id": "…", "ts": "…" } | null
}
```

`extra = forbid`，与现有 Local API 模型一致：多出来的字段是契约违反，不是向前兼容。

### 3.1 `owner`

| 字段 | 类型 | 权威 | 缺失语义 |
|---|---|---|---|
| `owner_id` | str ≤64 | data | 必填 |
| `display_name` | str ≤128 | data | **空字符串就留空** —— 不用标识符顶替名字 |

### 3.2 `companions[]`（≤32）

| 字段 | 类型 | 权威 | 说明 |
|---|---|---|---|
| `companion_id` | str ≤64 | data | |
| `display_name` | str ≤128 | data | 空即空 |
| `is_primary` | bool | data | 主伙伴 |
| `lifecycle_state` | `active \| pending \| suspended \| removed` | data | 不是在场 |
| `genome_id` | str \| null | agent/data | `null` = 未绑定人格 |
| `memory_realm_id` | str \| null | memory | `null` = 未开通记忆空间 |
| `recall_hits` | int \| null | memory | `null` = 记忆服务没答，**不是 0** |
| `runners_online` / `runners_total` | int \| null | memory | 同上 |
| `write_disposition` | str \| null | memory | |

**伙伴没有在场字段。** 这套系统从未为伙伴发布过心跳，契约里也不给它留位置 ——
留了位置，早晚有人填。

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

### 3.6 `sources[]`

`source`、`state`(`ok|degraded|unavailable`)、`detail`、`observed_at`、`latency_ms|null`。

`source` 取值至少覆盖：`hub`、`agent`、`memory`、`data`、`runtime_blackboard`、
`services`。每个 `null` 的块都要在这里找得到解释。

---

## 4. 事件流

```
GET /api/local/v1/mission-control/events?after_event_id=…&after_ts=…
Accept: text/event-stream
```

- 一条 SSE 事件 = 一条 `event`，字段：`event_id`（稳定、唯一）、`ts`（单调）、
  `source`、`type`、`severity`(`info|warn|error`)、`outcome`、
  `origin`(`live|polling|replay`)、`companion_id|null`、`device_id|null`、
  `turn_id|null`、`milestone`、`summary`。
- **游标是客户端给的**，不是「从现在开始」。Console 侧现在从 now 起头、靠周期
  snapshot 兜漏；Mobile 会切后台，必须能说「我读到这里了」。服务端从游标之后重放，
  客户端仍按 `event_id` 去重（两边都做，重连才不会重放飞镖或静默丢事件）。
- 游标过期（超出保留窗口）→ 一条 `stream.reset` 控制事件，客户端丢弃本地游标并
  重新拉一次 snapshot。**不许悄悄从 now 续上**。
- keepalive：≤5s 一条 SSE comment（沿用现有实现）。
- `retry:` 给出建议重连间隔；客户端另有有界退避。
- **`origin` 里没有 `mock`。** 演示数据只存在于客户端，不上线。
- **流断只表示观测降级。** 不能推导主机、伙伴、设备或语音轮次停了 ——
  这条写进契约，因为它是界面语义，不是实现细节。

---

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

## 7. 分歧点（需要生产侧确认）

1. **块级 `null` vs 整体 503**：本文选块级，理由是一次记忆服务抖动不该让整张星图
   变成一句「读不到」。生产侧若坚持整体失败更简单，消费侧要改的是渲染分支，代价
   落在「一个源坏了整屏黑」。
2. **游标保留窗口多长**：决定 `stream.reset` 多频繁。建议 ≥5 分钟，覆盖一次通勤
   级别的后台驻留。
3. **`recall_hits` 等记忆细节是否值得单独一次跨服务读取**：若代价高，可以先在
   `memory` 块里只给 `realm_id` + `state`，星图的记忆卫星退到「已配置」。
4. **伙伴列表的权威**：`data` 还是 `agent`。今天 Mobile 只能从
   `/workspace/runtime` 拿到主 Companion 一个。
