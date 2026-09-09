# Mobile 标准 Device 对话：需求复核与修正方案

评审日期：2026-09-09。Mobile 基线：`3f1a42e`。

本轮只评审并形成方案，没有修改功能、主机配置或设备数据。截图是历史总结，里面的实机成功记录没有作为本轮验证结果。检查了 Mobile 当前实现、相关提交，以及本地 Hub / Channel / Kernel 的相关代码；本地源码不等于正在运行的主机版本。现有 `docs/my-eidolon-ux-review.md` 保持原样，本方案只处理对话闭环。

## 1. 目标与结论

目标是：选定 Host 后，把这台手机作为该 Owner Domain 下的标准软件 Device 使用；用户在对话界面选择由哪位 companion 应答，并能开始、结束和切换对话。首次接入完成后，日常使用不应反复经过登记、审批或设备管理。

“标准 device 流程”约束的是身份、授权、挂载、通道和会话协议；它不要求用户逐个操作每条协议。App 同时承载 Controller 管理客户端与虚拟 Device，两者可以共用界面，但不是同一个授权主体。提案之后必须展示可核验的本机提案，由用户明确确认批准；只有领取、ACK、通道准备等设备动作自动接续。

2026-09-09 架构复盘修订：撤回初稿中的“一次点击自动提案并批准”。该方案虽保留两个 API 调用，却没有保留既有裁决要求的可见批准环节。以下交互和实施步骤已经同步修正；具体职责与解耦约束见第 7 节。

当前底层大部分能力已存在；主要缺口是没有把它们连成用户可完成的操作，以及恢复过程存在实质断路。截图所说的“同一设备切换两位 companion 并能对话”，即便当时实测成立，也不能推出“当前 Mobile 从入口到切换已经完成产品闭环”。

建议保留标准接入与 Kernel 绑定体系，完成一条窄范围的对话主流程。无需重写 Host 首页、增加 Mobile 专属直连 Agent API，或为了切伙伴强制重新申请 LiveKit token。

## 2. 当前路径与已确认问题

目前首次使用的大致路径：

```text
已选 Host → 打开对话 → 连接我的 Eidolon → 登记这台手机
→ 去批准这台手机 → 通用设备队列中手动选本机 → 明确批准 Enrollment
→ 手动返回对话页 → 等轮询领取凭证/拉通道 → 开始全双工对话

换 companion：退出对话页 → 设备列表 → 找本机 → 设备详情 → 更换关联
→ 再回对话入口 → 再连接 → 开始
```

### P0：缺少对话页内的 companion 选择与接续动作

- `lib/main.dart:55` 只向 `ClientPage` 注入 provisioner、enrollment 和审批队列路由；没有 Host 名称、当前设备绑定、伙伴列表或换绑动作。
- `ClientPage.initState()` 创建 controller，但不启动准备；进入页面后还要点击“连接我的 Eidolon”。
- `device_admission_queue.dart:31` 审批时直接使用 Workspace 的主 companion，未让用户在对话流程里选择。
- 换绑能力实际已存在于 `mounted_devices_page.dart:336`，底层是 `HostProductController.setDeviceCompanion()`，带 `expectedRevision` 并回读设备列表。

影响：用户要求的核心动作留在设备管理深处。一次外部换绑验证成功，只证明底层能切换。

修正：对话页显示 Host、本机已确认的应答伙伴和伙伴选择器；复用既有 roster / assignment 接口。初次审批使用用户选择的 `initialCompanionId`，后续选择使用标准设备绑定。

### P0：页面退出就可能丢失登记上下文

- `lib/main.dart:62` 在构建对话页时新建 `MobileBodyEnrollmentSession`。
- `mobile_body_enrollment_session.dart:120` 的 `_pending` 只在该对象中；`canFinish()` 同时需要它和平台 handoff key。
- 因此，即使 Android 进程和 handoff key 仍在，弹出对话页再重新进入也会创建不持有 challenge 的新 session。
- `actFor()` 将“已批准但上下文丢失”投影成 `waitForExpiry`；controller 取消轮询，页面不给动作。到期也没有定时重新读取以进入下一步。
- Hub `admission/domain.py:68` 确实不允许把已批准 proposal 直接取消，不能只补一个“撤回”按钮。

影响：普通导航就可能把本可完成的接入变成等待过期。当前测试明确验证了“无法完成时不给按钮”，但没有验证用户最终能走出去。

修正：将登记会话提升到 App 持有、按 Owner Domain 与本机身份界定的设备接入生命周期，不能寄存在 HostProductController 的管理登录会话中。页面只展示和触发它；Host 是发现和首次接入的入口，不是设备身份的生命周期所有者。页面返回不遗失正在进行的操作。真正进程死亡另按标准恢复处理；到期做一次有界回读并提供合法重新接入，不使用永远无动作的页面。

### P0：Claim 已生效、但本地引用没保存时，永远等不到通道

- `mobile_body_enrollment.dart:241` 先 ACK，之后才保存 Claim。
- ACK 成功后、保存完成前被终止，或保存失败，可能留下“Host 已 active，本地无引用”的状态。
- `mobile_conversation_provisioner.dart:206` 读不到本地 Claim 时直接返回 `claimActiveWithoutChannel`，没有发 configuration pull。
- 此状态继续每 5 秒重读，而读取不会补出本地丢失的引用。

修正：按照现有 SDK 的持久化/ACK 契约补全提交和恢复顺序；保留已验证 Grant 中必要的非敏感引用及未完成阶段，让 ACK 重试可继续。只有主机回答可用时才进入可对话状态。已有坏状态必须提供合法恢复入口，不能以“等待主机分配”代替本地修复。

### P0：通道失败仍有两层原因丢失

第一层在 Mobile：

- `DeviceControlClient` 用 `DeviceControlRefusal` 同时表达 HTTP 拒绝和无效响应。
- provisioner 只通过 `ChannelRefusal.forDetail()` 映射三个已知标签，忽略 `status` 与 `retryable`；其他标签变成 null。
- null 的 UI 文案却是“主机没有拒绝，只是现在没有通道”，并继续轮询。
- 因而 403、未知 409、无效 JSON、错误 nonce / DeviceRef 等，都可能落入这句错误描述。安全校验本身仍拒绝了响应，问题是后续诊断与恢复被归错类。

第二层在 Hub：

- `hub/channel_reconciliation/application.py:43` 中，投影未就绪、Provider 暂时失败、Provider 永久拒绝、Manifest 无法解析都可能返回空 tuple。
- `hub/device_control/http.py:236` 将结果作为 `channels: []` 返回。日志区分了原因，设备响应尚未区分。

影响：`0d53ba3` 修复了部分 Device Control 拒绝，不代表 Provider 分配失败已经透传。当前“无拒绝就只是暂时等待”的假设不成立。

修正：Mobile 明确区分成功但无通道、明确拒绝、临时请求失败、无效/不兼容响应；未知拒绝保留原始 code。空通道只能说“暂未取得通道，原因尚未提供”。先做有界重试与具体下一步；若需要分配原因，由 SDK 定义标准状态、Hub 填充、Mobile 消费，避免凭日志猜业务状态或添加 Mobile 私有协议。

### P0：已知不可自愈的错误没有可执行恢复动作

- `mobile_body_standing.dart:240` 对 `deviceFactsStale` 明说需要重新登记，同时说明此屏没有入口。
- 该状态的 `canProposeItself` 为 false，自动轮询停止，但只剩手动检查。
- 对 `claimNotActive` 也主要给“去管理端处理”的文字，而非能到达对应操作的路由。

修正：把“重新接入本机”“处理授权”“检查主机服务”等操作接到对应失败上。操作前核对当前 Owner / Device；不要把所有 409 都当成“重新登记”，也不要要求先移除设备。对仅 generation 落后继续保留现有 Authority 更正并回写的恢复方式。

### P1：登记查询选择了第一条本机历史记录

- provisioner 扫描列表，一遇到相同 `device_instance_candidate_id` 就停止。
- Mobile 请求包含 `grant_acknowledged` 的历史记录；Hub persistence 按 `created_at, enrollment_id` 升序返回。
- 同一身份再次登记时，较旧记录可能遮住当前 proposal，令页面检查和推进的不是这次操作。

修正：有进行中的 enrollment id 时定向读取该记录；已持有当前 Owner 的 Claim 时，日常以 Device Control 查询当前状态，不让历史审批队列成为每次开口的必经前置。不得简单改成“永远取最后一条”而忽略当前操作与有效 Claim。

### P1：会话失败后的状态收尾需要一起处理

- `join()` 在 `openSession()` 返回后才写 `_inConversation` 并设置 `asked`，很早到达的 `session_started` 存在被覆盖的时序风险。
- Mobile 没有等待 `session_started` 的有界超时；Channel adapter 的 10 秒 serving 检查目前只记录日志，不能保证设备退出“接通中”。
- `EidolonSession.disconnect()` 不清理 `_conversationId`，而 `openSession()` 用 `??=` 保留旧 id；当前 controller 掉线后把对话结束并回到 ready，需要明确之后是恢复旧对话还是开启新对话。
- `transcript` 未按会话分段或在新会话开始时重置。加入伙伴切换后，不能让 A 的文字继续以 B 的当前对话展示。
- 正常退出页面仅 dispose 通道，没有显式编排 close session；结束发送失败也缺少完整的本地收尾保证。

修正：使用当前 conversation id 和操作序号隔离异步回包；在发送前建立本次请求状态；匹配到当前会话的确认才更新 UI。超时后停止采集并给“重新连接对话”，不猜测具体服务故障。明确结束/重新开始语义，正常退出先关闭会话，再释放资源；本地清理用 finally 保证。历史按会话与伙伴归属展示。

### P1：Host 上下文与本地 Claim 作用域不一致

`PlatformMobileBodyClaimStore` 是全局单槽，`loadFor()` 只按 operational key 检查；provisioner 未先核对 Claim 的 Owner Domain 与当前选择的 Host。相同 key 切换 Host 时，可能拿上一域引用去询问新域，最终显示难以理解的拒绝。

修正：先校验选中 Host 的 Owner Domain、当前 Claim 与设备身份。现有生命周期裁决明确 V1 是单 Owner Domain + 多 Controller；不能通过增加多槽 Claim 存储把一个虚拟 Device 改成多域设备。相同 Owner 内重新发现或换 Host 复用身份；不同 Owner 时按标准归属转移/重新准入规则处理，不能静默迁移。此项不改变单域内 companion 切换。

## 3. 应当保留的已有改动

| 改动 | 评审结论 |
|---|---|
| `5e9225d` 软件 Body 提案与 configuration pull | 核心能力，应保留；改进编排和恢复即可。 |
| `d86d56f` 自动兑换已批准 Grant | 正确；领取和 ACK 是设备动作，不应反复要求用户点击。 |
| `ef3d227` 会话请求补 conversation id | 必需；进一步完善重连与晚到事件的隔离。 |
| `5f21265` 移除硬编码的对面名字 | 正确，但匿名只是不再误标，还缺少由权威绑定提供的伙伴身份。 |
| `e8f25c2` 区分请求、接通、有听到、远端离开 | 证据区分有用；应服务于少量用户可理解的状态，不能让内部状态数决定页面数。 |
| `0d53ba3` 透出拒绝原因 | 方向正确，映射和端到端原因传递尚未完成。 |
| `51a6983` 分开自动检查与手动检查 | 应保留；还需补真正能改变状态的恢复操作。 |
| `d9220bc` 读取并回写 Authority 更正后的 DeviceRef | 正确，应保留；不能退回“先删设备”恢复。 |

整体问题不适合通过回滚这些提交解决。很多提交确实修了局部缺陷，但验收停在“状态说得对、某个按钮存在”，没有收束成最初的用户任务。

## 4. 建议交互

### 已接入手机的日常路径

```text
Host → 对话页（自动准备）
       顶部：返回 / 当前 Host
       应答伙伴：Aria ▾
       主按钮：开始对话
       对话中：静音 / 结束 / 切换伙伴
```

进入页面自动检查现有身份和通道，不自动打开麦克风。保留最近由主机确认的伙伴绑定；无需再次登记或批准。准备尚未完成时，点击开始可记住本次意图，准备完成后接续，避免再要求一次“开始”。权限被拒绝、离开页面或切换 Host 时取消该意图。

### 初次接入

同一对话流程内分两次明确动作，不跳到全设备队列寻找本机：

1. “登记本机”：虚拟 Device 用标准 commissioning evidence 提出 Enrollment。
2. 提案返回后展示“这是你手上这台手机”、目标 Owner、operational key 指纹比对结果及应答伙伴选择；用户点击“确认接入并开始对话”，Controller 管理端才提交针对该提案的 ApprovalDecision。

批准后自动接续本机领取、验证并 ACK，等待标准挂载/通道事实，再开始会话。每一步仍走现有标准端口；voucher 只提供提案资格，不能当作 Approval。没有 Controller 决策权限时，由有权 Controller 在同样的管理路径批准，设备运行模块仅等待结果。

审批对象必须锁定这次 enrollment id / revision / 设备密钥，不能默认选队列第一项，更不能批量批准别的设备。复用现有审批的投影校验、稳定幂等键和决策提交逻辑，仅改变展示范围为“当前本机提案”，不能复制一个自批准实现。通用设备队列继续服务外接设备管理。

### 动态切换 companion

本方案采用现有架构语义：由 Controller 改变本机 Body endpoint 的持久 `BodyAssignment`，下一次对话使用新伙伴；不是同一个已启动会话里替换人格，也不是全 Host 的默认伙伴切换。UI 应说明“更改本机应答伙伴，后续对话沿用”。只有用户明确更改伙伴时写 assignment，普通开始/结束对话不写，不以频繁改写再恢复绑定模拟临时会话路由。

1. 从当前 Host 的 roster 选择可用伙伴。
2. 对话进行中时，选项明确为“切换到 B 并开始新对话”，先结束 A 并关闭麦克风。
3. 经 Controller 管理端的窄能力调用现有 `setDeviceCompanion(deviceId, expectedRevision, companionId)`，由现有 Host 管理工作流向 Kernel 的标准 BodyAssignment 权威提交；虚拟 Device 不能凭设备密钥自行改绑。
4. 回读主机确认的绑定；遇到 revision 冲突重新读取并展示，不把本地选择直接当作已经生效。
5. 开启新的 conversation id，调用既有 `session_open`；切换失败留在可恢复状态，不以 B 的标题继续 A。

本地 Channel 代码确认：Device token 的 metadata 不带 companion id；每个新 serving dispatch 都以新的会话建立，resolver 可从 Kernel mount 获取应答伙伴。所以不应仅因选择变化就强制重建整个通道或重发 Claim。

“当前绑定是 B”和“本次实际应答是 B”需要分开。当前协议若不提供实际 responder 信息，UI 写“已选择 B”，不要伪称已确认由 B 接听。竞争更新场景如需严格确认，由共享 SDK 扩展标准会话反馈，不能由 Mobile 自行增加未经契约支持的字段。

### 异常时的唯一主动作

| 状况 | 页面提示与动作 |
|---|---|
| 正常准备中 | 保持当前页，有界等待，可返回。 |
| 尚未启用本机 | 登记本机，随后明确确认当前提案。 |
| 真正需要 Owner 批准 | 批准本机 / 等待指定授权人。 |
| 未选择伙伴 | 选择伙伴；不反复尝试启动无人应答的会话。 |
| 临时网络失败 | 重试连接，保留已完成登记和当前选择。 |
| 无效响应、未知拒绝或缺失 authority | 准确说明无法完成；技术详情保留原始原因，提供对应主机检查入口。 |
| 凭证需要恢复 | 恢复接入本机，采用标准恢复流程，不默认移除。 |
| 已批准提案不可继续、尚未过期 | 显示具体原因、到期时间和返回入口；到期回读后允许下一步。 |
| 开始后未得到确认 | 有界结束“接通中”，停止采集，重新连接对话。 |
| 远端离开 | 明确中断并停止采集，提供重新开始；不先要求用户手动结束一次死会话。 |

设备 ID、指纹、Claim/Grant、Hub、AEC 标签、分配详情进入可展开诊断。常规页面只讲当前主机、伙伴、对话状态和下一步。

## 5. 实施范围和次序

### 第一批：修复会永久卡住的恢复路径

修改现有 provisioner / enrollment session / claim store / controller，不先建设新的通用状态机框架：

- 设备接入生命周期脱离对话 Widget 和 Host 管理登录会话，固定当前 Owner Domain 和本机上下文。
- 修复 Claim 本地持久化与 ACK 的断点、同一逻辑操作的幂等键稳定性。当前 `propose()` / `complete()` 每次调用生成新 command id，网络结果不确定时不能把重试当成新意图。
- 分开未知拒绝、无效响应和空通道；增加有界重试与恢复动作。
- 定向恢复当前 enrollment，避免历史记录遮挡；到期可继续。

进程死亡后的 handoff 恢复若需要持久化秘密，应使用受保护的平台存储并与 SDK 的标准设备规则对齐，不能只把 collection challenge 写入普通偏好存储。缺失且确实不可恢复的秘密只能按主机允许的状态迁移退出；方案不承诺凭空恢复。

### 第二批：完成对话页中的选择与首次启用

- 管理入口复用已认证 Host 会话；已接入设备经可信 Owner 目录与 Device Control 自动准备，不把管理登录设为日常设备运行前提。
- 应用编排层通过窄能力接入现有 roster / mounted device / assignment，设备通道与音频会话层不依赖这些管理能力。
- 首次启用在当前流程展示精确的本机提案，经用户明确批准后自动完成设备后续步骤。
- 加上 Host、伙伴、返回入口和对话中切换；不重做整个 App 导航。

### 第三批：关闭会话生命周期缺口并清理展示

- 确认超时、早到/晚到事件、掉线后的 conversation id、本地收尾和字幕分段。
- 需要服务端提供的信息，先在 SDK 定义最小标准增量，再由 Hub / Channel 实现并做兼容处理。
- 删除过时的“当前版本不会”解释、失实注释及 README 中已不符合现状的对话入口描述。技术因果保留在文档和诊断中。

三批属于同一闭环的交付步骤；不能第二批 UI 完成后就宣称整个需求验收通过。

## 6. 验收：按操作任务，不按状态枚举

修正前的基线：以下七个测试文件，69 项全部通过：

```text
conversation_screen_dead_end_test.dart
mobile_body_dead_end_test.dart
mobile_conversation_channel_test.dart
conversation_standing_test.dart
session_lifecycle_test.dart
device_companion_binding_test.dart
mobile_body_enrollment_session_test.dart
```

这是现有单元/Widget 回归结果，不是本轮真机端到端验证。尤其未知标签的现有测试仍期望 `channelRefusal == null`，而 UI 将 null 解释为“主机没有拒绝”；部分测试在固定错误分类，需随修正更新行为断言。

交付前必须补齐以下场景：

1. 新手机从选 Host 到实际语音应答，在一个对话流程内完成；日志可关联提案、决定、Claim、mount、conversation id。
2. 已接入手机再次打开，自动准备，点击开始即发起会话；不再要求登记、审批或重绑。
3. 同一个 `device_instance_id` 在 A → B → A 间切换，每段确由对应伙伴回答；Claim 身份不因切伙伴重建，其他设备和全局默认伙伴不变。
4. 登记后返回/重进，审批页往返，App 前后台；本可完成的 enrollment 不因导航被遗失。
5. 在 proposal 回包、collect 回包、ACK 回包、本地保存前后分别模拟失败/进程死亡；能继续或走到有终点的合法恢复。
6. 空通道、403、未知 409、临时 5xx、错误 JSON/nonce/DeviceRef：分类准确、不会永久轮询、每种失败有下一步。
7. 旧 DeviceRef 可自动校正；本地 Claim 缺失不无限等通道；重新登记不先删挂载与绑定。
8. 多份本机 enrollment 与其他设备混在列表中时，审批和恢复只操作当前本机提案。
9. 开始后无人接听、远端退出、网络断开、确认早到、旧会话结束晚到、切换绑定失败；状态、麦克风和字幕归属均正确。
10. 切换 Host 不向错误 Owner 提交旧 Claim；不通过静默迁移身份使测试“跑通”。

真机证据至少记录 App build、运行中的 Hub/Channel 版本、设备身份和会话关联 id。截图里给出的延迟与语音成功记录只作为历史参考，不作为本次方案已经实现的证明。

## 7. 架构复盘：标准虚拟设备与解耦约束

### 7.1 复盘依据与对初稿的纠正

补读现有[纯软件 Body 准入身份裁决](/Users/manson/ai/eidolon/docs/设备与Body/纯软件Body准入身份裁决.md)及[设备生命周期状态机与恢复边](/Users/manson/ai/eidolon/docs/设备与Body/设备生命周期状态机与恢复边.md)。文档中历史命名与旧实现描述需结合后续修订、当前 SDK 和代码读取，不能照抄过时接口。

- 身份裁决明确“commissioning proof ≠ approval”；W1 要求批准页显式标注本机并提供 operational key 指纹比对。当前 Mobile 架构文档与 Admission 实现也明确将 propose 与批准分开。初稿的单次点击自动提案并批准缺少这个环节，现已撤回。优化的是定位与页面跳转，不是取消 Owner 决定。
- 生命周期文档规定设备信任 Owner Domain，Host 是可替换 endpoint。初稿“提升到 Host / Owner 生命周期”不够准确，现限定为 Owner Domain + Device 上下文，独立于 Host 管理会话。
- 生命周期文档规定 `BodyAssignment` 是持久关系，短期占用不能通过反复改写持久绑定模拟。此次选择明确按持久应答伙伴处理；若未来要求“仅这一轮临时选择”，需单独评审通用契约，不能在 Mobile 内偷偷实现。
- 初稿保留了标准协议，但没有充分规定依赖方向。因此不能说初稿已经足够解耦；实施必须遵守下面的结构。

### 7.2 两种客户端共处一个 App，权限不合并

```text
对话 UI / 薄应用编排（用户意图、步骤接续、只读状态组合）
  ├─ Controller 管理能力
  │    → 既有 HostProductSession / repositories → 已认证 Host 管理入口
  │    → 标准 commissioning / 明确 ApprovalDecision / Kernel BodyAssignment
  │
  └─ 虚拟 Device 能力
       → 平台 operational key + 标准 admission evidence
       → Admission：propose → [等待外部决定] → collect → 验证/持久化/ACK
       → Owner Domain 可信目录 + Device Control：查询本机配置/通道
       → Channel adapter：session_open / session_close / 音视频

权威间仍走已有链路：
Admission 的 Claim 事实 → Kernel 标准挂载/资源投影
Kernel BodyAssignment → Channel 开启会话时解析应答伙伴
```

图表示职责依赖，不要求新增服务、仓库或一套工作流框架。App 的编排不拥有新的 Claim/Mount/Assignment 真相，也不替服务端协调器写数据库。

| 部分 | 拥有的职责 | 不得承担的职责 |
|---|---|---|
| 平台适配 | 密钥、签名、受保护存储、权限、音视频采集 | 审批、Owner 归属、伙伴路由规则 |
| 设备准入 | 本机提案、Grant 验证、持久化与 ACK、标准恢复 | 持有 approve 权限、自批准、选择 Companion |
| 设备配置/运行 | 可信目录、设备身份验证、configuration pull、通道生命周期 | 每次运行读取全域审批队列、依赖管理登录、创建挂载 |
| Controller 管理 | 提案审阅与批准、伙伴列表、标准绑定变更 | 用 Controller token 代替设备证明、替设备解密或 ACK |
| 音频会话 | 消费通道、开关会话、音视频、事件关联与收尾 | 理解 Enrollment、直接调用 HostProductController 或 Kernel、改写 assignment |
| 薄应用编排与 UI | 汇总证据、明确用户操作、串行接续、展示与取消意图 | 自定义授权规则、镜像权威数据库、把多个领域合成一套总状态机 |

### 7.3 对当前代码的最小解耦调整

1. `MobileConversationProvisioner` 目前每次 `provision()` 都调用 Controller 的 `fetchDeviceOnboardingTarget()` 和 `listRecovery()`。将首次接入/异常恢复读取与日常设备配置读取分开。已接入后使用设备持有的可信 Owner 目录及标准 locator/更新规则；缓存必须按标准验签、检查有效性及反回滚，不能靠永久信任旧 endpoint 消除依赖。
2. `MobileBodyAdmission` 目前接收包含 voucher/list/recover/decide 的整个 `DeviceAdmissionPort`，实际只用其中 voucher 能力。缩窄这个接缝，或在组合处传入准备好的标准 commissioning evidence；具体 voucher 获取与 Controller 授权留在管理适配层。不要把 `decide()` 下放进设备准入类。
3. 对话 UI 不直接注入整个 `HostProductController`；在 App 组合处提供 roster、当前绑定读取和 assignment 提交所需的最小接口/回调。继续复用已有 repositories 与授权恢复，避免建第二套管理客户端。
4. `ClientController` 负责交互与会话接续，准入步骤的持久状态仍归现有 enrollment 组件。把异步接续放入薄应用编排，不持续给 controller 增加审批、设备管理、Host 恢复、密钥存储职责。
5. Claim 引用属于 Owner Domain + 本机身份；enrollment 进度属于该域中的具体操作；会话属于 conversation id；显示伙伴名是读取的投影。四者不能靠一个 `ready` 标志相互推断。设备可已准入并有通道但尚无应答伙伴；这只阻止开始对话，不撤销设备接入。
6. 用户改绑成功后启动会话失败，不能自动恢复旧绑定、撤销 Claim 或重做准入。各动作保留自己的结果，UI 从失败步骤继续；同样，失去 Controller 权限仅阻止相应管理操作，设备是否还能对话由其独立 Claim/通道授权决定。

这里的“窄接口”优先复用现有端口或函数注入，只在实际依赖过宽处收口。各语言实现服从同一 SDK 契约和测试向量；不要求先抽出跨平台通用运行时，也不为每个动作新建一层。

### 7.4 不开旁路的可验证条件

- 首次提案仍经过共享 commissioning voucher/evidence verifier；Hub 后续 decisions → collect → ack 使用与其他 Device 相同的实现。软件平台的 provenance 和密钥适配是既有契约差异，不新增 mobile-only route、自动批准或跳过 Claim 的分支。
- 用户“登记本机”后，审批提交次数为零；只有显式确认对应提案才调用标准 Decision。另一 Controller 批准同一提案时，本机也能独立完成 collect/ACK。
- 同一有效 Claim 和可信目录下，禁止测试替身调用 Host 管理 API，设备仍可请求配置并开启/结束对话；Controller 会话到期不能制造 Device revoked。实际 Claim 被撤销时则必须按标准停止。
- 替换同一 Owner Domain 下的 Host endpoint 不改变设备身份或安全代际；V1 不同时持有多域 Claim，不为每次选 Host 创建新设备。
- 伙伴选择只产生标准 BodyAssignment 管理写入；设备身份/Claim 不变，普通开关对话不产生 assignment 写入。服务端仍依据 Kernel 的权威关系解析，UI 不通过 token metadata 或直连 Agent 指定另一个目标。
- ClaimActive 不等于 mount 已完成，mount 已完成不等于 channel ready，channel ready 不等于伙伴已接听；编排必须分别消费相应事实，不因 Mobile 已持有管理权限而推断完成。
- 同一错误语义和 SDK 增量适用于硬件与虚拟 Device；改变共享契约时验证 producer、Mobile 和其他受影响 consumer，不只添加 Mobile 自己能通过的 mock。
- 未获得标准恢复证据时，404/409 不得触发清身份、重铸底座、降 generation 或直接重建 mount。无法继续的步骤返回真实原因与合法操作，不以旁路兑现“始终能继续”的体验承诺。

第 7 节是实施和评审门槛。下面记录本轮实际实现与验证，区分自动化证据与真机限制。


## 8. 本轮实现与验证（2026-09-09）

### 已实现

- 主机详情新增直接对话入口，复用同一个产品对话页。管理连接不再是进入页面的前置门槛；管理能力按需准备。
- `MobileDeviceRuntime` 持有 Owner 范围的 enrollment 操作，页面返回不丢失提案。单个虚拟 Device 的现有 Owner 不会随选 Host 被替换；尚未收到回包的提案也属于进行中的操作。
- `DeviceOwnerDirectory` 保存公开的标准目录和信任材料，沿用既有验签、时效、代际与反回滚边界；Host 管理响应只作为可选位置更新，不能更换已安装的根。目录续期使用已签名的公开 descriptor URI。有效目录在可选管理读取失败时仍可使用，过期目录不能继续使用。
- 持有 Claim 时直接向 Device Control 请求配置，不读全域审批列表；没有本地 Claim 时定位当前或最新未完成 enrollment。未知拒绝、无效响应、403 和可重试通信失败分开处理，保留诊断原因。空通道不推断“主机没有拒绝”。
- 提案重试保留相同 command、证据和 handoff key；collect 重试保留相同 proof。收到 Grant 后先保存本机引用和精确 ACK，再发 ACK。ACK 回包丢失时可以由新进程恢复，不要求 handoff key 仍存在。
- 本页两次显式操作：登记本机、核对指纹与当前提案后确认。只接受匹配本机 identity、Owner、enrollment、revision 与 handoff key 的审阅记录；普通刷新不能触发 Decision。
- 本机应答伙伴沿标准 BodyAssignment 变更并读回确认。会话内切换先 close，再改绑，再 open；每次 open 仍由服务端解析 Kernel mount。重试不改变 Claim、全局默认伙伴或其他设备。
- 接通确认有 20 秒本地等待上限；空通道自动检查最多 6 次，仍未就绪交还明确操作。到期只做一次自动回读。退出、断线、远端离开、迟到的旧会话事件均有收尾；没有 conversation id 的生命周期事件不能确认当前会话。
- 产品页支持 320/390 像素手机与 1280 像素平板；伙伴选择、首次确认、重试、恢复、静音、结束和诊断在同一页完成。错误详情不占据主页面，Owner 冲突提供返回出口。字幕在用户未上翻时跟随最新内容。
- README 更新为实际产品入口。没有新增服务端 route、Mobile 专用授权协议、自动批准或直连 Agent 分支；没有改共享 SDK 契约。

### 自动化证据

最终 `flutter test --no-pub`：872 项通过、5 项跳过；`flutter analyze --no-pub`：无问题；`git diff --check`：通过。Android debug APK 构建成功并通过 `adb install -r` 保留数据安装。

APK SHA-256：`e674c0aa48ff0563eb0f2b8213cf9f23b946a8b6d1d5f1489a9f067b0bb95e01`。源码基线为 `3f1a42e`；本节记录本轮修正的实现与验证结果。

新增 `conversation_approval_test.dart`、`product_conversation_flow_test.dart`、`device_owner_directory_test.dart`，并扩展现有准入/通道/导航回归。覆盖显式审批、错误设备拒绝审批、导航保留提案、ACK 丢包后的新实例恢复、提案原样重试、同一 Device 的 A → B → A、改绑不确定结果的稳定重试、管理不可用、Owner 不匹配、无接通确认、轮询上限和响应布局。

正常界面的截图来自实际 Widget 渲染，使用模拟 Host/Companion 数据，并非真机语音接通证明：

- [手机布局](review/mobile-conversation/phone.png)
- [平板布局](review/mobile-conversation/tablet.png)

### 真机结果与尚未验收项

已在 Android `df331f93` 保留数据更新并操作实际入口。[最终版本的真机入口截图](review/mobile-conversation/device-entry.png)。只读确认本机 Device 为 `device-instance-08b2358fd82bf6c46c182251d5bfb3ab7aea4384e06ca24858921453cfdf268d`，保存的 Owner 为 `owner-f774cf8e1b667eb0ca7b`、owner generation 3、claim generation 1。

当前 `Eidolon-6b1f15`（192.168.1.32）目录给出的 Owner 为 `owner-0342958c2e259f177f43`，与本机 Claim 不同，因此停止跨域接入，未清身份、未重新铸造设备、未改数据库。[最终版本的真机归属冲突页面](review/mobile-conversation/owner-conflict.png)。另一已保存主机 `Eidolon-0a7989`（192.168.1.33）的管理连接可建立，但本次对话目录读取超时；没有据此推断其 Owner。

因此本轮尚不能宣称真实语音应答、真实 A → B → A、多轮中断和全新 Device 的整条准入已通过真机验收。需要现有 Claim 对应的原 Owner 服务可用后继续这些场景；旧截图中的成功记录不作为本轮证据。Hub/Channel 当前运行版本也未作为本轮语音验收版本登记。

## 9. 2026-09-09「主机不匹配」恢复修正

### 已核对的原因

第 8 节记录的是 639dd54 的验收状态。后续只读检查当前 .32 主机的运行数据库发现：同一平板 DeviceInstance 已有 active Claim，Owner 为 `owner-0342958c2e259f177f43`、claim generation 4，且有 2026-09-07 完成的 Grant ACK。本地保存的却是另一个 Owner 的历史引用。不能据此断言另一 Owner 的 Claim 当前仍有效，也不能直接把本地 Owner 字段替换成当前主机。

原实现存在两处缺口：Runtime 在读取本地历史引用后直接拒绝打开页面；“恢复本机接入”调用的是重新提案，而不是恢复已有记录。提示去做尚未实现的设备转移进一步造成死路。

### 修正边界

- Runtime 允许打开页面并说明记录冲突，provisioner 仍禁止把旧 Owner 的引用发给当前主机。进入页面、刷新和取消确认都不修改引用。
- 用户明确点击“恢复已有登记 → 核验并恢复”后，复用标准 Enrollment recovery projection，限定本机 DeviceInstance、当前可信 Owner/代际、已批准且已完成 ACK 的登记。
- 从该记录读取完整 DeviceRef，使用现有 Device Control `configuration:pull` 与本机 operational key 签名；管理端投影只能提供查询线索，不能提供会话授权。
- 只有 Device Control 验证身份并确认 Claim 有效、响应身份/nonce/Owner 代际正确，且本地登记没有并发变化后，才保存返回的引用。下一次普通连接仍直接走 Device Control，不依赖 Controller recovery 查询。
- 缺少本地引用与 Owner 不一致共用这一恢复动作；失败保留原记录和可重试入口，不创建 Enrollment、不签 voucher、不批准、不修改远端 Claim、Mount 或设备密钥。

这是对已存在且已完成授权的登记恢复本地引用，不是为未准入的 Owner 增加接管能力，也不是完整 Owner transfer。若目标 Authority 没有有效登记，此动作不能继续；真正的归属变更仍属于标准设备生命周期。V1 仍只有一个本地 Device 身份和一个当前引用，不增加按 Host 分配的身份或多 Owner Claim 列表。

### 验证范围

新增 `mobile_claim_recovery_test.dart` 覆盖正常打开无副作用、既有登记恢复、缺失引用、错误设备/Owner、未 ACK、ACK 待续、403、撤销、错误 nonce、并发变更，以及 Runtime 不再提前关闭恢复入口。产品页测试覆盖 320 像素屏幕上的确认/取消、失败保留操作和成功后回到“开始对话”。实际设备验收结果另记于本节后续记录，不能由模拟测试推定。

### 真机发现的传输断点

第一次恢复已经读到准入记录，但 `configuration:pull` 因 Android 无法解析 Authority 的 `.local` 名字失败。现有 `DeviceOnboardingTarget.reachedAt` 提供了已连接 Host 的地址，原 Device 传输却没有使用；缓存目录还会在启动等待 3 秒超时后丢弃晚到的地址。

修正复用已依赖的 OkHttp 4.12（现在显式声明依赖），在共用 pinned HTTPS 传输中仅覆写匹配 Authority 主机名的 DNS 地址，原 URL、Host、SNI、Owner 根证书和默认主机名校验保留。重定向与隐式连接重试关闭，应用的幂等边界不变。地址作为独立的本地定位线索保存，不写进签名 descriptor；可选 Controller 查询超时不阻塞启动，晚到且验签通过的结果仍更新 Device 目录。准入 session 在地址变化时也重建传输，保留原 command 和证明。

原生测试以仅用于测试的 PKCS12 证书启动 loopback TLS server，验证正确名字可连接、错误名字拒绝、错误信任根拒绝；该 fixture 不含运行环境密钥。另验证地址不影响其他 Authority、查询编码不变和 Controller/Owner 两种 TLS 模式保持隔离。

### 主机部署与重试体验

恢复后实际下发的旧通道凭据仍带 `.local` LiveKit 地址。Ops 源码已有统一的动态地址配置：未显式声明 LAN IP 时写入 `ws://:7880`，Channel Provider 在签发 binding 时选取当前路由地址。运行配置未同步这项既有机制；本次使用 `host_cli --config config/hosts/mac.toml debug prepare` 更新，再通过 HostController 的标准 supervisor 入口仅重启 channel-provider。没有在 Mobile 改写 opaque binding，没有修改 Hub/Channel 源码或数据库。

标准 prepare 首次被输入目录校验阻止：HostAgent 合约允许的可选 `factory_setup_code` 被私有输入校验当成了未知文件。Ops 的小范围修正直接复用 `OPTIONAL_INSTALL_INPUTS`，保留必需文件、未知文件、权限与 symlink 的原有检查；没有删除已有配置。相关测试 38 项通过，ruff 检查通过。该改动位于相邻 `eidolon_ops` 仓库，需要与 Mobile 修正分别提交。

客户端复用原重连计数，自动尝试三次后停止，显示可手动重新检查的错误状态；手动重试重置计数，成功连接后恢复原状态。页面不再重复显示同一句错误，也不再在停止自动重试后声称还会继续尝试。

### 本次实测记录

平板 `df331f93` 上已完成恢复：本地引用现在是 .32 的 Owner、owner generation 1、claim generation 4、trust epoch 1，DeviceInstance 未变。只读对照运行数据库，远端 Claim 的更新时间仍为 `2026-09-07 13:02:18.065312`，此设备的 Enrollment 总数仍为 4、最新创建时间仍为 `2026-09-07 13:01:19.500756`。这是恢复已有记录的实证，不是重新登记。

自动化验证：Flutter 全套 890 项通过、5 项跳过；最后的状态文案/重复提示调整后相关 14 项重跑通过，analyze 无问题；Android 原生 47 项通过；debug APK 构建成功。后续连接验收结果补记如下。

17:16 后，标准续期签发的 binding 已为 `ws://192.168.1.32:7880`，平板从普通入口进入“设备在线，可以开始对话”。随后完成 Eidolon → Aria → Eidolon 三次实际开始/结束，前两次页面进入“正在回复”，切回后显示“已接通，可以开始说话”。Channel worker 分别在 17:17:30、17:20:34、17:23:16 记录同一个 Device room 的 `session_started`，见 [脱敏会话日志](review/mobile-conversation/claim-recovery-sessions.txt)。结束后回到就绪页，麦克风关闭，选择保留为 Eidolon。

真机截图：[恢复后普通入口就绪](review/mobile-conversation/claim-recovered-ready.png)、[Eidolon 回复状态](review/mobile-conversation/claim-recovered-eidolon.png)、[Aria 回复状态](review/mobile-conversation/claim-recovered-aria.png)、[切回 Eidolon 接通](review/mobile-conversation/claim-recovered-eidolon-return.png)。本轮验证了真实入链、会话确认和伙伴切换；没有进行人工多轮口语、音质或打断延迟测量，也没有用这些结果替代全新设备准入验收。

最终安装的 debug APK SHA-256：`a0862bb64d90c926cefa2a453939d85e8cff2177c71048130e276b76f7de7e09`。本节修复在 `639dd54` 之后单独提交，Mobile 与 Ops 分属各自仓库。
