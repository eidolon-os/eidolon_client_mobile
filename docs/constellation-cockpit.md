# Mobile 星图（Constellation Cockpit）

状态：UI 已实现，数据仍是 mock；未接入产品导航
基线：2026-08-24，`lib/src/features/constellation/`

## 1. 这是什么

Admin Web 的 Mission Control 有一张「主权域星图」：主人核心在中心，伙伴作为行星挂
在轨道上，每个伙伴带三颗资产卫星（身体 / 记忆 / 活动），身体作为端口挂在身体卫星
上，链路上有光点在跑。这个模块把**同一个信息模型**搬到手机上。

搬的是模型和质感，不是那张图的尺寸。桌面靠一屏看全，手机靠**移动地图**：

- 打开即「全域」：整张地图完整装进视口，什么都不裁。
- 双指缩放、拖动平移；`⤢ 全域` 回到全景。
- 点行星＝聚焦：镜头飞过去把那一簇抬到检查器卡片上方，兄弟节点后退（语义缩放）。
- 点卫星＝直接落到检查器对应的那一页，不用先进伙伴再翻页。
- 细节随缩放出现：概览缩放下卫星只有字形和颜色，放大到能读了才画标签。
  四像素的标签不如一个诚实的字形。

## 2. 文件

| 文件 | 职责 |
|---|---|
| `cockpit_theme.dart` | 设计令牌（与 Admin 的 `cockpit.tokens.css` 同源）、面板与 LED |
| `cockpit_models.dart` | 视图模型 + 纯语义（状态色调、事件→脉冲、循环腿、阶段→卫星） |
| `cockpit_feed.dart` | 数据来源的接缝：`snapshot` / `updates` / `pulses` |
| `cockpit_mock_feed.dart` | 演示世界：按脚本跑一轮对话、召回、后台任务、被拒绝的守护、发不出去的指令 |
| `constellation_geometry.dart` | 纯几何：行星、卫星、身体端口、活动珠的位置；画布贴着内容算 |
| `constellation_painter.dart` | 节点之间的一切：轨道、归属线、资产腿、身体链、循环光点、事件飞镖 |
| `constellation_nodes.dart` | 可点的节点本体（主人核心、行星、卫星、端口、活动珠） |
| `constellation_stage.dart` | 可缩放平移的舞台、镜头飞行、细节分级 |
| `cockpit_header.dart` | 顶部仪表条（横向滚动，不靠删表盘来适配手机） |
| `cockpit_deck.dart` | 底部运行背板：收起是一条轨；展开是活动 / 事件 / 底座三页 |
| `companion_inspector.dart` | 聚焦卡片（概览 / 身体 / 记忆 / 活动） |
| `cockpit_details.dart` | 各类下钻详情 sheet |
| `constellation_cockpit_page.dart` | 页面装配：一个时钟、一个 feed、聚焦与下钻状态 |

## 3. 入口放在哪

### 3.1 现状：三块屏在回答重叠的问题

「我的 Eidolon」的连接卡上今天有三个入口：

| 入口 | 屏 | 它答的问题 | 独有的东西 |
|---|---|---|---|
| 运行驾驶舱 | `RuntimeCockpitPage` | 「什么是我的、它们怎么样」 | **没有**（见下） |
| 主机动态 | `MissionControlPage` | 「最近发生了什么」 | 设备生命周期流水 |
| 查看系统状态 | `HostSystemPage` | 「这台机器本身怎么样」 | 主机 vitals（磁盘/内存/温度）、服务启停 |

驾驶舱的四条 lane 逐条都在别处：vitals 和 services 在系统页（`host-vitals-card`
已经在那儿），activity 在主机动态，workspace runtime 在工作区卡片。**它唯一的贡献
是那个组合** —— 而星图是同一个模型更好的组合。

### 3.2 已落地（2026-08-27）：两块屏，域与机器

四个按钮变两个。分法是这一节原本就在论证的那条边界 —— vitals 是**这台机器**的
事实，不是**主权域**的事实，混在一起会让「域」和「机器」两个概念糊掉：

- **驾驶舱**（原「星图」）= 我的域，看的。谁是主人、有哪些 Eidolon、正在为它们
  发生什么。
- **主机运行状态** = 这台机器，读和操作的。运行驾驶舱 + 主机动态 + 查看系统状态
  三块合成一块。

**为什么四块能塌成两块**：那三块读的是重叠的来源（services 三块各读一遍、
activity 两块各读一遍），而且每一块都把能读到的一切按原尺寸铺开、永远如此 ——
于是「有没有出问题」要靠人读完三屏并注意到一处缺席。

**合并不是把三块叠起来。** 顺序按读者的问题排，不按来源排：

1. **一句判词**，由画出下面那些行的**同一批读取**算出来，所以屏幕顶上和中间不
   可能自相矛盾。一台没事的主机，这一句就是全部答案。判词的语义单独成文件并
   单独测（`host_runtime_verdict.dart`）：主机的判断不在客户端重定（`VitalConcern`
   是主机给的，磁盘 91% 是异常因为主机这么说，不是因为客户端挑了 90），而
   「读不到」自成一类 —— 「我说不上来」和「这个坏了」要采取的行动不同；
2. **异常在前，正常压成一行。** `底座 8/13` 是一行，展开才看每个服务；坏了的那个
   已经在判词里，**重启就在它自己那一行上** —— 这是没有独立「服务卡」的原因；
3. **原因只说一次。** 在判词里。下面那一行只说短状态，否则同一句话在一屏上出现
   两次；
4. **出问题时要引用的**（Host ID、fingerprint、reset epoch）默认收起 —— 那是抄给
   别人的，不是读的。三块老屏各自把它们摊开；
5. **危险动作最后**。

**一处刻意的重复**：底座同时出现在驾驶舱（`8/13` + LED，**观测**）和主机运行状态
（带重启，**操作**）。同一个事实的两种用途，不是漏掉。

**一条前提写错了，记下来**：这一节原先说「主机动态并进背板的事件页，那本来就是同一
批内容 —— 设备的到来、接受、移除」。不对。那块屏自己的 coverage 句写着「伙伴的来去、
谁来回答、换过的脸。设备是否在线不在其中」，它的词表也是
`companionArrived / answeringChanged / faceChanged / ownerNamed`。它是**改动记录**，
不是设备历史。所以它没有并进事件页（那里现在是审计流，治理与凭据），而是作为
「最近的改动」留在主机运行状态里，coverage 句原样带过去。

这留下一处张力，值得下一个人知道：改动记录讲的是**对域做过的事**，而它现在住在
机器那块屏上。真正的同类是驾驶舱背板的事件页（审计流）。等审计流在这台 Host 上
真的有内容之后，那里才是它该去的地方。

### 3.3 星图不做首屏

诱人但错。首屏的活是主机连接、workspace 状态和各入口，**这些必须永远能用**；
星图是只读观测，要求 workspace ready + 投影可读，两个前提都可能不成立。把一块
可能读不到的屏放在一块必须可用的屏前面，等于让恢复路径依赖观测路径 ——
plan 明确要求 Host Setup 保持独立恢复入口。

### 3.4.1 伙伴变多时:轨道按需涨,挤了就只画被聚焦那一家的卫星

roster 落地之后 N>4 是现实的,而原来的几何撑不住 —— 实测：

| N | 行星间隙 | 跨伙伴卫星间隙 |
|---|---|---|
| 4 | 205 | 216 |
| 5 | 83 | **19.8** |
| 8 | 35.7 | **−16.4（重叠）** |
| 10 | **6.2** | **−17.3（重叠）** |

重叠意味着**手指点下去会落到别人家的资产上**。两步改:

1. **轨道按需涨**（`orbitGrowth`）。邻居角距按 1/N 收窄,所以椭圆按弦长
   `2·R·sin(π/N)` 反解出"够放下两颗行星 + 一根手指"的倍数。N=10 的行星间隙
   从 6.2 涨到 38.9。
2. **挤了就收卫星**。光涨轨道不够:一簇资产伸出行星 131dp,要让它们也不撞,画布得宽到
   把每颗卫星压到 22dp —— 那就没得读了。所以未聚焦的伙伴只留行星（运行徽标和 LED 都还在）,
   点一下就靠**这一屏本来就有的聚焦**把它的卫星带回来。

**判定是测量,不是"N 大于几"**:实测 6 位是宽松的（39dp）而 5 位是挤的（19.8dp）——
哪几对最近取决于角度怎么落在椭圆上,奇偶还不一样。所以规则是"任意两家卫星的最近距离
小于一根手指就收",写成计数阈值会在 6 位那里误收。

几何是唯一决定"什么存在"的地方,painter 和节点只画已经在的东西 —— 所以焦点要传进
`buildConstellationLayout`,不让三个界面各自决定藏什么。

顺带修一个交互副作用:聚焦会把卫星放回来、从而改变画布尺寸,而原来的重构图逻辑
会在飞行动画之前先"跳"一下。现在只有视口变化（或无焦点时的画布变化）才重构图。

### 3.5 完整 roster 进星图:已裁决 —— roster 是存在性的权威

多 Companion 方案 §2.3 的待裁决点已由本线复查并写回该节:MC 属于管理面,而
「两份契约都在投影 Companion」的根因不是平面。§6.2 那一行的参数是
`?companion_id=...` —— **快照是按 companion 参数化的**,调用方已经从 roster 知道
有哪些伙伴,再来问 MC 它们的运行事实。加上 roster 的身份字段是权威字段而不是投影,
结论是:**伙伴列表从来不是 MC 该提供的东西**。

所以不是"要不要一屏两源"的取舍,而是**分工本来就该这样**:

| 事实 | 权威 |
|---|---|
| 主人是谁、默认是哪个 | `/api/management/v1/context` |
| 有哪些伙伴、名字、生命周期、revision | `/api/management/v1/companions`（roster） |
| 它们此刻在干什么(身体/活动/轮次/任务/记忆/底座/事件) | MC 快照,按 `companion_id` 索引 |

我原先担心的"一屏两源会糊成一份"在这个分工下不成立:行星来自 roster 权威,运行卫星
来自 MC 的 lane —— 而 lane 机制已经会在 MC 读不到时写「读不到」,不会画出一个看起来
在运行的伙伴。剩下的真实代价只有新鲜度错位(roster 在 T1、MC 在 T2),用各 lane 已有的
`observed_at` 和 roster 的 `revision` 表达。

**已执行**(`eidolon_sdk@7f3226d`,mobile 本次):契约里的 owner/companions lane 与
`default_companion_id` 已移除,只留按 `companion_id` 索引的运行事实;解析拆成
`parseMissionControlRuntime` → `CockpitRuntime`;`CockpitComposer` 把三个来源 join
成屏幕要的 `CockpitSnapshot`。

**它今天就能用。** roster 和 `/context` 在线,MC 还没有 producer —— 所以
`CockpitComposer` 的 `readRuntime` 是可空的:不传就是每条运行 lane 都
`unavailable` 并带上原因(「Mission Control 投影尚未在管理面提供」)。于是星图能画出
**主人真实的伙伴**,同时**不假装**知道它们在干什么。

边界:composer 收的是**注入的函数**,不 import `management_client.dart` ——
constellation 不认传输,而那个 client 正被另一条线逐能力重塑(512 行、6 个近期提交)。
它只依赖 `generated/management_v1.dart`,这是纲领明确允许的
（「客户端 feature repository 只能依赖 generated client 和自己的 presentation model」）。

两条分工细节写在测试里:**身份读不到就抛**(没有主人没有伙伴的星图无物可画,让页面
显示首次读取失败比画一张空图诚实),而**运行读不到只落进 lane**;默认指针**优先用
随 roster 同一次读取回来的那个**,`/context` 只作回落 —— 一个过期的指针会把标记打在
错误的行星上。

### 3.5.1 原先记在这里的顾虑（保留，因为它解释了为什么现在这样分工）

`ManagementClient` 已经能读完整 roster，星图的 companions lane 却只能拿到默认那一个。
直接拿 roster 喂星图**不违反**多 Companion 计划 L2906（那条禁的是反方向:从 MC
activity 反推 roster），但会让一屏出现两个源:roster 来自 management ABI、其余来自
MC 快照，两者各自失败、各自新鲜度不同。

真要做，星图必须显式区分「这一行伙伴来自 roster 权威」与「它的运行事实来自 MC」，
不能糊成一份 —— 否则 roster 读到了而 MC 没读到时，屏幕会画出一个看起来在运行的伙伴。
倾向等 MC 的 companions producer，保持一屏一源。

### 3.4 分两步落（已完成）

1. ~~现在：产品导航里没有任何入口~~ —— 2026-08-26 接上真主机（§7.9）。
2. ~~投影落地后：星图接掉 open-runtime-cockpit~~ —— 2026-08-27 完成，见 §3.2。
   `RuntimeCockpitPage`、`MissionControlPage`、`HostSystemPage` 三个文件删除，
   1602 行换成 993 行的一块屏 + 单独可测的判词。

被删的那两块屏的测试**断言没有跟着删**：还在描述行为的搬到了
`host_runtime_status_page_test.dart`（一个来源塌了其余照读、没人问过不等于没有、
改动说成句子不说事件类型、这份清单不知道什么就说出来），纯逻辑那组整组搬到
`host_activity_lines_test.dart`（它测的是 `activity_models`，和屏无关）。归驾驶舱的
那几条（「shows whose the Host is」、「a Host with no Workspace has no domain to
draw」）删掉了 —— 驾驶舱已有等价断言，留在这里会变成两块屏争同一个事实。

## 4. 看效果

```sh
flutter run -t lib/constellation_demo.dart
```

`lib/constellation_demo.dart` 是独立入口，产品导航里没有任何地方指向星图 —— mock
世界不能被当成主机说过的话。演示数据在两处显式标注：顶部的 `MOCK` 徽标，和每条
事件行前的 `MOCK` 来路。

可选的视觉回归参考（默认关闭，像素比较受渲染器和字体摆布，不该让别人的机器无故
变红）：

```sh
EIDOLON_GOLDENS=1 flutter test --update-goldens test/constellation_golden_test.dart
```

## 5. 多设备与横竖屏

不按「朝向」分支，按**哪种摆法能把地图画得最大**分支：两种仪表位置（底部背板 /
侧栏）× 两种轨道（竖版 / 宽版）四种组合各算一次 fit，选最大的那个
（`chooseChrome`）。横屏手机、矮的分屏窗口、平板正反两面都从同一个比较里出来，
没有一个特例。

- **竖版轨道**（`orbitRadiusX 152 / Y 260`）：伙伴沿竖椭圆铺开，仪表在底部背板。
- **宽版轨道**（`X 290 / Y 150`）：伙伴横向铺开，仪表搬到右侧栏，顶栏收成一行。
  横屏手机原本被顶栏+背板吃掉 390dp 里的 217dp，地图只剩 173dp 的信箱、卫星只有
  15px；换向之后卫星 41px，和竖屏（43px）基本一致。
- 侧栏窄于 200dp、或会让地图不足 300dp 时**不启用**，宁可回到底部背板。
- 转屏会重新构图（视口或画布尺寸任一变化都重算），不留上一次的镜头。

系统字号：仪表盘是有高度的，字长大了容器也要长大 —— 顶栏表盘条、服务卡片行、
背板高度都乘 `chromeScale`（钳到 1.3）。节点内部另算：圆是固定形状，超过约 1.15
三行字就放不进一颗卫星，所以星图内部把字号钳在 1.15 并用 `FittedBox` 兜底，
**放大靠这一屏本来就有的缩放**。下钻 sheet 在 Navigator 上层、不受这层钳制，
保留用户完整字号 —— 它们会滚动、能重排，读长文本本来就是它们的活。

覆盖到的尺寸（`test/constellation_adaptivity_test.dart`，每一屏都断言
「节点不越出舞台 / 节点不小于可读下限 / 没有任何 overflow」）：

| 屏 | 舞台 | 最小节点 |
|---|---|---|
| 手机竖屏 390x844 | 390x627 | 43dp |
| 手机横屏 844x390 | 576x341 | 41dp |
| 小屏竖屏 320x568 | 320x351 | 32dp |
| 小屏横屏 568x320 | 352x271 | 27dp |
| 平板竖屏 712x1067 | 712x850 | 77dp |
| 平板横屏 1067x712 | 799x663 | 62dp |
| 分屏 390x420 | 390x203 | 24dp |
| 折叠展开 673x841 | 673x624 | 56dp |
| 字号 1.3 / 1.6（竖 + 横） | — | 与 1.0 同 |

分屏 390x420 是承认的下限：窗口只有 420dp 高时地图就是小，靠缩放看。

## 6. 保留下来的产品纪律

- **没有伙伴心跳。** 这套系统从未为伙伴发布过在场信号，所以星图不给伙伴画在线点。
  身体的在场是身体的，逐台标注（在线 / 已准备 / 已绑定 / 不稳定 / 未探测 / 离线）。
- **没人探测过的服务是「未探测」，不是「正常」。** 背板不做「大概没事」这种推断。
- **读不到的来源被点名。** `degradedSources` 在底座页末尾明说，不折进一个看起来
  健康的整体里。
- **未开通的资产是虚线圈，不是暗一点的实心圈。** 「还没有」和「有但安静」不能是
  同一张画。
- **降低动效（reduced motion）下飞镖直接消失**，而不是被冻在半路 —— 停住的光点读
  起来像故障，不像信号。亮起来的链路仍然亮着。

## 7. 接真实数据要做的

### 7.1 已经是干净的部分

UI 只通过 `CockpitFeed` 的五个成员碰数据：`snapshot` / `updates` / `pulses` /
`refresh` / `dispose`。几何、绘制、色调、事件→脉冲全都不知道数据从哪来，
`cockpit_mock_feed.dart` 在产品代码里**零 import**（只有 demo 入口构造它）。
`ConstellationCockpitPage` 的 `feed` 是必填的，没有回落到 mock 的路径 ——
少传一个参数就显示演示数据，这种事不该可能发生。

### 7.2 接口已经按契约定型

完整契约见 **[mission-control-local-api-contract.md](mission-control-local-api-contract.md)**。
消费侧的形状已经改成契约要求的样子，不再是「mock 用着方便」的样子：

```dart
abstract class CockpitFeed {
  CockpitSnapshot? get snapshot;          // 第一次读到之前是 null
  CockpitObservation get observation;     // 观测状态与事实分开
  Stream<CockpitSnapshot> get updates;
  Stream<CockpitPulse> get pulses;
  Stream<CockpitObservation> get observations;
  Future<void> refresh();                 // 失败必须抛
  void pause();                           // App 切后台
  void resume();
  void dispose();
}
```

四个刻意的决定：

1. **`snapshot` 可空。** 真 adapter 在第一个往返之前没有事实。给它一个空 snapshot
   顶上，就等于让「还没读到」长成「什么都没有」。所以第一次读取落地之前，星图
   **一个节点都不画** —— 另有一屏说明它在读、或者第一次就失败了（含重试）。
2. **观测状态自己一条通道**（`connecting / live / degraded / lost` + 原因 + 最后一次
   成功读取时间 + 游标）。传输失败不用伪造一份 snapshot 来表达。
3. **`pause` / `resume` 在接口里**，因为消费者真的会调 —— 页面挂在
   `AppLifecycleState` 上，切后台就停止消费。
4. **`refresh()` 失败必须抛。** 静默失败的刷新按钮是最坏的一种按钮。

游标语义写在契约 §4.2：用 audit index 的 `ingest_seq`（一台主机上一个全序整数），
`event_id` 双端去重，`producer_seq` 用来发现单个生产者的缺口，失效只有「行被清掉」
和「`reset_epoch` 变了」两种。`CockpitObservation.cursor` 是它在消费侧的落点。

### 7.2.1 载荷已经 lane 化

`CockpitSnapshot` 的每一块现在是一条 `CockpitLane<T>`（`state / detail /
observed_at / latency_ms / truncated` + 载荷）。读不到的 lane **即使载荷里带了
东西也不采用** —— 没被观测到的东西不能因为躺在 JSON 里就被画出来。

界面上「读不到」和「空」是四处不同的画法：

| 位置 | lane 读不到时 | 而不是 |
|---|---|---|
| 表盘条 | `—` | `0`（0 是一次测量） |
| 身体/活动卫星 | `读不到`（警示色，`unreadable`） | `未绑定` / `空闲` |
| 行星徽标 | `活动读不到` | `空闲` |
| 主人核心 | `伙伴读不到` | `0 位伙伴` |
| 底座轨 | `读不到底座：<原因>`、`CORE ?` | 0 个芯片 + `CORE 0/0` |
| 底座页末尾 | 逐条点名读不到的 lane | 静默 |

解析在 `cockpit_wire.dart`，是全 App 唯一知道 wire 存在的地方。契约违反（版本、
coverage、缺字段）**拒绝**，不半懂着渲染；不认识的枚举值**照常携带**（App 常比
旁边的 Host 新，也常比它旧）；`lane.state` 认不出来时按**读不到**处理，不按正常。

mock 世界里有一拍会让记忆服务不回应，所以这条路径是**看得见**的，不只是断言。

### 7.2.2 「谁是默认」只说一次

快照带 `default_companion_id`，行上**没有** `is_primary`。理由有两层:

- **措辞**:Companion 权威那次修复把「主伙伴 / 主 / PRIMARY」改成「默认 / DEFAULT」，
  因为"两个客户端对同一个事实用不同的词，就是它们开始互相不一致的方式"。
  mobile 的 roster 早就说「默认」，星图曾是第三种说法。
- **形状**:每行挂一个布尔，等于让这里成为第二个裁决"谁是 default"的地方 ——
  而它**只在只有一个 Companion 时是对的**，这是最糟的一种错，因为它能通过任何人
  随手写的测试。

`test/mission_control_plane_guard_test.dart` 钉住这两条:星图里不出现
`主伙伴 / PRIMARY / isPrimary`，全 lib 不从 wire 读 `is_primary`。

### 7.3 读失败已经有位置了

流出错或 `refresh()` 抛出时，星图上方出现一条失败带：说「读不到这台主机的运行
投影」、说清**屏幕上是哪一次读取的样子**、给重试；同时顶栏的链路徽标从 ONLINE
翻成 UNSTABLE。星图本身留着 —— 它是最后一次事实，但它不再被允许假装是现在。
两条测试盯着这件事（含「重试再失败不会悄悄变正常」）。

### 7.4 契约缺口（这是 API 的，不是接缝的）

| 星图要的 | 今天 Local API |
|---|---|
| 主人、主 Companion | `/workspace/runtime` 有；**没有伙伴列表** |
| 身体列表 | `/devices` 有（`coverage=mounted-devices`） |
| **身体在场** | **没有** —— `MountedDevice` 无 online / last_seen，只能落到「已绑定 / 未探测」 |
| 底座健康 | `/host/services` 有 |
| 记忆细节（召回、整理、写入策略） | 只有 realm_id |
| 活动 / 轮次 / 任务 / 事件 / 路由 | **完全没有** —— 星图最有说服力的那部分全靠它 |

### 7.5 阻塞项（BLOCKED）

**星图现在没有真实数据源,而且短期内拿不到。** 这不是"待做",是被别人的排期挡住:

| 阻塞项 | 被谁挡住 | 解除条件 |
|---|---|---|
| `GET /api/management/v1/mission-control/snapshot` **不存在** | 需要穿四层(见 §7.7),其中内部平面要读各权威 —— 那是凭据隔离所在 | 四层实现落地 + OpenAPI 从路由导出 + 两个客户端生成 |
| `GET /api/management/v1/events`（SSE + 游标） | **多 Companion 计划 Phase 6**（"事件流以 `audit_outbox` 为唯一 producer；dispatcher 未接线前 `/events` 不发布"） | Phase 6 |
| 活动 / 轮次 / 任务 lane | 同上 Phase 6 | Phase 6 |
| 逐设备在场 | 设备生命周期计划 PH2-B 邻域，需避让 | PH2-B consumer cutover |
| 完整 roster 进星图 | producer 有了（`ManagementClient`），但**一屏两源**的边界要先定 | 见 §3.5 |

**旧接口已拆除,没有回退到它的路**:`test/mission_control_plane_guard_test.dart`
断言 lib 里不出现 `/api/local/v1/mission-control`。所以在解除之前,星图只有
`MockCockpitFeed`(demo 入口)和 `PolledCockpitFeed`(骨架,等一个 read 函数)。

### 7.6 进度

1. ✅ 契约进 `eidolon_sdk/contracts/local_api/v1/`（schema + 黄金载荷 + 镜像测试，
   见契约 §8）
2. ✅ 载荷 lane 化（消费侧）
3. 🔴 **走错平面,已拆除**（见 §7.7）。原来落在
   `GET /api/local/v1/mission-control/snapshot`，那条平面正在被删除；
   正确位置是 `/api/management/v1/mission-control/snapshot`。
   拆掉前它能读到的部分是：
   - **能读**：主人、主 Companion（degraded：控制面只给主伙伴）、已挂载身体
     （degraded：**在场没有权威回答**）、底座服务（`unknown` → `checked=false`）
   - **读不到**：活动 / 对话轮次 / 后台任务 / 记忆 / 事件 —— 每条 lane 说出缺哪个
     控制面能力，不空着到达
   - 原因见 §7.6：Local API 是独立 app，只经显式 Port 触达权威，**没有
     `nats_kv`、没有 data store**
4. 🟡 feed 骨架保留（`polled_cockpit_feed.dart`）：轮询、有界退避、
   前后台暂停恢复、失败走观测通道、**永不伪造脉冲**。它只收一个 read 函数、
   不拥有传输,所以换平面不动它。手写进 `LocalApiClient` 的那个读取方法已删除
   （见 §7.7）
5. ⬜ 产品面变更：星图接掉运行驾驶舱、主机动态并进背板（见 §3.2），单独一个提交 ——
   等活动/事件那几条 lane 有 producer 之后再做，否则星图最有说服力的部分是暗的

### 7.7 走错了平面:为什么删掉而不是改个路径

`/api/local/v1/mission-control/snapshot` 是错的,而且错在架构层面。
[EidolonOS多Companion统一管理架构方案.md](../../docs/跨系统/EidolonOS多Companion统一管理架构方案.md) §2.3
写明:`/api/local/v1` 上那 22 个 Owner 产品端点要**逐个迁入
`/api/management/v1` 后删除**,并且——

> **「收敛」是删除，不是并存。** 若它们与 `/api/management/v1` 长期共存，
> 本节要消除的问题只是换了主角——从 Admin Web 换成 Mobile。

我在一条正在被删除的平面上**新长了一条 Owner 产品路由**,正是那句警告说的
"换主角"。同一份计划的 Management API 表里本来就写着
`GET /mission-control/snapshot`——目标平面从来不是我选的那个。

消费侧同样错:我把读取手写进 `LocalApiClient`,而 mobile 自己的
`test/management_boundary_test.dart` 的文档注释就写着

> `LocalApiClient` is 27 hand-written methods over `/api/local/v1` … the
> cheapest way to add a management feature is to add method 28. That works,
> once.

**我加的就是第 28 个方法。**

所以这一轮的处理是 §2.3 规定的那一半:**删除**。已拆掉 admin 的路由与
`local_api/mission_control.py`、mobile 的第 28 个方法,并把 feed 从
`LocalApiCockpitFeed` 改名为 `PolledCockpitFeed`（类名不该编码一个正在消失的平面）。
没有留兼容窗口,因为它从未发布,也没有任何东西指向它。

### 7.8 正确位置要穿四层

management 面的实现不是换个 path 前缀,它有四层,凭据隔离就住在这些层之间:

| 层 | 位置 | 职责 |
|---|---|---|
| 内部平面 | `app/management/`（`/internal/v1/management/*`，带 service credential 依赖） | 读各权威并投影 |
| loopback 适配 | `local_api/management/backend.py` | 只带一个 service token 到内部平面 |
| 公共 router | `local_api/management/router.py`（`ManagementBackendPort`） | 认证 Owner、组装公开视图 |
| 生成的客户端 | `contracts/management/v1/generate_dart.py` → mobile；`generate_typescript.py` → admin web | **两个客户端从一份文档生成**,所以 ABI 不会长成先写的那个客户端的形状 |

OpenAPI 文档是**从路由导出**的(`generate.py`，`--check` 是漂移门禁),不手写。
所以下一步的顺序是:内部平面投影 → backend 方法 → 公共路由与视图 → 导出文档 →
生成两个客户端 → mobile 用生成的 DTO 替掉 `cockpit_wire.dart` 的手写解析。

**同时要处理的重复**:SDK 的 `contracts/local_api/v1/`（我建的）目录名就是那条
将死的平面,而 management OpenAPI 一旦描述了同一份载荷,它就成了第二份 wire 定义。
词汇（`biz/contracts/mission_control.py`）留在 SDK 是对的；wire schema 与 golden
应随文档搬到 management 那边。

### 7.9 已接上真主机：缺口在哪、为什么是那里（2026-08-26 复核）

这一节此前列了五条「缺的控制面能力」，并断言「星图现在两侧都按契约就位，缺口全在
Admin 控制面边界」。前半句对，后半句把范围说大了 —— **生产者一直都在**，只在
operator 面（`/api/mission-control/*`，owner 靠 query 参数）。缺的是它在 Owner
面上的暴露。补上之后真机实况是：

| lane | 现状（真机 `20260826-owner-runtime-map-6`） | 来源 |
|---|---|---|
| `services` | **ok**，13 个服务带真实延迟 | 服务注册表 + supervisord |
| `activities` | **ok**，12 条带逐跳链路 | 由 turns / long tasks 投影 |
| `turns` | **degraded**，12 条 | Agent 轮次；Data 不发布对话历史 |
| `jobs` | **degraded**，1 条 | Agent 长任务；Data 不发布任务清单 |
| `devices` | 存在=清单(Owner 面 join)，在场=**无生产者** | 见下 |
| `memory` | **unavailable** | Memory 只发布 recollections，无 realm/runner 名册 |
| `events` | **unavailable** | 这台 Host 的 audit indexer 没在跑 |

三条仍未点亮，各有明确的主：

* **事件流** —— `EIDOLON_ADMIN_AUDIT_NATS_URL` 在主机上存在但为空，indexer 因此不
  启动（消费端就是创建流的那一方，所以上游也不发布）。方案 Phase 6 后半把
  「indexer 纳入服务清单」判给 operator 面，不在这条线上。**它一配上，事件 lane
  和飞镖同时活** —— 见 §7.11。
* **逐设备在场** —— `9a5880f align admin with data v2 and kernel boundary` 收走了
  Admin 直读运行黑板的能力，至今没有权威通过 HTTP 发布逐设备在场。谁来重建是边界
  决定。在场缺席期间，身体照画、在场标 `unknown`（永不 `offline`）。
* **per-companion 记忆域 / runner 名册** —— 在 `eidolon_memory` 那条线。roster 是
  存在性与身份的权威，不带 realm。

### 7.9.1 Owner 面的暴露怎么走的（四层，没有例外）

`app/management/mission_control_router.py`（服务凭据，只读，与 mutation 分文件）→
`local_api/management/backend.py`（loopback）→ `/api/management/v1/mission-control/
snapshot`（Owner 只来自会话，没有 `owner_id` 入参）→ 重新生成 OpenAPI / TS / Dart。

投影（`app/management/mission_control.py`）不是 re-export：operator 专属材料（运行
黑板、trace span、证据链、权限账本）不过界，身份不在其中（`/context` 与 roster 是
它的权威），每条 lane 带 state/detail/observed_at/latency_ms/truncated。形状的权威
是 SDK 的 JSON Schema，用 `jsonschema` 验证投影，不写会与之分歧的 pydantic 镜像。

**lane 在读取的那一行记账**（`app/mission_control/lanes.py`）：每次读取声明它决定
哪些 lane，`SOURCE_LANES` 必须穷尽，没登记的来源当场抛。console 要的扁平
`source_status` 由同一本账派生，所以两个视图不可能对「观测到了什么」有分歧。

**设备 lane 是两个权威的 join，在 Owner 面合成**
（`local_api/management/mission_control.py`）：存在来自这个面本来就在替 Owner 读的
清单（Claims + mounts，Controller 会话），在场来自 admin 进程。存在永不被读成在场。

### 7.9.2 一次重构切掉四项能力，而合成对着四个都还在伸手

真机第一次调用这条新路由是 500：`'HubManagementClient' object has no attribute
'list_devices'`。追下去，`9a5880f / 06e7a2e` 那次重构搬走或删掉了 admin 的四项
能力，而 Mission Control 的合成对着四个全部还在调 —— Hub 设备清单、Hub 事件流、
`app.memory.runners`、NATS KV 客户端。每一处都被宽 `except` 或 `_safe` 的构造盲区
藏住，所以 **operator 控制台那张星图从那时起一直 500，而没人发现**：唯一覆盖它的
测试是对着仍带旧方法的 stub 断言的。

四处都退役并说清缺失，而不是接回来。另加三道结构闸（`test_mission_control_router.py`）：
组合调用的权威方法必须存在于真实客户端类上、函数内 import 的模块必须真的能 import、
上游方法被删只损失它自己的 lane。每一道都验证过会咬。

### 7.10 观测的生命周期归页面：为什么这是契约的事，不是补一行

第一次拿真机打开星图，屏幕停在「正在读取这台主机的运行投影」不动，没有报错也没有
重试按钮。链路本身是通的，断的是**谁来发起**：

- `ConstellationCockpitPage` 只订阅了三条流，从不发起读取；
- `PolledCockpitFeed` 只在被要求时读（一次 `start()` / `refresh()`）；
- `CockpitFeed` 里**没有「开始观测」这个动作**，页面拿着这个接口根本无从要求；
- 而 `MockCockpitFeed` 在自己的构造函数里就发布了第一帧 —— 于是所有 widget 测试都是
  **feed 在驱动页面**，页面漏掉的那一步谁也看不见。

同一个缝上还漏了另一半：入口在 `MaterialPageRoute` 的 builder 里 `new` 出 feed，
**没有任何人 dispose 它**。退出星图之后那个 6 秒轮询会一直敲这台主机，直到进程结束。

两个缺陷是一类：**生命周期义务写在注释里，而不是写在类型里**。所以修的是这一类：

1. **`start()` 进契约**，并写明*任何实现在 `start()` 之前不得观测任何东西*，构造必须
   没有可观察的副作用。`MockCockpitFeed` 也照办 —— staged 的是世界，不是生命周期。
2. **页面收下所有权**：`ConstellationCockpitPage` 收 `openFeed`（工厂，不是实例），在
   `initState` 里建、订阅、`start()`，在 `dispose` 里关。四个转换在同一个 `State` 里，
   而 `dispose` 是框架本来就会调的那一个 —— 忘不掉。
3. **顺序写进代码注释并由测试锁住**：先订阅后 `start()`。broadcast 流不为迟到的听众
   留事件，顺序反了就又是永远的首读屏。
4. **`refresh()` 也算「有人来要」**：它自己会排下一次轮询，所以它同样开启观测；
   `resume()` 不行 —— 从未开始过的东西没有东西可以继续。不许自己开始的只有构造函数。

测试落在缝上，不落在任何一个实现上（`test/cockpit_feed_lifecycle_test.dart`，用一个
只记录四个转换的假 feed）：页面开一次、只开一次、离开就关、切后台就停。外加一组对
**实现**的约束测试 ——「构造一个 feed 不产生任何观测」，新增实现要一并加进那张表。

验证过这道闸会咬：把 `_feed.start()` 注掉，除新测试外既有 widget 套件立刻红 17 个
（mock 不再自驱之后，它们全都开始真的依赖这个 seam）。

### 7.11 飞镖已经接好，等的是事件流

`PolledCockpitFeed` 现在会发脉冲，而且不是从 snapshot 差异里编造的。原先那条理由
（「差异出来的箭会宣称一个没人观测到的方向和瞬间」）成立，但它讲的是**状态**：两次
读取里在线身体从 2 变 3，说不出这件事何时、怎么发生的。它不适用于事件 lane —— 那是
主机的审计尾巴，每一行都有 id、时刻、主体、结果，还有主机指派的序号。上次没有、这次
有的那一行，就是在这两次之间发生的。

三条纪律（`test/polled_cockpit_feed_test.dart`）：第一次读取只建基线（带回来的是
一百条没人在看时的瞬间，全画出来就是宣称它们正在发生）；同一个瞬间只发一次；没有
序号的事件不猜。外加：事件 lane 读不到时**不动水位**，恢复后那段空档照样发出来。

所以飞镖今天不动的唯一原因是这台 Host 的事件 lane 是空的（indexer 没跑）。**不需要
再写 mobile 侧的代码**；`EIDOLON_ADMIN_AUDIT_NATS_URL` 一配上就会动。

SSE 暂时没做，理由记在这里以免下一个人当成漏项：服务端自己是每秒轮询 sqlite 发现
新事件的，所以 SSE 是「在轮询上加推送」，延迟下限一样；而代价是 local_api 至今没有
任何流式路径（要新开一种 backend port 形状）、手机端要加 SSE 解析与重连退避、
keepalive 每 5 秒一帧的耗电。游标已经是精确的（`ingest_seq` 单调），批量读取
`after_seq` 在语义上不输：恰好一次、有序、无需去重。**SSE 值得付这个代价的时刻，是
审计索引变成推送的时候**（indexer 可以通知），那时同一条路由升级，游标语义不变。
