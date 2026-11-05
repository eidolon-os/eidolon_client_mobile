# ESP32 设备改用 BLE 配网：可行性评估

日期：2026-11-04。只做评估：没有刷机，没有改任何构建的默认配置，没有提交固件或 SDK。
固件基于 `eidolon-client-esp32@8957618a`，ESP-IDF 5.5.4，板子 BOX-3。

之后按本文做了什么、台架结果、还剩什么，见第 8 节（2026-11-05）。

## 为什么评估

ESP32 设备现在走开放 SoftAP + 乐鑫 Security 2。手机必须离开家庭 Wi-Fi 两次：

1. 第一次加入设备热点：读身份、prepare_only、扫描 Wi-Fi。
2. 回到主机网络，取 voucher。
3. 第二次加入设备热点：下发 trust 和 prov-config，等终态 ACK。

Android 每次加入设备热点都会弹出系统确认。手机回不了家网时，App 只能让人去系统 Wi-Fi 设置
（`docs/device-setup-host-return.md`，2026-10-09 平板在 `rcgy5#305` 上回网失败）。
Reachy Mini 和 Eidolon Host 都用 BLE 做控制通道，手机全程留在家网，没有这一类问题。

固件里早就有 `EIDOLON_PROVISIONING_TRANSPORT_BLE`（`main/Kconfig.projbuild:1286`，默认 n）。
它的说明写着“两种传输的端点、载荷、顺序完全相同，只是每块板的硬件选择”。
但所有维护中的板子都关着 BT，BLE 也从未在真机上验证过
（`docs/设备与Body/StackChan配网与OPi5Max连接故障复盘-20260921.md:36`）。

## 结论

- **可行，但不是打开一个开关就行。** BOX-3 打开开关后能编译通过，但直接上真机会有四个问题（第 2 节）。
  其中“载荷超过 BLE 单次上限”需要改 device_foundation v1 契约。
- **收益：** 手机不再离开家网，所以下面这些都会消失：
  - 两次访问之间的回网失败，以及 `awaitingHost` 这一步；
  - 加入设备热点的系统确认；
  - 设备单射频上 AP 和 STA 的信道争用。
  
  iOS 也有了实现路径（CoreBluetooth）。
- **代价：**
  1. 契约里要加 BLE 分片帧；
  2. 内部 RAM：默认 NimBLE 常驻 +20.7 KB，精简配置只有 +3.9 KB；运行时的动态分配要上机测（第 1 节）；
  3. 手机端新写一个 BLE 传输；
  4. 固件修三处收尾问题。
- **手机端的流程结构可以先不动。** 保留两次访问，每次访问改成一次 BLE 连接，手机仍在家网上，所以取 voucher 自然成功。
  合并成一次访问是之后的优化，不是前提。
- **对照标准方案（第 7 节）：** Eidolon 在结构上已经接近 Matter，偏离只有两处：传输和全局固定的配对口令。
  后者比换传输更要紧，因为现在 SRP 的口令是公开的。

## 1. 实测：BOX-3 编译与静态内存

方法：把固件仓库复制到临时目录（不碰共享 checkout 的 `build/`），用 `scripts/eidolon/eidolon-esp-box-3.sh build`
编译。各版本只改 BT 相关选项，再用 `python -m esp_idf_size` 解析 `eidolon.map`。

| 版本 | 静态 D/IRAM | 相对基线 | 其中 IRAM 代码 | 镜像大小 | OTA 分区余量（0x410000） |
|---|---|---|---|---|---|
| 基线（BT 关） | 162,803 B | — | 94,491 B | 3,534,912 B | 724,928 B |
| BLE + NimBLE（默认选项） | 183,507 B | **+20,704 B** | 112,919 B（+18,428） | 3,723,424 B | 536,416 B |
| BLE + Bluedroid | 194,531 B | +31,728 B | 112,859 B（+18,368） | 3,926,336 B | 333,504 B |
| BLE + NimBLE 精简 | 166,663 B | **+3,860 B** | 96,027 B（+1,536） | 3,830,688 B | 429,152 B |

精简版选项：`BT_CTRL_RUN_IN_FLASH_ONLY=y`（控制器代码放 flash；IDF 说明写可省 20 KB 以上，代价是 BLE 性能下降、
擦写 flash 时可能受影响），只保留 peripheral 角色，最大连接数 1，NimBLE 堆分配改到 PSRAM。

NimBLE 默认版增量的来源：`libbtdm_app.a`（控制器）IRAM 代码 16,970 B，`libbt.a` 975 B，
`libprotocomm.a` 391 B，`libcoexist.a` 357 B。

**为什么这 20 KB 要紧。** 2026-10-02 的 BOX 冒烟日志（`reports/20261002-followup-validation/boot/box-round-1.log`）里，
LiveKit 建房时内部堆空闲是 58,659 B，最大连续块 57,344 B，建房需要 19,712 B。
IRAM 代码和 DRAM 在 S3 上共用同一块 SRAM，所以常驻 IRAM 每多一字节，内部堆就少一字节，不管 BLE 有没有在用。

- 默认 NimBLE 版会让这个空闲降到大约 38 KB（推算，未上机）。
- 精简版把常驻静态开销压到 3.9 KB：控制器代码去了 flash，`libbtdm_app_flash.a` 的 IRAM 只剩 199 B。代价是镜像大约多 300 KB，OTA 分区仍有 429 KB 余量。

所以静态内存不是障碍，应该直接用精简配置。
还剩一项只能上机测：控制器和 NimBLE 初始化时从内部堆的动态分配，以及 BLE 运行期间的峰值。
精简版已把 NimBLE 的堆放到 PSRAM，但控制器自己的分配仍在内部 RAM。

## 2. 直接打开开关会出的问题（固件）

### 2.1 Eidolon 自己的载荷超过 BLE 单次上限（需要改契约）

protocomm 的 BLE 传输一次请求就是一次特征值写，一次响应就是一次特征值读：

- Bluedroid 上限 481 B（`protocomm_ble.c:27`，Security 2 时的 `CHAR_VAL_LEN_MAX`）；
- NimBLE 上限 512 B（`ble_att_svr.c` 的 `BLE_ATT_ATTR_MAX_LEN`）。

Eidolon 的端点载荷（按 SDK golden 估算，未加 Security 2 的 16 B 认证标签）：

| 端点 | 方向 | 大小 |
|---|---|---|
| `eidolon-descriptor` | 设备 → 手机 | 约 900 B（`golden/setup-descriptor.json` 的 bounded_window） |
| `eidolon-trust`，prepare_only | 手机 → 设备 | 约 1.0 KB，外加 Owner 根证书和授权签名证书两张 PEM |
| `eidolon-trust`，正式提交 | 手机 → 设备 | 约 3.9 KB（含 2.7 KB voucher），外加两张 PEM |
| `eidolon-status` | 设备 → 手机 | 最坏约 436 B（按 `device_provisioning_protocol.cc` 的字段推算），加标签后约 452 B，在上限内但很紧 |
| 设备端上限 | — | `kMaxTrustHandoverPayloadBytes = 16 KiB`（`device_provisioning_protocol.h:70`） |

所以 Kconfig 说明里“载荷完全相同”在 BLE 上不成立：descriptor 和 trust 都会被 ATT 层拒绝。
SDK 自带的 `prov-scan` 本来就分页，不受影响。

修法：在契约里给 BLE 定义分片帧，SoftAP 不变。可以是新增端点（例如 `eidolon-trust-part` 携带 offset/total，
设备端在会话内重组，满了才交给现有处理），也可以是现有端点内的帧头。这是 device_foundation v1 的增量修改，
要同时改契约文档、conformance、ESP32 和手机端。Reachy Mini 的 Python 实现只走 SoftAP，可以不跟。

### 2.2 `FREE_BTDM` 让同一次开机里的第二个 BLE 窗口起不来

`device_provisioning.cc:575` 用的是 `NETWORK_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM`。
配网管理器 deinit 时它会调 `esp_bt_mem_release(ESP_BT_MODE_BTDM)`（`network_provisioning/src/scheme_ble.c:272`）。
这一步不可逆，重启前蓝牙控制器再也初始化不了。

可 Eidolon 不重启也能再开窗口：

- 已归属设备长按 BOOT 换网络；
- 输错密码回滚后再长按 BOOT。

只有身份被替换时才重启（`commissioning_runtime.cc:541`）。所以照现在的写法，第一个 BLE 窗口之后的窗口都会在 `network_prov_mgr_init` 失败。

两种修法：

- **A. 不释放：** 改用 `NETWORK_PROV_EVENT_HANDLER_NONE`，或开 `NETWORK_PROV_KEEP_BLE_ON_AFTER_PROV`。
  控制器的静态数据和堆就常驻了，要和第 1 节的余量一起上机测。
- **B. 释放，再开窗口时走重启：** 物理在场的授权写进日志，`esp_restart()`，开机后再开 BLE 窗口。
  这正是 `device_boot_recovery.cc` 已有的模式。但它跨越了 D8“只有物理在场才能开窗”的边界，日志必须保证
  “有人按过”这个事实不会被伪造或重放。

精简配置下静态开销只有 3.9 KB，A 的成本主要是控制器 deinit 之后还留着的那部分，要上机测。
建议先按 A 上机，测运行时内部堆。不够再做 B。

如果已归属设备在线时换网络改为由 Host 通过运营网络下发（第 7.3 节第 3 条），
BLE 窗口就只剩首次配网和离网换网两种情况。这时 B 的代价变小，也和 esp-matter 默认释放 BLE 内存的做法一致。

### 2.3 BLE 上终态 ACK 之后要白等 30 秒

SoftAP 下，ACK 响应发出后在 httpd 任务里回调 `terminal_ack_response_finished`，马上拆除连接（`device_provisioning.cc:262-280`）。
BLE 分支没有这个信号（注释写着依赖期限兜底）。于是要等提交后 30 秒的 `terminal_deadline_us`，
由 `TerminalDeliveryExpired` 收尾（`commissioning_runtime.cc:635`、`commissioning_orchestrator_core.cc:229`）。
结果是设备晚最多 30 秒才回到 Station、向主机登记，手机端看到的“正在接入”也就长了 30 秒。

修法：ACK 被接受之后，把 `PROTOCOMM_TRANSPORT_BLE_DISCONNECTED` 当作“响应已送达”（手机读完 ACK 响应就主动断开），期限只做兜底。

### 2.4 BLE 设备名上限 29 字节

`ServiceName()` 拼出 `eidolon-<型号≤18>-<MAC 后 6 位>`，最长 33 字节。
protocomm 的 BLE 设备名上限是 29（`MAX_BLE_DEVNAME_LEN`），会用 `strlcpy` 直接截断：

- `eidolon-m5stack-stackchan-xxxxxx`（32 字节）和 `eidolon-touch-amoled-2.06-xxxxxx`（32 字节）会丢掉 MAC 末 3 位；
- `m5stack-core-s3`（30 字节）丢 1 位；
- BOX-3（24）和 korvo-1（22）不受影响。

名字只是提示（身份以 descriptor 为准），但同型号多台并排时，列表会出现重名。修法：BLE 下用短型号代码。

### 2.5 其他需要注意的

- **服务 UUID：** protocomm 默认用乐鑫的通用服务 UUID，附近任何乐鑫配网设备都会被扫到。
  应该用 `network_prov_scheme_ble_set_service_uuid` 设一个 Eidolon 专用 UUID，手机按它过滤。
- **共存：** 配网期间设备一边 BLE 连着手机，一边用 STA 连家网，还要用 HTTPS 取并验证 Owner 描述符。
  构建里软件共存已经自动打开（`ESP_COEX_SW_COEXIST_ENABLE=y`），时序和速度要上机验证。
- **净效果：** SoftAP 的问题会一起消失，包括 APSTA 同信道约束、httpd 3 个 socket 的调优、TCP_NODELAY，
  以及第二次访问时的 `COMMISSIONING_TERMINAL_TIMEOUT` 调查方向。

## 3. 输错密码之后能不能在同一窗口重试

现状：Wi-Fi 被拒，设备就回滚，发布 `rolled-back / NETWORK_REJECTED`，等 ACK，然后关闭传输。
屏幕显示 “Setup failed: Wi-Fi rejected. Previous setup retained”
（`commissioning_orchestrator_core.cc:207-228`、`commissioning_runtime.cc:612-617`）。再试需要长按 BOOT 重新开窗口。

- **同一窗口重试：** 不建议。
  - 契约的 state vector 规定回滚之后必须停止传输（`state-vectors/commissioning-runtime.json` 的 failure_sequences）。
  - 候选密钥按窗口 generation 生成（`esp_idf_commissioning_credential_store.cc:376`），voucher 绑定这把密钥，所以重试本来就要新 voucher。
  - 改动面大，换来的只是省一次重连。
- **未归属设备回滚后自动开新窗口：** 建议，并且在现有规则之内。
  - 未归属设备本来就允许无人时自动开窗口（`wifi_board.cc` 的 `OpenSetupWithoutAnyonePresent`）；
  - D8 只约束已归属设备。
  
  有了 BLE，手机这边是：重连蓝牙 → prepare → 在家网上取 voucher → 重输密码，几秒钟的事，不用再碰设备。
  已归属设备换网络失败，仍然要长按 BOOT，这是 D8 的本意，不应放宽。前提是 2.2 先修好。

## 4. 手机端

### 4.1 BLE 传输

`ProvisioningSession` 把 SRP 和 AEAD 交给乐鑫的 `Session(transport, Security2)`，传输层只要实现
`com.espressif.provisioning.transport.Transport.sendConfigData(path, data, listener)`。
SoftAP 时这一层是我们自写的 `ProvisioningHttpTransport`。

BLE 版也建议自写 `ProvisioningBleTransport`，不用乐鑫库自带的 `BLETransport`。
原因是后者把连接状态发到 greenrobot 的全局 EventBus（`DeviceConnectionEvent`），
而 SoftAP 这条路当初正是为了不和后续访问共享这条全局总线，才把它换掉的（`DeviceProvisioningManager.kt` 的类注释）。

自写的部分：

- 连接后发现服务，读每个特征的 0x2901 用户描述符，得到“端点名 → 特征 UUID”的映射（protocomm 的约定）；
- 请求 MTU 512；
- 写请求、读响应，一次访问一条链路；
- 断开时让会话失效。

GATT 的重试（133）、MTU、写闩这些模式，可以照 Host 用的 `BleCommissioningManager.kt` 写，估计 250–350 行，再加单测。

### 4.2 发现与候选

- 按 Eidolon 服务 UUID 做 BLE 扫描，候选的 `transportKind` 记为 `ble`，`transportId` 记为蓝牙地址。
- `DeviceProvisioningCandidate` 已经有 `transportKind`，可以直接扩展。
- `BLUETOOTH_SCAN` 和 `BLUETOOTH_CONNECT` 权限已经为 Host 配网申请过。
- SoftAP 专有的部分 BLE 都不需要：`WifiNetworkSpecifier`、local-only `Network`、定位服务检查、扫描缓存陈旧判断。
- SoftAP 路径保留给负担不起 BLE 的板子。

### 4.3 流程

- **第一步，不改页面和 coordinator 的结构：** 两次访问照旧，每次访问是一次 BLE 连接加 SRP 握手（预计 1–3 秒，需实测）。
  设备断开后会自动重新广播（`protocomm_nimble.c:256-266`），第二次访问能连上。
  手机始终在家网，所以 `_issueVoucherOrWait` 一次就成功，`awaitingHost` 实际上走不到，可以保留作兜底。
- **第二步（可选）：** 链路一直保持到取完 voucher、输完密码，合成一次访问。
  这要改 `device_setup_page.dart` 和 `device_setup_coordinator.dart` 对会话的所有权，以及 checkpoint 的恢复语义，收益只是省一次重连。

### 4.4 iOS

Flutter 这边目前只放行 Android（`platform_device_provisioning.dart:43`）。BLE 是 iOS 上最顺的路：
CoreBluetooth 加乐鑫 iOS 库的 Security 2；SoftAP 在 iOS 上还要走 `NEHotspotConfiguration`，同样有系统弹窗。

## 5. 最小改动清单

**SDK 契约（eidolon_sdk device_foundation v1）**
1. BLE 分片帧：用于 descriptor 响应和 trust 请求。status 响应目前约 452 B，建议也走同一分片，免得以后加字段时越界。
2. 修正“两种传输载荷相同”的说法，补 BLE 的终态送达语义（断开即送达）和 conformance 用例。

**固件（eidolon-client-esp32）**
1. 分片帧的设备端：重组缓冲按 16 KiB 上限、绑定会话，断开就丢弃。
2. 2.2 的内存策略（先 A）。
3. 2.3 的断开即送达。
4. BLE 设备名改用短型号。
5. 设 Eidolon 专用服务 UUID。
6. 板脚本：按板子打开 `EIDOLON_PROVISIONING_TRANSPORT_BLE` 和 NimBLE，选定精简选项。BOX-3 先行。
7. （可选）未归属设备在 `NETWORK_REJECTED` 回滚后自动开新窗口。

**手机（eidolon_client_mobile）**
1. `ProvisioningBleTransport`、BLE 发现，以及 `DeviceProvisioningManager` 按 `transportKind` 分支。
2. 分片帧的手机端。
3. 页面文案：BLE 候选不再出现“系统要求连接设备热点”的提示。

## 6. 需要上机验证的

- BOX-3 运行时内部堆，三个时点：开窗口前、BLE 已连接时、窗口关闭后的语音建房。重点是方案 A 常驻之后，建房时还剩多少。
- 配网期间 BLE 与 STA 连接、HTTPS Owner 验证的共存，两次访问之间的重连耗时。
- 分片后的 trust 下发和 ACK 时序，以及“断开即送达”。
- 同一次开机里第二个 BLE 窗口（长按 BOOT）能正常打开。
- korvo-1、stackchan 等其他板的内存余量。本次只测了 BOX-3。

## 7. 和标准方案的对照

给设备配网这件事，真正有标准组织背书的只有两个：

- **Matter commissioning**：CSA 发布，Apple、Google、Amazon、Samsung 都实现了，是智能家居的事实标准。
- **Wi-Fi Easy Connect（DPP）**：Wi-Fi 联盟，只管把 Wi-Fi 凭据交给设备。

乐鑫统一配网、Improv、涂鸦是厂商或社区方案，Reachy Mini 是自研。

这些方案标准与否，结构都在往同一套上收敛，Matter 写得最完整：

1. 每台设备有独立的配对秘密，印成二维码。
2. 用这个秘密做 PAKE，双向认证，攻击者无法离线爆破。
3. 开一个失败就整体回滚的事务。
4. 设备生成自己的密钥，由归属方签发运营身份。
5. 在加密会话里下发 Wi-Fi。
6. 设备上了真实网络之后，再用运营身份确认完成。

所以拿来做尺子的是 Matter 的结构，不是 Matter 协议本身。用它量，Eidolon 在结构上已经接近 Matter，
偏离只有两处：SoftAP 传输，以及全局固定的配对口令。Reachy 只有传输选对了。

### 7.1 逐步对照

| Matter 的做法 | Eidolon ESP32 现状 | Reachy Mini |
|---|---|---|
| **传输**：Wi-Fi 设备走 BLE。Soft-AP 写进了规范，但 Google 说 SDK 1.0 没实现，没有设备在用 | SoftAP（偏离） | BLE |
| **PASE**：SPAKE2+，27 bit 设置码（二维码或 11 位手动码），设备只存 verifier | SRP6a，设备只存 salt 和 verifier；但口令是全局固定的 `eidolon-dev-setup`（偏离） | ECDH + PIN 当 HKDF 盐，不是 PAKE；`PIN_` 明文发出 |
| **Fail-safe**：没有 CommissioningComplete 就整体回滚 | 暂存 → 提交 → 回滚事务，比 Matter 更细 | 没有，nmcli 失败只是回退热点 |
| **设备证明**：DAC → PAI → PAA 证书链 | 有 manufacturer-bound 的规格，没实现 | 没有 |
| **运营身份**：设备出 CSR，管理域签发 NOC | 设备生成候选密钥，Host 签 voucher 绑定 SPKI，再登记、下发 ClaimGrant | 走 Hugging Face 账号授权 |
| **下发 Wi-Fi**：在 PASE 会话里 ScanNetworks / AddOrUpdateWiFiNetwork / ConnectNetwork | `prov-scan` / `prov-config` 在 SRP 会话里 | `WIFI_SCAN` / `WIFI_CONNECT_ENC` |
| **完成**：上了运营网络后，DNS-SD 发现 + CASE + CommissioningComplete | 设备在新网络上验证签名的 Owner 描述符后才提交，再登记到 Host（等价） | 云端列表里出现同一个 hardware_id |
| **BLE 上的大消息**：用 BTP 分片 | 没有，即第 2.1 节的问题 | 载荷小，不需要 |
| **首次之后**：第一个 fabric 建好后必须停止 BLE 广播，之后开窗口都走 IP | 已归属设备长按 BOOT 仍能开窗口换网 | — |

最后两行和本文的两个问题直接相关：

- **2.1 的分片是 BLE 传输的固有成本，不是我们设计错了。** Matter 专门定义了 BTP，因为证书类消息必然超过 ATT 的单次上限。
- **2.2 里"BLE 用完就释放内存"本身就是标准做法。** esp-matter 默认在配网后释放 BLE 内存，想保留可以关掉 `CONFIG_USE_BLE_ONLY_FOR_COMMISSIONING`。
  Eidolon 撞上这个问题，是因为"已归属设备离网后，靠物理在场换 Wi-Fi、身份不变"这个需求超出了 Matter 的模型。
  在 Matter 里，已配网设备不能再用 BLE 广播，离网后通常只能恢复出厂重新配网。
  最后这一点规范里没找到明文，是从"首个 fabric 后必须停 BLE 广播"推出来的。

### 7.2 其他方案各自的定位

- **Wi-Fi Easy Connect（DPP）**：设备二维码里放的是公钥，Android 10+ 的系统设置充当配置器。
  手机不离开自己的网络，也不需要定位权限，ESP-IDF 也支持设备端（enrollee）。
  但 Android 上要跳到系统设置页；iOS 不支持；而且只能传 Wi-Fi 凭据，带不了 Owner 信任。不适合做主路径。
- **Apple**：TN3111 写得很直白。最好的办法是 WAC 或 HomeKit，但都要加入 MFi；
  否则用 `NEHotspotConfiguration` 自己做，"不如 WAC 和 HomeKit 顺滑"；有 Wi-Fi 配件的，用 AccessorySetupKit 简化发现。
  也就是说，第三方 SoftAP 在 Apple 那里就是官方认定的次优路径。
- **Android**：CompanionDeviceManager 弹系统选择器，替 App 扫描 BLE 或 Wi-Fi 设备，不需要精确定位权限，但定位服务要开着。
- **乐鑫统一配网**：BLE 和 SoftAP 二选一。二维码格式是 `{"ver","name","pop","transport","security"}`，缺省就是 Security 2；
  `pop` 是每台设备一把的"钥匙"。乐鑫自己的 SoftAP 配网 App 在 iOS 上不支持搜索设备热点。
- **Improv**（ESPHome / Home Assistant）：走 BLE，密码按原始字节发送，规范里没有任何加密。
  安全只靠可选的"在设备上按键授权"，授权 1 分钟后失效。最简单，也最弱。
- **涂鸦**：AP、蓝牙、EZ 三种。TuyaOS v3.4.0 起不再支持 EZ（类似 SmartConfig 的广播式配网）。

### 7.3 该借什么，不该借什么

**不建议整体换成 Matter：**

- Matter 的价值是跨生态互通，让苹果、谷歌、亚马逊的控制器能接管设备。Eidolon 的设备是语音陪伴体，归属在自己的 Owner Domain，Matter 没有对应的设备类型。
- 设备证明（DAC）需要 CSA 会员资格和 PAA 证书链，还有认证成本。
- esp-matter 协议栈要和 LiveKit、AFE 抢 BOX-3 的内部 RAM，而语音时实测只剩约 58 KB（第 1 节）。
- Eidolon 的事务、终态证据和 ACK 比 Matter 的 fail-safe 更细，没有理由换掉。

**值得借的三件事，按价值排：**

1. **每台设备独立的配对秘密，印成二维码。** 这比换传输更要紧。
   SRP6a 和 SPAKE2+ 同属增强型 PAKE，缺的只是把全局口令换成每台设备自己的口令和 verifier。
   现在的口令是公开的，PAKE 实际上等于没开。格式可以直接用乐鑫二维码里的 `pop` 字段。
   Host 的 8 位 setup code 目前是 TLS 里的哈希比对，不是 PAKE，
   跨仓库文档 `eidolon/docs/跨系统/手机认领流程梳理与同类产品对照.md` 已把它记为未决项，可以一起改。

   **决定（2026-11-04）：** 带屏设备进入配网模式时，把二维码直接显示在屏幕上；无屏设备提供可打印的二维码。
   目前所有设备都带屏。屏幕上的码可以每个窗口重新生成，看得到屏幕本身就证明人在设备旁边，
   比出厂印一个固定秘密更强，也不需要产线写入。
2. **传输换成 BLE。** 也就是本文第 1–6 节评估的那件事。
3. **已归属设备的后续操作尽量走 IP。** 设备还在线时，换网络从 Host 通过运营网络下发，不开 BLE 窗口。
   只有离网的情况才需要长按 BOOT 开 BLE 窗口。这样第 2.2 节可以选方案 B（重启进 BLE 窗口），
   配网完成后照常释放 BLE 内存，和 esp-matter 的默认做法一致。

### 7.4 来源

- Google Home Developers：[Matter commissioning primer](https://developers.home.google.com/matter/primer/commissioning)、[Commissionable and operational discovery](https://developers.home.google.com/matter/primer/commissionable-and-operational-discovery)
- Silicon Labs：[Matter commissioning](https://docs.silabs.com/matter/2.7.0/matter-overview-guides/matter-commissioning)
- CSA：[Matter 1.0 Core Specification（PDF）](https://csa-iot.org/wp-content/uploads/2022/11/22-27349-001_Matter-1.0-Core-Specification.pdf)
- connectedhomeip：[issue #35506（SupportsConcurrentConnection）](https://github.com/project-chip/connectedhomeip/issues/35506)、[BtpEngine.cpp](https://pigweed.googlesource.com/third_party/github/project-chip/connectedhomeip/+/12fe9df8d26485d1ba119b3a6925fc8ac75a4824/src/ble/BtpEngine.cpp)
- rs-matter-stack：[非并发配网说明](https://docs.rs/crate/rs-matter-stack/0.1.0/source/src/wireless.rs)
- matter_setup_code：[设置码格式](https://lib.rs/crates/matter_setup_code)
- Espressif：[esp-matter FAQ](https://docs.espressif.com/projects/esp-matter/en/latest/esp32/faq.html)、[ESP-IDF DPP](https://esp-idf.readthedocs.io/en/latest/api-reference/network/esp_dpp.html)、[esp-idf-provisioning-android（二维码格式）](https://github.com/espressif/esp-idf-provisioning-android)、[RainMaker firmware dev tips](https://docs.rainmaker.espressif.com/docs/dev/firmware/firmware_dev_tips)
- Android：[Wi-Fi Easy Connect](https://source.android.com/docs/core/connect/wifi-easy-connect)、[Companion device pairing](https://developer.android.com/guide/topics/connectivity/companion-device-pairing)
- Apple：[TN3111 iOS Wi-Fi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)、[AccessorySetupKit ASAccessory](https://developer.apple.com/documentation/accessorysetupkit/asaccessory.md)
- Improv：[BLE 规范](https://www.improv-wifi.com/ble/)、[ESPHome Improv via BLE](https://esphome.io/components/esp32_improv/)
- 涂鸦：[Pairing mode](https://developer.tuya.com/en/docs/iot-device-dev/TuyaOS-iot_abi_network_config_mode?id=Kc67tro6mzaz0)

## 8. 实施状态（2026-11-05）

第 7.3 节的第 1 条（屏幕上的设置码）已经落地，主机设置码也改成了 PAKE，两者都上过台架。
第 2 条（BLE）暂缓，第 3 条（已归属设备在线换网）不做，都在 8.4（2026-11-05 决定）。
输错 Wi-Fi 密码的处理也补齐了（8.2）。

### 8.1 已落地

| 仓库 | 提交 | 内容 |
|---|---|---|
| eidolon_sdk | `669938f` | 设置码二维码载荷、BLE 传输、分帧的契约和 golden |
| eidolon-client-esp32 | `6b6560e8` | 设置码、二维码载荷、分帧的纯逻辑核心，按 SDK golden 逐字节回放 |
| | `55479141` | 每个窗口生成新码；SRP verifier 在设备上派生；屏幕叠加层显示二维码和数字 |
| | `592325f5` | 所有维护中的板子默认开启设置码；korvo-1（mbedtls 4）的 SHA-512 改走 PSA |
| | `f71ffd2b` | Wi-Fi 断开 4 次就判定被拒并撤回（之前对部分断开原因无限重试）；BOX-3 现在跑这一版 |
| | `c76b7d7c` | 删掉没接线的分帧核心（BLE 暂缓） |
| | `d5c735fe` | 设备显示 connecting 时长按 BOOT 也能开窗；不能开窗的状态在屏幕上说明原因（另一个会话做的，还没上台架） |
| eidolon_client_mobile | `704c1b8` | Wi-Fi 列表点一行原地展开（三个页面） |
| | `641d2f5` | 扫码或输入 8 位数字；码只在内存里，跟着设备走两次访问 |
| | `3ad19db`、`4345221` | 主机设置码用 SRP-6a 证明，不再发送；旧主机明确报错，不降级 |
| | `54546e4` → `f20a523` | 加过设备声明 `frame-v1` 时的分帧，BLE 暂缓后删除 |
| | `e18d643` | 码被拒后回到扫码那一步 |
| | `e8edd34` | 移除后重新加入时说清楚为什么是新设备；无码入口只指无屏设备 |
| | `d03753d` | 设备撤回（Wi-Fi 被拒、连不上主机等）后回到扫码那一步，说清楚下一步 |
| | `aba393b` | 提交 Wi-Fi 后等设备结果 60 s（原来 30 s，比设备放弃得早） |
| eidolon_admin | `9777001`、`b5ca266`、`875dc4f` | 主机只接受 PAKE；猜码令牌桶只拖慢、永不关窗（ADR-0008） |
| docs | `852aa2e`、`dd3c890` | 认领流程与状态机 |

开发口令 `eidolon-dev-setup` 只剩两处用途：Reachy Mini 这类无屏设备走的「查找设备」入口，
以及固件每次开机对 SRP 派生做已知答案自检时用的向量。

### 8.2 台架

BOX-3 + HyperOS 平板 + Mac Host：

| 场景 | 结果 |
|---|---|
| 长按 BOOT 开窗 | 约 1.2 s 进入广播；屏幕显示二维码和 8 位数字 |
| 输错码 | 设备在握手第二步拒绝，窗口保持；手机回到扫码那一步（`e18d643` 复测） |
| 扫码换网（已归属） | 提交到设备确认约 8 s；终态 ACK 到拿到 IP 约 5 s，到主机确认约 10 s，到语音通道约 14 s。身份、认领、伙伴不变 |
| 移除后重新加入 | Hub 依次 revoke、commissioning-standings、enrollment、grant collect/ack。设备换了新身份，这是设备生命周期 §19.3.8 的要求；旧记录离开设备列表，`erase-operations:pull` 一直是 204 |
| 输错 Wi-Fi 密码（修复前） | 路由器回 AUTH_EXPIRE/CONNECTION_FAIL，配网库对这两种原因无限重试；设备停在 validating 9.5 分钟，直到碰巧收到 HANDSHAKE_TIMEOUT 才撤回。手机 30 s 就走了，只能说结果未确认 |
| 输错 Wi-Fi 密码（`f71ffd2b` + `aba393b`） | 提交后 37 s 设备放弃并撤回，手机收到并回到扫码那一步，提示「设备没有接受这个网络……再扫描屏幕上的新二维码」；设备 5 s 后回到原网络，主机仍是 approved，身份不变 |
| 正确密码（同一版） | 5 s 连上新网络，7.4 s 提交，18 s 主机确认 approved；重试上限不影响正常配网 |
| 设置码外泄 | 平板 logcat 里没有出现 |
| 内存 | 窗口打开那几秒，内部 SRAM 低水位约 11 KB（SoftAP，语音已关）。这次没有出问题，但做 BLE 之前要先查清是哪一步吃掉的 |

各板默认开启设置码后的编译结果（只验证到编译；叠加层在四种屏幕尺寸上有主机端截图测试，
除 BOX-3 外都没上真机）：

| 板子 | 结果 | 应用 / 最小应用分区 | 余量 |
|---|---|---|---|
| esp-box-3 | 通过，已刷机上台架 | 3.39 / 4.06 MiB | 17% |
| korvo-1（IDF 6.1） | 通过（SHA-512 改走 PSA 之后） | 3.28 / 4.31 MiB | 24% |
| xiaoling | 通过 | 3.02 / 4.31 MiB | 30% |
| m5stack-core-s3 | 通过 | 3.01 / 4.31 MiB | 30% |
| m5stack-stackchan | 通过 | 3.00 / 4.31 MiB | 30% |
| esp32-s3-touch-amoled-2.06 | 通过 | 3.03 / 4.31 MiB | 30% |
| atk-dnesp32s3 | 不通过，原因与设置码无关（见 8.4） | — | — |

korvo-1 的 SHA-512 修正只验证到编译。设备每次开机都会先做已知答案自检，自检不过就拒绝开窗、屏幕提示无法开始设置，
不会出现码对不上的情况。这块板子上台架时先看这一条。

### 8.3 用设置码在真机上认领主机（B4，2026-11-05 已测）

**结果：** OnePlus PHK110 卸载重装 App 后（之前管理过这台 Mac，重装后没有任何凭据），通过局域网用 Setup 码认领成功。
`pake/start` 和 `pake/claim` 都返回 200。从 start 应答到 claim 完成 238 ms，整次 PAKE 约 0.36 s（一次采样）。
手机显示「主机接入已完成……其他管理手机不受影响」。认领后，开发配置的常开窗口立即换成了新的。

**发现一个死胡同：手机拿着过期的窗口 ID 去认领。**
- 经过：手机在查找主机时读一次 endpoint 文档，之后「添加」时不再重读。如果在这之后主机生成了新码（新窗口顶替旧窗口），
  `pake/start` 会回 401 `commissioning_denied`，手机却显示「Setup 码错误或已失效，请核对后再试」。
- 后果：核对后输入正确的码也一样失败，只有退回去重新查找主机才行。先在手机上开始添加、再去主机拿码，正是给已认领主机加手机时最自然的顺序。
- **已修复**：手机 `eeab399` 在认领前重新读取 endpoint，只在主机身份不变时采用新窗口；
  start 就被拒时提示「主机现在没有开放的 Setup 窗口」，不再说码错。
  真机复测（同一顺序：手机先查找，再在主机上生成新码）一次成功：重读 endpoint → `pake/start` 200 → `pake/claim` 200。
- **开发阶段的 Setup 码统一是 99999990**：Mac 的出厂码文件里就是这个码，常开窗口也一直用它。
  `./eidolon mac commissioning-code` 原来没把它传给主机，主机就随机生成了一个；ops `4c5d0a2` 修复后，不带 `--code` 也会用 99999990。
- 只在主机上验证、没在真机上测的：输错码不关窗、局域网连续猜码返回 429。这两项由 admin 的测试覆盖。

以下是原来的测试步骤：

PAKE 有 RFC 5054 向量、跨语言 golden 和变异测试。部署后在 Mac Host 上验证过
`pake/start` 的回答和旧接口 404，但还没有一部真手机用设置码完成认领。已经管理这台主机的手机
会直接用管理密钥认证，走不到 PAKE，所以需要一部没有这台主机凭据的手机：

1. 在 Mac 上执行 `./eidolon mac commissioning-code`，记下 8 位码。这会开一个认领窗口，
   已认领的主机也可以再加一部手机（peer controller）。
2. 用一部没管理过这台主机的手机（或者清除 App 数据后的 OnePlus），从「设置另一台主机」输入这个码。
3. 期望：认领成功，耗时 p95 < 1 s；输错码时提示码不对，窗口不关；局域网上连续输错后提示稍后再试（429）。

### 8.4 暂缓与后续

- **BLE（P5 的固件部分、P6、P7、P9）：暂缓（2026-11-05 决定）。**
  硬件不是问题：维护中的板子都有 BLE 射频，平板和手机也都支持。暂缓是因为现在做的收益小、风险大：
  - SoftAP 流程在台架上稳定：今天三次完整配网，平板每次从扫码到加入设备热点约 2.5 s，
    没有停在系统确认上，之后都自己回到了家网。BLE 要消掉的离网和回网失败，这次一次都没出现。
  - 风险在内存：配网窗口里内部 SRAM 只剩约 11 KB，BLE 常驻至少还要 3.9 KB（精简配置），
    默认配置要 20.7 KB（第 1 节）。
  - 两端都要新写一个传输，对「稳定」是净风险。
  - 还没有 iOS 客户端，iOS 这条收益暂时用不上。

  满足下面任一条件就重新启动：开始做 iOS 客户端；某款 Android 手机上出现回网失败或系统确认，
  而且无法绕过；SoftAP 在某块板子上不可用。
- **分帧代码已删除**（手机 `f20a523`、固件 `c76b7d7c`）：没有设备声明 `frame-v1`，删前走不到。
  重启 BLE 时从 `54546e4`、`6b6560e8` 恢复；SDK 里的契约和 golden 留作设计依据。
- **已归属设备在线换网（轨道 C）：不做（2026-11-05 决定）。** 要换 Wi-Fi 的常见原因——换路由器、
  改密码、搬家——发生时设备本来就离线，在线换网用不上；只剩「旧网络还在、主动换到另一个」这种少见情况，
  而长按 BOOT 扫码换网约 30 s 就能完成，身份和伙伴不变。代价却要动 SDK、Hub、主机、固件、手机五处，
  再加一个远程改设备 Wi-Fi 的攻击面。设备装在够不着的地方、长按 BOOT 不现实时再考虑。
- **P8 的固件部分：不做（2026-11-05 决定）。** 输错密码只要在设备上重新开窗、扫新码，提示已经说清楚。
  - 未归属设备撤回后不自动重开窗口，需要长按 BOOT。
  - 不做错码限次。已知风险：配网窗口没有时限，有人在 Wi-Fi 范围内守着，每秒约能试 3 个码，
    一天猜中的概率约 0.26%。已归属设备的窗口只有主人亲手长按才会打开。
- **主机 `hub-discovery` 会停止回应组播查询**（2026-11-05 台架上遇到一次）：对它的局域网地址发单播查询
  仍然能答，但设备的组播查询没有回应，设备找不到主机，一直显示重连。
  `./eidolon mac service restart hub-discovery` 后立刻恢复。
  - **不是发布引起的**：15:05 之后没有发布，也没有服务重启，旧进程一直在运行。
  - **线索**：Mac 走 Wi-Fi，当前 DHCP 租约开始于 15:16:07（租期 8 小时，不是常规续租），说明 Wi-Fi 那时重连过、地址没变。
    discovery 每 10 秒比对一次接口名、索引、地址和前缀，重连后四项相同，所以不会重建；重启则会重建套接字和组播成员资格。
  - **没有复现**：重启后观察约 40 分钟，设备 3 次、Mac 本机组播探测 9 次都正常，所以没有改代码。
  - **再出现时**：先从 Mac 往 `224.0.0.251:5353` 发一次旧式单播查询（端口不是 5353）。
    - 没有回答：问题在本机套接字，修法是在 discovery 里加组播自检，失败就重建。
    - 有回答、只有设备收不到：问题在网络这一侧。
- **结果未确认留下的记录**：手机等设备结果超时后，这次接入会留在「未完成的设备接入」里，点「继续接入」向主机确认并收尾。
- **atk-dnesp32s3 本来就编不过**：它的分区表没有 64 KiB 的 owner_trust NVS，
  与设置码无关，需要单独修板子的分区配置。
