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

## 3. 看效果

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

## 4. 多设备与横竖屏

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

## 5. 保留下来的产品纪律

- **没有伙伴心跳。** 这套系统从未为伙伴发布过在场信号，所以星图不给伙伴画在线点。
  身体的在场是身体的，逐台标注（在线 / 已准备 / 已绑定 / 不稳定 / 未探测 / 离线）。
- **没人探测过的服务是「未探测」，不是「正常」。** 背板不做「大概没事」这种推断。
- **读不到的来源被点名。** `degradedSources` 在底座页末尾明说，不折进一个看起来
  健康的整体里。
- **未开通的资产是虚线圈，不是暗一点的实心圈。** 「还没有」和「有但安静」不能是
  同一张画。
- **降低动效（reduced motion）下飞镖直接消失**，而不是被冻在半路 —— 停住的光点读
  起来像故障，不像信号。亮起来的链路仍然亮着。

## 6. 接真实数据要做的

### 6.1 已经是干净的部分

UI 只通过 `CockpitFeed` 的五个成员碰数据：`snapshot` / `updates` / `pulses` /
`refresh` / `dispose`。几何、绘制、色调、事件→脉冲全都不知道数据从哪来，
`cockpit_mock_feed.dart` 在产品代码里**零 import**（只有 demo 入口构造它）。
`ConstellationCockpitPage` 的 `feed` 是必填的，没有回落到 mock 的路径 ——
少传一个参数就显示演示数据，这种事不该可能发生。

### 6.2 接缝本身还是照 mock 的形状定的

真流要补进接口的三样，恰好都是
[product-surface-plan.md](product-surface-plan.md) §5 已经要求的：

| 缺口 | 为什么不能靠 adapter 内部糊 |
|---|---|
| **游标与去重** | 有界重连之后，要么重放（飞镖打两次）要么跳过（静默丢事件）。`pulses` 现在是 fire-and-forget，没有「我从这里续上」的概念 |
| **前后台生命周期** | 接口没有 `pause` / `resume`，App 切后台时订阅只是挂着 |
| **`refresh()` 的结果** | 返回 `Future<void>`，成功失败都一样 —— 现在页面靠 catch 兜住，但这是页面在替接口补语义 |

失败通道已经补上了（见 §6.3），剩下这三样等真实传输一起定，现在补是凭空设计。

### 6.3 读失败已经有位置了

流出错或 `refresh()` 抛出时，星图上方出现一条失败带：说「读不到这台主机的运行
投影」、说清**屏幕上是哪一次读取的样子**、给重试；同时顶栏的链路徽标从 ONLINE
翻成 UNSTABLE。星图本身留着 —— 它是最后一次事实，但它不再被允许假装是现在。
两条测试盯着这件事（含「重试再失败不会悄悄变正常」）。

### 6.4 契约缺口（这是 API 的，不是接缝的）

| 星图要的 | 今天 Local API |
|---|---|
| 主人、主 Companion | `/workspace/runtime` 有；**没有伙伴列表** |
| 身体列表 | `/devices` 有（`coverage=mounted-devices`） |
| **身体在场** | **没有** —— `MountedDevice` 无 online / last_seen，只能落到「已绑定 / 未探测」 |
| 底座健康 | `/host/services` 有 |
| 记忆细节（召回、整理、写入策略） | 只有 realm_id |
| 活动 / 轮次 / 任务 / 事件 / 路由 | **完全没有** —— 星图最有说服力的那部分全靠它 |

### 6.5 顺序

1. projection 与事件流落地；
2. 把游标 / 生命周期 / refresh 结果补进 `CockpitFeed`；
3. 写 pinned adapter（走现成的 `local_api_client` + `pinned_http_client` +
   Controller session），由 `HostProductController` 构造并决定换主机 / reset epoch
   时的生命周期归属；
4. `streamState` 与 `degradedSources` 来自逐 source 的
   `ok / degraded / unavailable` 与 freshness，不由客户端猜；
5. 然后才把入口放进产品导航。
