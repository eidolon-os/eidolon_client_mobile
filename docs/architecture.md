# Eidolon Mobile Client 架构

## 当前优先级：Host Control first

当前 App Shell 默认进入 `features/host_setup`，只与 `eidolon_admin` 的 Local API
交互。当前开箱链路是：

```text
SetupWizard -> BLE commissioning -> NetworkManager + Controller claim
            -> save ManagedHost
            -> mDNS candidate + pinned HTTPS
            -> Local Controller session
            -> GET/PUT /api/local/v1/setup/workspace
            -> Local API -> Admin internal onboarding -> Data Workspace Authority
```

Mobile 不直接访问 Admin 运维 API。BLE Host access、LAN authentication 和 Workspace
onboarding 是三个连续但独立的完成点：Host claim 成功后立即持久化，后半段失败不会
回滚网络或认领；用户可从已保存 Host 的“连接主机”入口恢复 Workspace operation。

`host_setup/workspace_models.dart` 严格消费 Local API 的产品投影，不接触 Data/Admin
内部 operation fingerprint 或服务凭证。Local API 使用稳定 Host operation 恢复中断，
Mobile 不保存第二份可写的 Workspace ready 状态。

Workspace ready 后，Mobile 读取 `GET /api/local/v1/workspace/runtime`。Local API 从
Controller session 推导 Owner，Admin 再通过 System Directory 声明的只读 runtime
authority endpoint 访问 Data。返回值只包含 Owner 显示名、主 Companion ID、Persona
版本摘要和 Memory Realm ID；raw Persona genome 与 runtime config 留在系统内部。
Workspace/runtime 的 operation、Owner 和主 Companion 必须一致，否则 Mobile 拒绝展示。

日常产品层不再由页面直接持有 URL、Bearer token 或 Local API client。边界拆分为：

```text
HostProductSession
  -> BLE trust refresh / mDNS rediscovery / Host identity verification
  -> short-lived Controller authentication and one bounded re-authentication
HostWorkspaceRepository / HostDevicesRepository
  -> typed Local API operations
HostProductController
  -> independent connection / Workspace / runtime / Devices degradation
Flutter pages
  -> My Eidolon / System / Devices presentation only
```

每次全量刷新重新进行 mDNS 发现，因此 DHCP 地址变化不会复用陈旧 IP。Controller session
返回的 reset epoch 必须与 Host overview 一致；业务请求遇到 401 时只重新认证一次，若主机
已 Reset 或 Controller 已撤销，则清空整个产品会话，不继续展示“已安全连接”。

原有 `ClientPage`、`ClientController`、HubClient 和 LiveKit session 暂时作为保留的
Conversation 功能存在，不参与默认启动，也不在 Host Control 阶段调试。

## 保留的 Conversation 实现

以下能力来自原 Audio Demo，代码与测试继续保留：

1. 从已认证 Local API 取得 Owner bundle，并只接受其中与当前 Owner
   Domain trust anchor 和签名目录一致的逻辑 Authority endpoint。
2. 在 AndroidKeyStore 里持有一把 P-256 operational key，并从它的 SPKI 派生这台设备的
   `device-instance-<sha256>` —— 与 ESP32 同一条规则（`device_instance_identity.dart`）。
   这台手机用它提出自己的 Enrollment：`create → collect → ack` 由
   `device_setup/mobile_body_enrollment.dart` 编排，走与 ESP32 完全相同的一条链路。
   提出与批准是两次调用而不是一次 —— 软件路径上两者是同一个人，把它折成一步就是
   在补偿裁决 W1 明确拒绝补偿的那个弱化。`hub_client.dart` 里那条旧的签名注册路径
   （`X-Device-ID` 等头）在 Hub 上已无对端（命中数 0），产品配置下不再被调用。
   设计依据见 `docs/设备与Body/纯软件Body准入身份裁决.md`。
3. 读 Admission 的 recovery 投影，把这台手机的处境报成 `MobileBodyStanding` 的七段之一
   （`mobile_body_standing.dart`），每段说清发生了什么、缺什么、谁能动。不能自行前进的几段
   停止轮询，并指名缺口而不是给一个「再试一次」。
4. Active 之后是**一条**长期持有的 LiveKit 通道，客户端在其上声明要不要说话；不再是
   control room + voice room 两个房间（`eidolon_session.dart` 的首段注释记着为什么）。
   **ClaimActive 到通道之间这条边在移动端还没有实现**（`configuration:pull` 无 Dart 客户端），
   所以 `HubConfigStatus.active` 在移动端产品路径上目前不可达。
5. 发布麦克风音轨时明确启用 WebRTC AEC、NS、AGC，支持全双工对话。
6. 接收 LiveKit data topics（UI state、session control、control command），并为控制命令返回 ack/result。
7. 订阅并渲染远端视频轨，给后续数字人留出直接对接点；首版默认仅请求音频会话。

## 模块边界

```text
Flutter UI / ClientController
    |-- HubDiscovery ------ Android NsdManager (mDNS)
    |-- DeviceIdentity ---- Android Keystore (P-256 / ECDSA)
    |                       Kotlin 只导出 SPKI；instance id 由 Dart 按契约派生
    |-- Admission --------- GET  /api/admission/v1/enrollments（只读，经 Host Local API）
    |                       POST ...                       ← 未实现，见准入身份裁决
    |-- EidolonSession ---- 一条长期 LiveKit 通道
    `-- VadProcessor ------ 可替换接口，首版 NoOp
```

Android 原生层只承载平台强相关能力。Hub 协议模型、注册流程、会话状态机和 UI 均在 Dart 层，后续 iOS 只需补齐 discovery/identity/permission 的平台实现。

## Local API transport

Android pinned HTTPS 被定义为有界 unary transport，不维护第二份 Local API
route/method 白名单。MethodChannel 协议版本化，request/response body 使用 Base64
保持字节语义，并在 Dart 与原生两侧限制大小。原生错误分类为 invalid request、
secure channel、timeout、unreachable 与 I/O；UI 不得用无类型 `catch` 把客户端契约
错误误报为 Workspace 服务故障。

Mission Control 的长生命周期事件流不复用 unary bridge；后续使用独立 streaming
transport 管理 cursor、重连、去重和 App lifecycle。

## 外部 Device Setup

`features/device_setup` 已建立独立的 provisioning、admission 与 checkpoint Port。
它不依赖 Host Bootstrap transport，也不保存 Wi-Fi 密码。网络配置与 Owner admission
使用两个正交状态轴；Admission 失败只前向重试，不撤销已成功的设备配网。

非敏感 checkpoint 通过统一 `AppPreferences` adapter 持久化，写入串行化并逐条隔离
损坏数据；只保留有界的最近记录。checkpoint model 不接受 Wi-Fi 密码、pairing secret
或 Controller 凭据。当前 legacy Hotspot 没有可信 Device 身份，因此不会创建产品
checkpoint；持久化 store 留给完成真实 pairing/admission 契约后的产品 adapter。

当前 ESP32 build 实际优先使用开放 Hotspot + HTTP `/submit`，没有产品 Device Identity
证明或 enrollment receipt。因此 Mobile product coordinator 默认拒绝把它当作产品完成
链路。完整审计与推进条件见 [product-surface-plan.md](product-surface-plan.md)。

## AEC 决策

首版使用 LiveKit Flutter SDK 下层 WebRTC 的音频处理，并在 `AudioCaptureOptions` 显式开启：

- `echoCancellation`
- `noiseSuppression`
- `autoGainControl`
- `voiceIsolation`

这条链路能够把远端播放参考信号交给 WebRTC AEC，适合手机扬声器全双工场景。VAD 不与采集/传输代码耦合，后续可在 `VadProcessor` 接入本地模型并选择仅上报状态或参与发送门控。

## 首版不做

- 本地唤醒词和本地 VAD 决策。
- 后台常驻、锁屏保活、蓝牙耳机的完整产品化策略。
- 数字人生成服务；但客户端已经能订阅并渲染远端视频轨。
- iOS 原生桥接实现与发布配置。
