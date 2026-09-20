# 桌面陪伴闭环验收 — 2026-09-20

本轮范围：统一伙伴形象；创建、选择设备、确认绑定、表达设置的持久恢复；现有桌面设备链路验证。未扩展微具身、机械控制或 coworker。

## 实现

- Data 在创建事务中将已知官方模板的形象保存为 `profile_json.artwork_id`（如 `five-elements/1/fire`）。这是带版本的展示选择，后续改名或人格编辑不会重新推断它。未知模板、自定义伙伴和未来形象版本保留文字占位。
- 通过现有 roster 投影和生成的 Management DTO 传给 Mobile，不增加图片服务或另一份角色目录。`CompanionPortrait` 统一用于伙伴列表、详情、设备选择和对话准备/无视频状态：用户上传头像优先，官方离线插图其次。有实时视频时仍显示原视频。
- 原有头像读取改为按 companion ID 缓存，延迟响应不能把 A 的头像写到 B；上传/清除后的读取代次隔离旧响应。
- 伙伴创建继续使用原有冻结请求与幂等 operation。设备流程复用同一创建入口，只有有设备等待的创建操作才保留完成收据；从伙伴列表恢复创建也能交回原设备，不新建第二个角色。
- `DeviceCompanionSetup` 负责接入后的主人决策；配网与认领仍由原 Device Setup 负责。共用 `AppPreferences`/`PreferenceWrites`，按 Host/controller/Owner/device 隔离。未选设备的交接同样持久保存。
- 每次写前保存请求与展示时的版本，恢复先读主机。如果结果已存在则继续下一步；结果未写入且版本未变才重试；并发修改则停止覆盖。绑定完成但表达未决定时继续提示配置，不报全部完成。结束本地配置会先核对主机，不冒充撤销已成功的写入。

## 自动化

| 范围 | 结果 |
|---|---|
| Mobile 全量回归 | 1116 passed，8 项原有 skip |
| 新增形象与现有设备交接测试 | 10 passed（部分与全量重叠） |
| 最终统一错误提示后的配置/绑定回归 | 20 passed |
| Mobile 全量静态分析 / Debug APK | 通过 |
| Data 创建、目录、迁移 | 47 passed |
| Admin 目录及控制平面客户端 | 125 passed |
| Admin 契约生成一致性 | 8 passed |
| Channel 输出策略、静默输出、presentation、语音生命周期 | 58 passed；其中 2 项需本机 gRPC 端口权限后通过 |
| ESP32 companion manifest | face 开/关两个构建均通过 |
| ESP32 companion UI | 两块板字体、布局边界、字幕滚动、通知、静默模式、PTT 事件通过 |

恢复故障测试覆盖：主机已成功但响应丢失、重建客户端后的读取确认、输出 null/false 语义一致、跨设备/主人/主机隔离、并发变更不覆盖、跨入口创建收据。形象测试覆盖改名、未知版本降级、上传头像优先和异步回复不串图。

Admin 改动文件的 Ruff 另报告 control_plane/contracts.py 中两个既有未使用 import；本轮未改这两处。Data 改动的 import 规则已修正。

## 部署与数据

- Pi5 发布：`pi5-companion-desktop-20260920c`，Data `b06023d`，Admin `209da61`；Agent 保持原 `b07aa5a82268ed2015cbd4849408099df4796784`。
- Ops prepare/dry-run/activate 通过，doctor `healthy`，app-ready `app_ready`。标准发布契约不执行数据库迁移，本轮没有绕过或修改该契约。
- 先通过 SQLite backup 保存 `/var/lib/eidolon/deployments/companion-artwork-20260920-before.sqlite3`，再使用已部署 Data 的标准 Alembic `upgrade head` 执行 `0002_companion_artwork`。
- 迁移只读取首个 genome 的已知 revision-1 预设，保留已有展示选择和其他 profile 字段。不改人格、记忆、设备归属、默认伙伴或上传脸图。升级/降级/重升测试通过；降级保留旧版本可忽略的可选展示字段。
- Pi5 核实原水系 `HIL－W0920` 与火系 `烁烁` 分别保存 water/fire 形象。总数仍为 7，默认 Sanjiu 未操作。
- 平板 `df331f93` 保留数据覆盖安装最终 APK。SHA-256：`527a4595ecfad61ef95defbeb89abd840e524eb1bebfb833e3c34d55438c51fd`。
- [精简发布证据](desktop-companion-20260920/evidence.json)。未推送远端。

## 真机流程

1. BOX-3 起始绑定为小禾 `cp_a723362066e34ab8af2d3a0b229532f1`，绑定 revision 3。原表达为说话、表情、提示音开启，显示对话文字关闭。
2. 选择已有烁烁，断开平板 Wi-Fi 后确认绑定；主机仍为原 ID/revision 3。结束 App 进程、恢复 Wi-Fi、冷启动，再打开设备看到“正在确认设备关联结果”。继续后绑定到原烁烁 ID，revision 4，没有创建新伙伴。
3. 关闭说话并断网保存表达。结束进程、恢复联网后看到“正在确认表达设置结果”；继续后主机确认的详情变为“表情、提示音”。
4. 将说话重新打开，保持字幕关闭、表情/提示音开启；将伙伴恢复为编号 9532f1 的原小禾。主机核实原 companion ID，绑定 revision 5。没有修改另一台设备。
5. 最终安装包在真实 Pi5 上展示水系、火系列表图与火系详情图，以及选择火系后的对话准备页形象。未启动语音会话。形象来自主机持久字段，不依赖测试名字。

[绑定冷启动恢复](desktop-companion-20260920/01-binding-restored.png) · [表达冷启动恢复](desktop-companion-20260920/02-outputs-restored.png) · [表达生效](desktop-companion-20260920/03-outputs-applied.png) · [伙伴列表](desktop-companion-20260920/04-roster-artwork.png) · [伙伴详情](desktop-companion-20260920/05-detail-artwork.png) · [对话准备页](desktop-companion-20260920/06-conversation-artwork.png)

## 验收边界

真实硬件的扬声器、显示屏和现场说停效果未冒充验收：本机没有连接 BOX-3 串口，也没有板端画面/声音反馈。此处完成的是平板到真实主机的绑定与表达权威确认，以及现有 Channel/固件自动化验证。真机故障是“离线提交、结束进程、联网恢复”；“主机成功但丢响应”由故障测试覆盖。空白 Host 初次初始化和多台硬件持续长跑未在本轮人为重置/制造。

此前对话页的“恢复已有登记”阻塞已由独立任务修复，根因为旧检查点与当前可信 Authority 的 Owner generation 不一致。详见 [根因与修复](mobile-body-recovery-2026-09-20.md)。修复保留设备身份，通过现有正式准入流程完成当前主机登记。

2026-09-20 用户现场完成以下三项并确认“都验证了。回复正常”：按住说话后字幕与语音回复；结束并彻底关闭 App 后再次对话无需重新登记；切换伙伴后形象、回复身份及声音对应。上述为用户现场验收，解除 Mobile 对话阻塞；不扩大到 BOX-3 物理输出或自由对话打断。修复后 Mobile 全量 1126 passed / 8 skipped，静态分析通过，最新 APK SHA-256 见根因报告。
