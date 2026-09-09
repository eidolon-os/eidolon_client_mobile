# Eidolon Mobile Client

当前首要目标是成为无屏 Eidolon OS 主机的接入和管理界面。App 首次启动进入
Setup；主机无需预先联网，Android 通过 BLE 与 `eidolon-bootstrapd` 完成可信配网
和 Controller 认领：

```text
Mobile Setup -> BLE GATT -> pinned TLS -> bootstrapd -> NetworkManager
             -> LAN pinned HTTPS -> Local API -> Admin -> Data Workspace Authority
```

Mobile 同时作为标准虚拟 Device，通过已选主机的「打开对话」进入对话页。
首次接入在页内分两次明确操作：登记本机、核对身份后确认接入；随后沿标准
Admission → collect → ACK → Device Control → Channel 流程准备。

```text
Owner 可信目录 + operational key + Claim → Device Control → LiveKit Channel
                                                       → session_open / close
Controller 管理能力 → 明确批准本机提案 / 选择本机应答伙伴（标准 BodyAssignment）
```

已接入设备直接使用保存并校验的 Owner 目录和 Claim 查询配置，不依赖管理审批
列表。伙伴选择沿用到后续对话；对话中切换会结束旧会话、确认绑定后开启新会话。
原音频开发页保留用于兼容测试，不是产品默认入口。

## 已实现

- 首次使用入口、Setup 向导、我的 Eidolon、主机详情和独立换网/恢复入口。
- Debug 6 位 Setup 码（Host 固定开发码或临时码）；先发现 Host，再输入数字码，不导入 JSON。
- Android 12+ Nearby Devices 权限及旧 Android BLE/location 权限处理。
- 按固定 BLE Service UUID 扫描；广播 marker/RSSI 只展示和排序候选，不作为身份认证。
- 验证 Host 签名的动态 commissioning endpoint，并 pin P-256 TLS SPKI。
- Android GATT Write/Indicate 可靠链路和平台 `SSLEngine` TLS 1.2+ client。
- Wi-Fi scan/configure/confirm/rollback 与 Controller claim 完整向导。
- 独立 Android Keystore Controller P-256 key；与 Mobile Body/Hub key alias 隔离。
- 已认领换网使用 Controller challenge 签名，不复用一次性开箱 secret。
- 已认领 Host 的公开信息与 Controller ID 本地持久化；secret、Wi-Fi 密码和私钥不写入。
- 读取 `GET /api/local/v1/host`，严格解析 Host ID、公钥指纹、运行模式以及
  claim/network/workspace/recovery 状态。
- Controller-authenticated `GET/PUT /api/local/v1/setup/workspace`；认领后通过
  mDNS、pinned HTTPS 和短期 Controller session 创建或恢复首个 Owner、主
  Companion 与 Workspace。
- Controller/Owner-scoped `GET /api/local/v1/workspace/runtime`；只展示主 Companion、
  当前 Persona 版本和 Memory Workspace 的安全摘要，不把 raw Persona 或 runtime
  config 暴露给 Mobile。
- 「主机监控」读取 Controller-authenticated `GET /api/management/v1/host/monitor`，
  展示 CPU/NPU 型号与逐核占用、内存/磁盘、服务和进程资源，以及可展开的运行路径、
  脱敏启动命令、PID、用户和启动时间。仅显示当前快照；代码常量默认每 10 秒刷新，
  后台和路由不可见时暂停，不存历史数据。完整方案见 [主机监控计划](docs/host-monitor-plan.md)。
  主机采集支持 Linux systemd/cgroup v2 和 macOS supervisord；NPU 使用 RKNPU 驱动提供的逐核读数，
  不支持或无权限的指标明确显示不可用。旧 Host 需更新 SDK、Kernel 和 Admin 后端。
- Host 产品会话统一承担 mDNS 重发现、Host pin/身份校验、Controller 认证和一次有界
  重新认证；IP 变化与会话失效不再由各业务页面重复处理。
- Host 在 Workspace 前先保存；LAN/Admin/Data 暂不可用时只暂停后半段，不回滚
  Wi-Fi 或 Controller claim，可从“连接主机”继续。
- Host Setup 不直接调用 Hub、LiveKit 或 Audio Channel；主机服务只经 Local API 契约。
- Android pinned HTTPS 使用版本化、二进制安全的 unary transport；HTTP 方法契约由
  Local API client/server 拥有，平台 adapter 不维护重复的 route-level 白名单。
- 外部 Device Setup 已拆出 provisioning/admission/checkpoint Port 和前向恢复状态机。
- Device Setup 的非敏感 checkpoint 已提供有界持久化实现，支持并发写入和损坏条目
  隔离；Wi-Fi 密码、pairing secret 与 Controller credential 不进入持久化。
- 独立 Devices 页面展示主机确认的 mounted inventory、Companion attachment、revision
  和详情；不从 mount 事实臆断设备在线。
- 已提供明确隔离的兼容设备开发配网入口：Android 通过系统网络选择器连接当前
  `eidolon-*` 热点，使用设备 `/scan` 与 `/submit` 配置 Wi-Fi；UI 不会把成功结果
  表示为 Device 认领、挂载或添加完成。
- 原 Audio Demo 的控制器、AEC、Avatar 和回归测试均保留。

- Android 不再读取 Host 发布的直连注册地址；产品路径从已认证 Local API
  取得 Owner bundle，Owner Domain 签名目录才决定逻辑 Authority endpoint。
- Android Keystore 内不可导出的 P-256 私钥；签名 canonical request 与 ESP32
  客户端一致。
- Hub `pending_approval`、`waiting_binding`、`active`、撤销状态处理及自动刷新。
- LiveKit control room 与 voice room、`room.join`、`config.refresh`、
  `device.identify`、ACK/result、`session_end`。
- 麦克风发布显式开启 WebRTC AEC、降噪、自动增益和 voice isolation。
- 转写/UI 状态接收、麦克风静音、远端视频轨渲染。
- 响应式 UI：手机/平板竖屏使用单栏，宽屏平板横屏使用舞台与控制双栏。
- `VadProcessor` 扩展接口；首版使用 `NoOpVadProcessor`。

详细设计见 [docs/architecture.md](docs/architecture.md)。
Mobile 产品层与 ESP32/Mission Control 的真实契约门槛见
[docs/product-surface-plan.md](docs/product-surface-plan.md)。

## 环境

- Flutter 3.44+ / Dart 3.12+
- Android SDK，JDK 17
- Android 7.0（API 24）或以上真机
- 首次开箱不要求手机与 Host 已在同一局域网

本机开发工具位置：

```text
Flutter SDK: ~/Developer/flutter
Android SDK: ~/Developer/Android/sdk
JDK 17:      /opt/homebrew/opt/openjdk@17
```

## 运行

```bash
flutter pub get
flutter run
```

开发测试阶段可由 Host 配置固定 6 位码，也可执行
`eidolon-bootstrapctl dev code --ttl 600` 签发临时码。固定的只是码值；
commissioning session 仍然短期有效，连续 5 次失败后失效。产品
release 不显示该入口；制造二维码/扫码入口尚未实现，不能把
开发数字码当作产品带外信任方案。

也可以使用项目内的 Android 运维脚本。工具链默认读取 `~/Developer` 下已经
安装的 Flutter 与 Android SDK：

```bash
./scripts/android-mobile.sh devices
./scripts/android-mobile.sh diagnose
./scripts/android-mobile.sh build
./scripts/android-mobile.sh install --serial df331f93
./scripts/android-mobile.sh restart --serial df331f93
./scripts/android-mobile.sh reinstall --serial df331f93
./scripts/android-mobile.sh logs --serial df331f93
```

`install` 使用覆盖安装并保留应用数据；`reinstall` 会先卸载再进行干净安装。
Android 设备 ID 基于系统的 `ANDROID_ID` 确定性生成，因此使用同一 Android
用户和同一 APK 签名密钥重装后，Hub 中仍是同一个 `device_id`。卸载会删除
AndroidKeyStore 私钥，所以干净重装后 Hub 会在原设备记录上发起安全的密钥
重新登记，需要管理员再次批准，不会创建另一台设备。

Host Controller 使用另一个 Keystore alias。卸载 App 会删除 Controller 私钥，不能
仅靠本地记录恢复主机权限。此时由持有主机的人执行 `eidolon-ops controller-reset`
撤销全部 Controller，再像首次开箱一样重新认领；Owner、Companion、记忆、网络和
已准入设备都不受影响。App 不会因为连不上就自动开放认领。

BlueZ、NetworkManager、Android GATT/TLS、LAN mDNS 和 Controller session 已在当前
Pi 5/Android 平板/路由器组合上完成过一次真实 Host commissioning 与重启恢复；该结果
不能外推为完整网络兼容矩阵。当前 Pi/Android 已真实完成首个 Owner、主 Companion 和
Workspace 创建，并在新建 Controller session 后重复读取到 ready；Data outage、进程重启、
重复提交和 App kill 的实机故障矩阵仍未完成。自动化已覆盖重复提交、Local API 重启后
重新认证、runtime authority 降级以及跨 Owner/Companion 拒绝。产品二维码、物理
recovery、Factory Reset 和 iOS 仍是后续项。

下面的 Hub 注册和 Audio 使用说明属于保留的后续 Conversation 功能，当前不再是
App 首次启动流程。待 Host 达到产品定义的 ready 状态后，再恢复对应入口。

若 Android 网络环境拦截 mDNS，可点击“手动输入地址”，格式示例：

```text
http://192.168.1.10:8082/api/device/register
```

## AEC 验证建议

真机使用扬声器播放远端 TTS，并在本地持续说话。服务端录制或 STT 输入中不应
出现明显的远端 TTS 回灌。首版使用的是 WebRTC/设备音频 HAL 所提供的 AEC；
后续可增加机型白名单、耳机/蓝牙路由和客观 ERLE 指标测试。

## License

Copyright © 2026 Li Jinsong.

本项目允许依据 [PolyForm Noncommercial License 1.0.0](LICENSE) 进行许可范围内的
非商业使用。商业使用需要另行取得书面授权，请联系
[lijinsong@aimanthor.com](mailto:lijinsong@aimanthor.com)。

许可范围、第三方例外和必要声明见 [LICENSING.md](LICENSING.md) 与 [NOTICE](NOTICE)。
