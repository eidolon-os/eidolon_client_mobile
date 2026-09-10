# RK3588 连接失败与 Pi5 设备设置 404：根因复查

后续收敛的职责划分、用户流程和实施边界见[架构简化方案](host-and-device-architecture-simplification-plan.md)。

诊断基线：`369aec7`。以下是修复前诊断记录；后续 Mobile 实施及验收状态见上述架构简化方案。诊断阶段读取了平板、Pi5、RK3588 的实际状态并做了可恢复的无线省电对照，未修改业务代码、清空检查点或重置设备。此前提交的有限重试是容错，不是无线故障的根治。

## 1. RK3588：无线链路反复丢失信标，造成 TCP 建连失败

### 已确认的事实

- 平板、Mac、Pi5 都出现无法访问 RK3588 `192.168.1.33` 的情况，影响 ping、SSH 和 Local API 9002；不是仅 Mobile App 的某个连接对象失效。
- 经 mDNS 获得 `fe80::ac30:69da:ad41:1180` 后，Mac 曾通过同一 Wi-Fi 网卡的 IPv6 链路地址登录成功；后续 IPv6 也间歇超时。因此不能把它定性为只影响 IPv4 的缺陷。
- 主机负载约 `0.43 / 0.39 / 0.38`，9002 监听为 `0.0.0.0:9002`，队列未积压。Wi-Fi 地址和默认路由正确；ARP ignore/filter 为 0，反向路径过滤为 loose。有线口 `enP3p49s0` 为 DOWN，当前没有独立的有线管理通道。
- RK3588 的 NetworkManager 记录连续的 `completed → disconnected → scanning → associating → 4way_handshake → completed`。例如 16:39:48、16:40:42、16:41:49、16:42:57、16:43:27、16:44:22、16:45:19、16:45:56 都发生断开；重连约需 7 秒，随后 DHCP 重新取得同一 IP。
- 厂商无线驱动日志在相应断链中报告 `WLC_E_LINK(16), reason 1`。已读取主机实际安装源码 `/usr/src/bcmdhd-sdio-101.10.591.52.27-6/src/include/bcmevent.h:762`：

  ```c
  #define WLC_E_LINK_BCN_LOSS 1 /* Link down because of beacon loss */
  ```

- 无线驱动为 `wl` / Broadcom DHD，内核 `6.1.115-vendor-rk35xx`。关联在 2.4 GHz 信道 11，观测信号约 -55 至 -58 dBm；NetworkManager 和 wpa_supplicant 各自只有一套运行进程，所查 Bootstrap 日志未显示主动换网操作。

### 因果链与确定性边界

驱动报告信标丢失 → 无线关联断开 → 扫描/重新握手 → DHCP 恢复 → 间歇可连接。这解释了 mDNS 能看到名字和 IP，但随后 TCP 超时，以及再次进入偶尔成功。mDNS 候选地址不是此刻单播链路可用的证明。

已经确认根因落在 RK3588 与接入点之间的无线链路/驱动层，而非主机显示名、Controller 身份串台或 Workspace 加载。**尚不能只凭这些日志断言具体是 DHD 固件缺陷、AP 兼容性、射频/天线还是省电交互。**要确定这一层的具体触发因素，需要独立有线/串口管理下的 AP、频段、驱动/固件对照，不能直接写一个关闭省电或自动重连脚本当最终修复。

### 省电对照及恢复

- 原状态 `Power save: on`，NetworkManager profile 使用 default。
- 16:50:06 通过 `iw` 临时设置为 off，脚本安装退出/中断恢复钩子，未修改持久配置。
- 16:50:18 仍发生断开，16:50:25 重连，16:50:46 再次断开。16:51:16 另一次读取已显示 on，说明重连会重新应用无线设置；16:51:37 实验退出时再次确认恢复 on。
- 该实验不能证明省电完全无关，但足以说明“执行一次关闭省电”没有消除故障。期间和后续的平板采样还出现 15% / 40% 丢包、数秒级延迟；因为设置在重连时重新应用，不能把这些采样当成严格恒定 off 条件下的结果。

### 正确修复方向

1. 接入独立有线/串口管理，持续记录无线驱动和关联事件；先保证诊断不依赖正在掉线的链路。
2. 对照同一主机连接另一个稳定 AP/频段，以及相同 AP 下的受支持驱动/固件；记录信标丢失次数、丢包率和持续 TCP 连接成功率。改变一个因素后复测，避免一次修改多个配置。
3. 将验证有效的配置/驱动版本归入 RK3588 的 Host foundation 部署，而不是由 Mobile 调整主机网络，或添加业务层补偿脚本。

## 2. Pi5 404：自动恢复跨越 Owner generation，并反复接管终态记录

现场截图：[设备设置错误](../screenshots/pi5-device-setup-generation-error.png)。该页面显示 `Enrollment recovery 返回 HTTP 404`，并非 Wi-Fi 扫描接口不存在。

### 主机与手机事实对照

| 项目 | 手机检查点 | Pi5 当前事实 |
| --- | --- | --- |
| Owner Domain | `owner-b0a862b0aab941d64554` | 相同 |
| Owner generation | **8** | **9** |
| Enrollment | `enrollment_o4P6W7qsNH0FJx1DsYjYBDUM` | 当前表中不存在 |
| 接入状态 | `networkConfigured / failed`，`enrollment_gone`、不可重试 | 当前已有另一条第 9 代有效设备 Claim |

当前 generation 同时通过 Pi5 Hub 的只读数据库 `hub_authority_state` 和运行接口 `/api/device-onboarding/v1/descriptor` 验证为 9；手机检查点从应用自己的 SharedPreferences 读取。

16:37:52 Pi5 Local API 日志：

```text
Admin Device admission query refused by hub authority (not_found): enrollment not found
GET /api/local/v1/device-enrollments/enrollment_o4P6W7qsNH0FJx1DsYjYBDUM → 404
```

其他 target、设备列表、Enrollment 列表接口均为 200。因此不是整套设备 API 未部署或 URL 路由缺失。Hub 对已经不属于当前权威状态的旧 Enrollment 返回 404，符合现有契约；不能把 404 改成成功。

### 客户端缺陷

1. `DeviceSetupPage._resumePersistedAdmission`（约 270–282 行）自动选择检查点时，只比较 `ownerDomainId`、`networkConfigured` 和 `!isReady`，**没有比较 `owner_domain_generation`**。于是第 8 代记录被交给第 9 代 Authority 恢复。
2. 同一筛选也没有排除 `rejected` 或不可重试的 terminal failure。404 被正确保存为 `enrollment_gone / retryable=false` 后，下次进入仍会再次选中它；更新其 `updatedAt` 还会让它继续排在前面。
3. “配置新设备网络”与“继续历史接入”共用页面，`initState` 自动执行恢复。用户想扫描新设备，却被历史任务接管，随后看到 Enrollment/Grant/HTTP 等实现词汇。现有“重新设置设备”按钮只提供逃离方法，没有解决自动恢复资格错误。
4. Coordinator 对新发起流程复用检查点时已有 Owner generation 校验，但恢复入口没有在调用 Authority 前复用同等的作用域约束。恢复后校验 Projection 不能防止这个已经发出的错误恢复请求。

### 可控复现

复用现有 Widget 测试依赖，运行两项临时诊断：

- 相同 Owner ID、检查点 generation=1、当前 target generation=2：页面仍发出 recover 并进入终态错误。
- 已保存不可重试的 `enrollment_gone`：离开再进入后 recover 次数由 1 增至 2。

两项诊断通过，确认上述是可重复的状态机缺陷。临时测试已移到本机临时目录，不把错误行为作为长期回归要求。

### 正确修复方向

- 在现有模型/Coordinator 中统一定义恢复资格：Owner ID + generation 匹配、阶段可恢复、非终态；页面筛选和显式恢复都使用这个规则。
- 旧 generation 的检查点只作为失效历史，不向当前 Authority 自动恢复；不批量清空其他 Owner 的数据，也不修改主机身份。
- 新设备入口保持可达；可恢复的进行中任务作为明确的“继续接入”选项，不无条件取最新一条接管页面。
- 收到终态后结束该任务的自动观察，下一次进入不再自动恢复；现有明确重新开始和有效任务的崩溃恢复能力继续保留。
- 用户提示描述“上次接入已失效/主机状态已更新”，技术详情单独展示。不能通过吞掉 404 或只改文案修复。

## 3. 独立的连接体验问题

`HostLocator.standard` 当前先执行 `AnnouncedAddressSource`，再执行 `RememberedAddressSource`；平台发现的默认窗口是 5 秒。因此即使用户已经选中已保存主机、地址没有改变，首页也会先显示“查找”，等待发现结果，再连接。UI 中的“选中身份”与“解析/验证地址”没有解释清楚。

这增加每次切换的等待和候选验证请求，**不是无线信标丢失的原因**。优化应在现有统一定位层为已知地址提供快速验证路径，失败或地址失效再复用发现；始终保留 TLS pin 与 Host ID 校验，不另建一套连接缓存。网络失效时继续正常定位，不能因为“上次在线”就显示已连接。

## 范围与交付

- 本轮确认了两个问题各自的实际失败机制，并指出无线层进一步定责所需的对照条件；不宣称已经确定或修复具体 AP/固件缺陷。
- 未重新打包 APK，未重置主机/设备、未删除手机历史任务、未持久改变 Wi-Fi 配置。
- 现场截图与本报告留在仓库；完整设备日志、诊断测试和对照输出留在临时目录，避免提交其他应用信息或证书材料。
