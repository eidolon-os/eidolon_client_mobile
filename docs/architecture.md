# Eidolon Mobile Client Demo 架构

## 首版目标

首版以 Android 真机可运行、可与现有 Eidolon Hub/Channel 联调为验收口径：

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

