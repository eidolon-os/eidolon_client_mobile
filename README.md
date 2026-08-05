# Eidolon Mobile Client

当前首要目标是成为无屏 Eidolon OS 主机的接入和管理界面。App 默认进入 Host
Setup，通过树莓派上 `eidolon_admin` 提供的 Local API 读取 Host Identity 和
Bootstrap 状态：

```text
Mobile Host Setup -> eidolon-local-api -> bootstrapd
```

现有 Hub/LiveKit/Audio Demo 保留在同一 codebase，但已退出默认启动流程，等主机
初始化和管理闭环稳定后再重新接入：

```text
mDNS 发现 Hub -> P-256 签名注册 -> 审批/绑定 -> LiveKit control room
                                            -> voice room + AEC 对话
```

## 已实现

- 默认 Host Setup 页面和版本化 Local API client。
- 读取 `GET /api/local/v1/host`，严格解析 Host ID、公钥指纹、运行模式以及
  claim/network/workspace/recovery 状态。
- Debug 构建可手工输入 Local API 地址，或通过 `EIDOLON_LOCAL_API_URL` dart-define
  注入开发地址；地址不接受 credentials、query、fragment 或 Admin 子路径。
- Host Setup 不调用 Admin 运维 API、Hub、LiveKit 或 Audio Channel。
- 原 Audio Demo 的控制器、AEC、Avatar 和回归测试均保留。

- Android mDNS/NSD 发现 `_eidolon-hub._tcp.local.`，支持手动输入
  `register_url` 作为调试兜底。
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

## 环境

- Flutter 3.44+ / Dart 3.12+
- Android SDK，JDK 17
- Android 7.0（API 24）或以上真机
- 手机与 Eidolon Hub 在同一局域网

本机开发工具位置：

```text
Flutter SDK: ~/Developer/flutter
Android SDK: ~/Developer/Android/sdk
JDK 17:      /opt/homebrew/opt/openjdk@17
```

## 运行

```bash
flutter pub get
flutter run --dart-define=EIDOLON_LOCAL_API_URL=http://eidolon.local:9002
```

当前 Local API 端点是只读的。开发环境需要让 `eidolon-local-api` 监听手机可访问的
接口；产品环境将由受控的本地入口暴露，不能直接开放 Admin API。未提供 dart-define
时，用户可以在 Host Setup 页面手工输入地址。

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
