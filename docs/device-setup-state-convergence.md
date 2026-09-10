# Mobile 配网与设备授权状态收敛修复

日期：2026-09-10。

## 现象与证据

用户报告：新设备配网/授权已成功，但当前页面停留，返回上一级才显示结果，过程像重复扫描、连接。

测试平板 `EidolonDeviceSetup` 日志显示：02:23:56 第一次连接设备；02:24:28 第二次连接；02:24:29 下发并应用 Wi-Fi；02:24:37 收到 committed terminal evidence，并完成 terminal ACK。此日志证明该轮配网已提交，没有证明提交后又发生了一次写入。

两次 SoftAP 连接是现有标准流程：读取设备并 prepareOwner，关闭 SoftAP 后向 Host 取得该设备密钥对应的 voucher，再连接设备下发配置。Host 在 SoftAP 连接期间不可达，因此不能为减少连接次数而把 Host 请求塞进配网连接内。

## 代码确认的问题

1. 配网页每次 `_finish` 的局部 `networkCommitted` 与持久化 checkpoint 各自决定页面步骤。重复回调被 `_run` 忽略后，仍能用局部 false 把正在执行的页面退回 Wi-Fi 表单。
2. Coordinator 每次 provision 都重建 selected checkpoint，没有先检查该 setup 已提交的事实；页面反复创建 coordinator，也无法统一互斥执行。
3. 平台 adapter 在返回提交证据前额外关闭连接；清理异常会把已提交的配网报告为失败。
4. 授权页仅在进入、回前台或手动刷新时读取投影。批准后的 Grant 交付和 Claim 生效不会主动反映在当前页面。
5. 配网页恢复过滤掉 ready checkpoint，即使它正是当前任务；放弃旧任务的标记又会拦住后来新任务的自动恢复。
6. Android 的旧 NetworkCallback、延迟启动、描述符响应和 commissioning 收尾缺少当前连接归属检查，可能影响后续连接。日志未证明该竞态在本次报告中实际发生。

这些是 Mobile 编排层与连接生命周期的问题，不要求改变服务端的设备准入架构。

## 修复边界

- 复用现有 DeviceSetupCoordinator、checkpoint 和 Admission recovery 接口。一个页面持有一个 coordinator；同一任务的并发操作合并，已持久化的 networkConfigured 进入准入恢复，不重新开连接或写网络。
- Coordinator 先保存 checkpoint，再通知页面；页面据此展示进度。连接清理不再决定业务成功与否。
- 两个页面复用一个轻量查询调度器：串行查询、后台暂停、完成或拒绝停止。授权页的查询不会再次发起批准；配网恢复沿用既有不可变 Decision 意图及幂等 ID。
- 当前任务按 setupId 读取，包括 ready 状态；放弃旧任务不阻止新任务后续收敛。
- Android 在网络回调、延迟启动、描述符响应和收尾释放时核对连接归属，关闭前先撤销旧请求身份。
- 第一轮读取设备身份/扫描网络无论成功失败都释放连接。

仍由设备 committed terminal evidence 与 ACK 确认配网，仍由 Host 的标准 ApprovalDecision、Grant、ClaimActive 判断准入完成。没有增加 Mobile 特殊设备分支，没有用“命令已发送”或“已批准”冒充设备已接入，也没有替换 SDK 或协议。

## 验证

- Flutter 全量：918 项通过，5 项既有跳过。之后补充重新设置场景和清理异常断言，相关测试 30 项通过、1 项既有跳过。
- 回归覆盖：同帧重复确认；重启后不重复写已提交网络；成功 checkpoint 在清理前持久化并通知；清理失败仍能取得提交证据；两次连接仅一次写入；重新设置后自动完成；当前任务采用已完成 checkpoint；授权页原地跟进 Grant/Claim、后台暂停、终态停止、只批准一次。
- `flutter analyze --no-pub`：通过。
- Android debug APK：构建通过。
- App 原生测试 `:app:testDebugUnitTest`：47 项通过，包括 commissioning lease 的提交与 ACK 测试。全工程 Gradle 单测触发第三方 image_picker SDK 36 测试，因本机 Java 17 而失败（要求 Java 21）。

真机范围：已读取本轮旧版本日志。尚未在修复版本上重新执行实体设备配网与授权验收；自动化测试不能替代这一步。没有清空设备身份或重置现有配网。
