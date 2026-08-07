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

原有 `ClientPage`、`ClientController`、HubClient 和 LiveKit session 暂时作为保留的
Conversation 功能存在，不参与默认启动，也不在 Host Control 阶段调试。

## 保留的 Conversation 实现

以下能力来自原 Audio Demo，代码与测试继续保留：

1. 通过 `_eidolon-hub._tcp.local.` 发现 Hub，并读取 `register_url`。
2. 生成并持久化 P-256 设备身份，按 ESP32 相同的 canonical request 规则签名注册请求。
3. 处理 `pending_approval`、`waiting_binding`、`active`、`revoked`、`unregistered` 状态。
4. Active 后进入稳定的 LiveKit control room；手动或收到 `room.join` 后刷新 token 并进入 voice room。
5. 发布麦克风音轨时明确启用 WebRTC AEC、NS、AGC，支持全双工对话。
6. 接收 LiveKit data topics（UI state、session control、control command），并为控制命令返回 ack/result。
7. 订阅并渲染远端视频轨，给后续数字人留出直接对接点；首版默认仅请求音频会话。

## 模块边界

```text
Flutter UI / ClientController
    |-- HubDiscovery ------ Android NsdManager (mDNS)
    |-- DeviceIdentity ---- Android Keystore (P-256 / ECDSA)
    |-- HubClient --------- signed POST /api/device/register
    |-- EidolonSession ---- LiveKit control room + voice room
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
