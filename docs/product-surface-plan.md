# Mobile 产品层边界与推进顺序

状态：实施中
复核基线：2026-08-07 当前本地工作树与已合入产品分支

## 1. 产品入口

Mobile 是普通用户访问 Eidolon OS 的本地产品入口，不是缩小版 Admin Web。
所有日常能力必须经过 Controller-authenticated、Host-pinned 的 Local API allowlist。
Mobile 不接收 Admin、Hub、Kernel 的运维凭据，也不通过 WebView 或通用反向代理访问
这些服务。

```text
Mobile App Shell
  ├─ Host Setup / Recovery
  ├─ My Eidolon / System / Workspace
  ├─ Devices
  │    └─ Add Device -> Device Setup
  ├─ Mission Control (read-only)
  └─ Conversation

Mobile -> pinned Local API -> product adapters -> owning authorities
```

各 feature 有独立状态机。Host Setup、Device Setup、Mission Control 与 Conversation
互不拥有对方的完成状态，也不能因为一个 feature 降级而回滚另一个 feature 已提交的事实。

## 2. 当前真实能力矩阵

| 产品面 | 当前真实能力 | Mobile 决策 |
|---|---|---|
| Host Setup | BLE commissioning、Wi-Fi、Controller claim、LAN auth 已实现 | 保持独立恢复入口 |
| Workspace | Local API `GET/PUT /setup/workspace` 已实现 | 完成首次 Owner/Companion/Workspace；失败不回滚 Host |
| System | Host/Bootstrap 正交状态与 IP 可读；换网已有 BLE 流程 | 作为 My Eidolon 的系统卡片，不开放 Supervisor/日志/配置 |
| Admin Web control plane | 当前产品分支只有运维型 Device Admission/Mount 编排，要求操作者输入 Hub credential | 只复用领域语义；不能把 credential 输入或 Admin route 搬到 Mobile |
| Mission Control | Data V2 产品分支已移除旧跨库聚合；旧 cockpit 分支不是当前可用 producer contract | 等 Owner-scoped projection API 后接 snapshot + stream，不复活跨库读取 |
| ESP32 provisioning | 当前目标 build 同时设置 Hotspot/BLUFI，但预处理顺序实际选择 Hotspot；开放 `Xiaozhi-XXXX` AP + 明文 `/submit` | 只认定为 development provisioning；不能当作产品 Device claim |
| Hub onboarding | enrollment/handoff 与 management approval contract 已存在 | ESP32 固件须先迁移；Mobile 只经 Local API 批准，Owner scope 不由 App 自报 |
| Conversation | Hub/LiveKit/AEC Demo 保留 | Workspace 与 Mobile Body admission ready 后恢复入口 |

## 3. 已建立的 Mobile Device Setup 边界

`features/device_setup` 已建立以下独立 Port：

- `DeviceProvisioningTransport`：发现并连接外部 Device；实现可以是 Hotspot、
  ESP-BLUFI 或后续协议，但不能依赖 Host Bootstrap transport。
- `DeviceProvisioningSession`：读取可验证 Device descriptor、扫描/配置网络，等待
  Device 用自己的 Identity 提交 enrollment 后返回 receipt。
- `DeviceAdmissionPort`：经 Local API 向当前 Controller Owner scope 前向推进
  approval / mount / attachment；请求中没有可由 App 任意填写的 `owner_id`。
- `DeviceSetupCheckpointStore`：只保存非秘密 checkpoint。Wi-Fi 密码、retrieval token、
  Controller secret 不进入 checkpoint。

状态由两个正交轴表示：

```text
provisioning: notStarted -> selected -> configuringNetwork -> networkConfigured
admission:    notStarted -> awaitingEnrollment -> pendingApproval
                         -> approved -> binding -> ready
```

网络配置成功、Admission 暂时失败时，不清除 Device Wi-Fi，也不重做 provisioning；
使用相同稳定 request ID 前向恢复。只有两个轴分别达到 `networkConfigured` 与 `ready`
时，UI 才能显示“设备已添加”。

产品 coordinator 默认拒绝 `developmentTofu`。当前 ESP32 Hotspot 没有制造身份证明，
即使成功写入 SSID，也只能显示“开发配网完成”，不能显示“设备已认领”。

## 4. ESP32 产品协议收口条件

在实现 Mobile production adapter 前，ESP32 provisioning 至少要提供：

1. 可验证且有有效期的 Device descriptor：Device ID、公钥指纹、setup session、
   支持的 provisioning contract；身份由制造凭据或等价带外因子绑定。
2. 不在开放明文链路发送家庭 Wi-Fi 密码；若保留 Hotspot，必须有每台设备唯一的
   setup credential 与应用层安全通道，不能只依赖开放 AP SSID。
3. Device 自己持有独立 P-256 Identity，并按 Hub 当前 enrollment/handoff contract
   提交；Host Setup 码和 Controller key 不得复用。
4. provisioning 通道向 Mobile 返回与 descriptor 相同 Device ID 的 enrollment receipt，
   或 Local API 提供等价的受信关联查询。
5. 固件与 Local API 都使用稳定 operation/request ID，能够在 App kill、设备重启、
   Hub 暂不可用时恢复到最后提交阶段。

当前 build 事实决定第一个开发 adapter 可以验证 Hotspot，但不能由此推导最终产品采用
Hotspot。Hotspot 与 ESP-BLUFI 的产品选择必须在上述身份与机密性条件下做真机矩阵，
而不是按编译开关数量决定。

## 5. Mission Control Mobile 契约门槛

Mobile Mission Control 只读。恢复它需要新的、权威边界正确的产品投影：

```text
GET /api/local/v1/mission-control/snapshot
GET /api/local/v1/mission-control/events?cursor=...
```

Local API 从 Controller session 推导 Owner scope。snapshot 必须逐 source 标注
`ok / degraded / unavailable` 和 freshness；事件必须有稳定 cursor/event ID。
Mobile streaming adapter 独立于 unary pinned HTTPS adapter，负责有界重连、去重、
App 前后台暂停/恢复。流断开只表示观测降级，不能推导 Host、Companion、Device 或
voice turn 已停止，也不能承载任何 mutation。

旧 Mission Control 的星图、时间线和 source degradation 可以作为交互语义参考，
但其跨数据库 service 不能进入当前产品分支。

## 6. 推进顺序

1. 已完成 Host Setup/Workspace 基础真机闭环以及 pinned unary transport 契约测试；
   重启、Data outage、重复提交和 App kill 属于后续故障矩阵。
2. 当前推进 My Eidolon/System/Workspace 的 Local API 产品 projection 与原生 Mobile 页面。
3. Hub 提供 Controller/Owner scope 到 management principal 的服务端交换边界后，增加
   Devices read 与 forward-only admission allowlist。
4. ESP32 固件补齐 product descriptor、安全 provisioning、enrollment receipt；实现
   第一个真机 `DeviceProvisioningTransport` adapter 与 Add Device UI。
5. 全局审计/运行时 projection producer contract 落地后实现 Mission Control snapshot
   与 lifecycle-aware stream。
6. 最后迁移 Conversation；语音失败不影响 Host 或 Device 管理。
