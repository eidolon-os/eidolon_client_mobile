# 设备配网：释放设备热点后把手机自己的 Wi-Fi 要回来

日期：2026-11-15。相关文档：[device-setup-host-return.md](device-setup-host-return.md)（10-09）。

## 现象

StackChan 用扫码配网，在 Mac Host 上恢复网络。配网本身成功了：设备已提交，连回家里的 Wi-Fi，
Hub 激活成功，LiveKit 也已就绪。但 App 一直停在「3. 接入主机 · 进行中」，没有任何提示。

## 证据（华为平板 BAH3-W59，Android 10 / EMUI，App 0.1.0）

- `02:24:48.203 Observed committed terminal evidence` 之后，App 撤销了设备热点的网络请求。系统日志是
  `NetworkAgentInfo [WIFI () - 103] got DISCONNECTED, was satisfying 14` 和
  `CTRL-EVENT-DISCONNECTED ... locally_generated=1`。
- `dumpsys wifi` 里 WifiConnectivityManager 的日志：
  `setSpecificNetworkRequestInProgress : inProgress=false → Set WiFiConnectivityManager disabled → Stopping`。
  上一次 `setTrustedConnectionAllowed` 停在 `false`，之后不再扫描，也不再回连。
  此后单次扫描的结果也被丢弃（`AllScan onResults returned ... mWifiConnectivityManagerEnabled:false`）。
- 平板此后没有任何网络：`Active default network: none`，`mWifiInfo ... DISCONNECTED`。
  App 对主机 `https://192.168.100.12:9002` 的每次请求都在约 5 ms 内报 `ConnectException`。
- 用 adb 把平板 Wi-Fi 关掉再打开，平板 4 秒内连回 `rcgy5#305`；1 秒后 App 显示「设备已接入这台主机」。
  Hub 里这台设备的 claim 从 10-29 起一直是 active，设备和主机都没有问题。
- 以前的配网在别的手机上完成：10-29 StackChan 由 PHK110 认领，11-05/07/08 用的是小米平板
  24091RPADC（Android 16 HyperOS）。10-09 的日志显示，App 释放设备热点后，小米平板会**立刻**尝试回连。
  这台华为平板 11-14 才装上 App，今天是它第一次配网。

## 根因

设备的配网热点是用一个带 `WifiNetworkSpecifier` 的网络请求连上的。在 Android 10 上，这条连接会**顶替**
手机原来的 Wi-Fi（只有一个射频，同一时间只有一条连接）。App 放手以后手机原来的网络能不能回来，
要看平台实现：较新的系统会回连，EMUI 10 不会，系统的自动回连一直保持关闭。

App 的代码却默认「撤销请求 = 把网络还给手机」（`close()` 的注释原话是 "give the phone its own network back"）。
实际上它只是放手，并没有把手机原来的网络要回来。之后所有到主机的流程都建立在一个已经不存在的网络上。

固件、Hub、Host 都没有问题；这次的固件改动也和这个问题无关。

## 修复

用的是 Android 自己的机制：App 用一个普通的网络请求告诉系统「我需要 Wi-Fi」，系统再按自己的自动回连
连上手机已知的网络。App 不选网络，也不碰密码或保存的网络配置。

- `OwnWifiReturn`（纯逻辑，可在 JVM 单测）负责这一段的生命周期：
  - 设备网络一被释放，就发起一个不带 specifier 的 Wi-Fi 请求（默认能力：INTERNET / NOT_RESTRICTED / TRUSTED）；
  - 一旦有**别的**网络满足这个请求，就撤销它。还在拆除中的设备热点不算；
  - 下一次访问设备前撤销（射频要交给新的这次访问）；
  - `DeviceProvisioningManager.destroy()` 时撤销。
- `DeviceProvisioningManager.releaseDeviceLocked()` 本来就是设备网络唯一的释放点，现在由它在这里把网络交还给手机。
  `joinDeviceNetwork()` 开始一次访问前先撤销还没满足的交还请求。
- 在手机本来就没离开原网络的系统上（同时支持两条连接），或系统自己会回连的系统上，这个请求会立刻被满足并撤销，
  行为和以前一样。

所有调用点都不需要按版本分支，也不改 Dart 侧的流程。主机不可达时的等待逻辑（10-09 的 `hostReturnBudget`）保持不变，
仍是手机确实连不回去时（例如路由器拒绝接入）的兜底。

## 验证

- `OwnWifiReturnTest`：8 项，覆盖发起请求、被别的网络满足后撤销、忽略还在拆除的设备热点、
  新的访问抢占、过期回调不起作用、重复释放不会叠加请求、从没连上设备也会交还、关闭时撤销。
- 真机（BAH3-W59，同一台平板、同一台 StackChan，装的是本修复的 debug 包；Host 换成了 main-20261114-a9374453）：

  | 时间 | 修复前（02:24） | 修复后（02:54） |
  |---|---|---|
  | 设备提交 | 02:24:48.203 `Observed committed terminal evidence` | 02:54:51.115 同左 |
  | 释放后 | `Auto connect disabled`，此后 7 分钟以上不扫描、不回连，直到手动关开 Wi-Fi | 02:54:51.160 `Asked Android for the phone's own Wi-Fi back` |
  | 先被提供的网络 | — | 02:54:51.167 仍在拆除的设备热点（network 107），被忽略 |
  | 回连 | 无 | 02:54:52.043 `Trying to associate with SSID 'rcgy5#305'`；02:54:53.298 network 108 CONNECTED |
  | 请求撤销 | — | 02:54:53.467 `Own Wi-Fi request settled` |
  | 到达主机 | 每 3–5 秒一次 `ConnectException`，一直持续 | 02:54:53.554 第一个 9002 请求成功；Hub 02:54:58 批准，02:55:02 claim active |

  释放后 0.9 秒开始回连，2.4 秒后到达主机；设备列表里 StackChan 显示「在线」。

## 手机确实连不回去时：「接入主机」要说清楚（同日补充）

上面的修复让系统自己把网络连回来。但如果路由器拒绝接入（10-09 那次）、手机被切到别的网络，或者系统也连不上，
手机还是到不了主机。以前这时「接入主机」这一步什么都不说，原因有两个：

- 协调器在恢复接入时，把「没连到主机」和「主机回答了失败」混在一起，都记成 `admission_unavailable`，
  页面分不出是哪一种；
- 页面每 3 秒一次的后台读取走的是用户命令的路径（`_run`）：每次都把忙碌状态打开、把提示清空。
  主机不在时，每次读取都要先用 mDNS 找约 5 秒主机，所以大约每 8 秒里有 5 秒，屏幕只有一个
  「正在从主机恢复设备接入状态」的转圈，所有按钮都隐藏；剩下 3 秒才闪一下「当前网络到不了这台主机。」。
  这时既没有一句话能停留到读完，也没有一个出口能停留到点上（证据：before_toggle.png 和 02:24 那次的 logcat 节奏）。

### 改动

- 「没连到主机」只有一个定义：`host_setup/host_reachability.dart` 的 `hostNotReached`
  （从配网页原样搬出，10-09 取 voucher 时的等待和这次都用它）。协调器恢复接入时按它分级：没连到记成
  `host_not_reached`（可重试）；主机回答的失败仍然是 `admission_unavailable`，照旧显示错误卡片和「从主机恢复状态」。
- `host_not_reached` 时页面不显示错误，而是显示一张说明卡「手机还没回到主机所在的网络」：
  知道配网前手机连的是哪个 Wi-Fi 时就点名；给一个「打开 Wi-Fi 设置」按钮（Android 10 以上打开系统的 Wi-Fi 面板，
  面板浮在 App 上方；没有面板的系统打开 Wi-Fi 设置页）；并说明设备这边不用再操作。步骤行显示
  「3. 接入主机 · 等手机回到主机网络」，进度行显示「手机连回后会自动继续接入」。手机连回以后自动往下走，不需要再点任何按钮。
- 后台读取（`_observeAdmission`）不再走命令路径：不占用忙碌状态，不清空提示，只有读取到结果才更新屏幕。
  从系统设置回到 App 时立刻读一次。「重新设置设备」会先等正在进行的读取结束，免得这次读取把刚删掉的进度又写回来。
- 10-09 那个「手机还没回到主机所在的网络」页面（取 voucher 超过预算后显示）共用同一段说明和同一个按钮。

### 验证

- `device_setup_page_phone_off_host_network_test.dart`，共 3 项：
  - 说明卡稳定显示；读取进行中提示和出口都还在；按钮能打开 Wi-Fi 设置；连回以后自动完成；
  - 主机回答的失败仍然显示错误卡片；
  - 读取进行到一半时点「重新设置设备」，不会把进度写回去。去掉「先等读取结束」那一行后，这项会失败，已确认。
- 协调器测试新增 1 项：直接连不上，或重新定位时只遇到沉默 → `host_not_reached`；返回 503 → `admission_unavailable`。
- 两次访问测试新增断言：取 voucher 超过预算后的页面会点名「owner-wifi」，并能打开 Wi-Fi 设置。
- 全量测试 1496 项通过（8 项是原来就跳过的）；`flutter analyze` 没有新增问题；debug APK 构建通过。
- 真机（BAH3-W59，15:46，本提交的 debug 包；平板上放了一条临时的「恢复网络」待续记录，指向在线的 StackChan
  `device-instance-77abed88…`，这条路径只读取主机的 claim 列表；测试结束后已删除，其他数据不动）：

  | 时间 | 发生了什么 |
  |---|---|
  | 15:46:24 | 关掉平板 Wi-Fi，点「继续接入」 |
  | 15:46:25 → 15:47:02 | 每 3–5 秒一次到 9002 的 `ConnectException`，中间有 mDNS 查找。连续 7 张截图（间隔约 2.5 秒）里，说明卡、「打开 Wi-Fi 设置」「重新设置设备」都一直在，没有闪动 |
  | 15:47:05.402 | 点「打开 Wi-Fi 设置」：`START act=android.settings.panel.action.WIFI cmp=com.android.settings/.panel.SettingsPanelActivity`，WLAN 面板浮在页面上方 |
  | 15:47:17 → 15:47:21.789 | 在面板里打开 WLAN，连上 `rcgy5#305` |
  | 15:47:24.643 → 15:47:24.680 | 点面板的「完成」回到 App，37 ms 后第一个到主机的请求完成；随后页面显示「设备已接入这台主机」，全程没有再点任何按钮 |
