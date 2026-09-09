# Mobile 对话准备与 Room 生命周期

## 需求与边界

连接 Host 后进入准备页，选择 Companion 和 PTT／半双工／全双工，再点击开始对话。Mobile 是标准虚拟 Device；本次范围是这条对话路径及页面交互。

Host 的 Controller 连接、Device 的 Claim、逻辑 Channel 与 LiveKit Room 各自保留原有职责。退出 Room 不撤销登记，不修改设备归属，不删除逻辑 Channel。设备声明模式，服务端按声明配置既有 pipeline。

2026-09-10 的 Host 切换后续修正将 App 内的虚拟 Device 按 Owner Domain 隔离；每个实例仍使用本页的标准流程。迁移、数据作用域和验收见 [Mobile Host 切换](mobile-host-switching.md)。

## 执行流程

1. 连接 Host，读取设备配置与伙伴列表，展示已绑定伙伴；不连接 Room，不打开麦克风。
2. 选择伙伴与对话方式。选择是页面草稿，刷新不覆盖草稿；没有模式选择不能开始。回到准备页保留本页选择。
3. 点击开始：通过现有 Controller BodyAssignment 确认伙伴；未变化则只读，变化则按当前 revision 提交并读回确认。
4. 使用 Device operational key 调用标准 `manifest:assert`。读取当前接受的 Manifest；内容相同不写，内容变化用接受的 revision + 1。声明被接受后重新拉取匹配配置。
5. 使用现有 Provider binding 连接 Room，用 SDK 发布静音音轨，再发标准 `session_open`。既有 worker 为 PUBLISHER 类型，发布静音轨道是正常设备接入的一部分，否则“等确认后才发布”会与服务端互等。确认前和 PTT 未按下时不发送麦克风音频。模式不放入 session_open，不新增 Mobile 专用服务端分支。
6. 收到对应 conversation_id 的 `session_started` 后启用所选模式。未确认、确认超时或错误时不收音。
7. 结束或返回：关闭麦克风、发送 session_close、断开 RTC。重新进入前台和配置刷新不会自动入房。LiveKit 负责当前连接的网络重连；终止性断开回到准备页。
8. 对话中更换伙伴或模式先确认结束，返回准备页，由用户再次开始。

## 模式行为

| 方式 | 本机行为 | 服务端行为 |
| --- | --- | --- |
| PTT | 按住收音，松手关闭；可靠发送现有 audio_state 的 ptt 边沿 | 既有 PTT 分段提交 |
| 半双工 | 自动收音；伙伴 speaking 时停收音，listening 后恢复；手动静音保持 | 既有 half_duplex pipeline 策略 |
| 全双工 | AEC/降噪开启，允许持续收音与打断 | 既有 full_duplex pipeline |

PTT 按放与麦克风异步操作按顺序执行，覆盖快速松手、手势取消、进入后台。页面展示各模式说明和当前状态，小屏可滚动，底部操作固定。

## 共享 Hub 修正

`ReconcileChannelBinding` 对已有 Channel 使用 `refresh`；仅首次建立 DeviceRef 生命周期才 provision。refresh 的 operation_id 包含当前 operation、到期时间及目标 Manifest digest/revision，A→B→A 沿当前 Channel 前进，不重放旧操作。

Provider 原先只允许过期刷新。现补全标准 refresh 的另一种有效条件：当前 active 凭据对应的 Manifest 与 Authority 新提交的不同。未过期且声明相同的刷新仍拒绝；旧 active/expired 操作原子地 fence；撤销后不能刷新复活。复用原传输资源，不修改 Claim，不引入新操作协议或设备类型分支。

## 验证记录

- Mobile 完整测试：899 通过、5 跳过（2026-09-09 最终构建）。
- 静态检查：通过。
- Hub + 真实 Provider 的跨仓 Channel reconciliation：13 通过，包含 A→B→A、重复读取、凭据续期、撤销。Manifest assertion 另有 5 项通过。
- Provider 全套测试：164 通过。
- Manifest signing 使用 SDK golden，向本地 lock 加入该原始文件；验证 bare SPKI 编码。
- 自动化覆盖模式未选、准备期不入房、声明响应丢失、revision 往返、Claim 保持、PTT 快速按放、半双工恢复、手动静音、会话确认超时、退出不重连及不同屏幕尺寸。
- 平板 `df331f93` 连接香橙派 `Eidolon-0a7989`：准备页不自动入房，未选择模式时开始按钮不可用；已有伙伴 `mac` 保持原绑定。
- 23:48:29、23:50:00、23:51:37、23:53:08 依次完成 PTT → 半双工 → 全双工 → PTT。服务端四次日志分别确认 `interaction_mode=ptt/half_duplex/full_duplex/ptt`，且全部发送 `session_started`，Room 均为 `eidolon-device-5582b08fb6be2decd55a46c3`。没有重新登记、修改 Claim 或切换 DeviceRef。
- 真机验证对话中切换模式：显示“结束当前对话？”；确认后回到准备页，不自动重开；点击开始才重新接通。
- PTT 实际按放产生一次 1600 ms 音频，服务端 `PTT result action=commit reason=segment_transcribed`，转写耗时约 430 ms。随后 LLM 拒绝请求：请求 2098 tokens 超过当前模型 2048-token 上下文。半双工也遇到相同模型限制。页面收到并显示语音服务失败提示。这证明收音、转写及提交已推进，但本次 **未通过 ASR→LLM→TTS 完整语音验收**；模型上下文配置问题不在这次 Host／Room 分离改动中修正。

## 发布记录

- Hub 提交：`03459b5d307b09897693236488778670f931e244`。
- Channel 提交：`8724e9de962688840eaaea9d904d9b752ff9a46e`。
- 香橙派：`rk3588-mobile-modes-20260909`，Ops 返回 `activated / applied`；doctor healthy、app_ready 通过。其余组件固定为上一发布版本，未重置登记或主机数据。
- Mac 开发 Host 已加载修复。换网后 RTC 仍公布旧 IP，通过现有 LiveKit 启动包装器重新生成实际地址。最初未发布音轨导致 PUBLISHER worker 无法启动，后续通过标准静音音轨发布修正，并在香橙派完成上述模式往返验证；未把早期 Mac 尝试计为完整语音成功。
- Mobile 最终 APK 已安装到平板 `df331f93`；实现、测试和本验收记录随同一提交保存。
