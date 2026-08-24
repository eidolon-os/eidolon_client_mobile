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

### 3.2 建议：星图接掉驾驶舱，主机动态并进背板，vitals 留在系统页

- **星图取代运行驾驶舱**，占掉 `open-runtime-cockpit` 这个位置，沿用同一个
  「workspace ready」门（没有 Owner 就没有域可画）。`RuntimeCockpitPage` 删掉，
  不留第四块重叠的屏。
- **主机动态并进背板的「事件」页**。那本来就是同一批内容 —— 设备的到来、接受、
  移除 —— 而背板已经有事件页。`coverage` 那句话跟着搬过去，不能丢：
  「这里只记录设备的到来、接受和移除」。
- **vitals 留在系统页，星图不重复它**，只留一个跳转。理由是权威边界：vitals 是
  **这台机器**的事实（而且是 Console 的驾驶舱读不到的那部分），不是**主权域**的
  事实。把它画进星图会让「域」和「机器」这两个概念糊在一起。

### 3.3 星图不做首屏

诱人但错。首屏的活是主机连接、workspace 状态和各入口，**这些必须永远能用**；
星图是只读观测，要求 workspace ready + 投影可读，两个前提都可能不成立。把一块
可能读不到的屏放在一块必须可用的屏前面，等于让恢复路径依赖观测路径 ——
plan 明确要求 Host Setup 保持独立恢复入口。

### 3.4 分两步落

1. **现在**：产品导航里没有任何入口，只有 `lib/constellation_demo.dart`
   （mock 世界不能被当成主机说过的话）。
2. **投影落地后**：星图接掉 `open-runtime-cockpit`，删 `RuntimeCockpitPage`，
   主机动态并进背板事件页。这一步是产品面变更，不和数据接入混在一个提交里。

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

**还没做、等拍板的一件事**：契约 §7.1 建议把载荷改成 lane 封套（每块自带
`state / detail / observed_at`）。今天的 `CockpitSnapshot` 还是「非空列表 +
`degradedSources`」的老形状。lane 化会动消费侧约 6 处解析和 3 处渲染，
所以先等这条结论被接受再一起做 —— 免得先按一个还没定的形状改一遍。

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

### 7.5 顺序

1. 契约进 `eidolon_sdk/contracts/local_api/v1/`（schema + 黄金载荷 + 镜像测试，
   见契约 §8）；
2. 载荷 lane 化（消费侧，约 6 处解析 + 3 处渲染）；
3. projection 与事件流在 Local API 落地；
4. 写 pinned adapter（走现成的 `local_api_client` + `pinned_http_client` +
   Controller session），由 `HostProductController` 构造并决定换主机 / reset epoch
   时的生命周期归属；
5. 产品面变更：星图接掉运行驾驶舱、主机动态并进背板（见 §3.2），**单独一个提交**。
