# 设备配网：离开设备热点后，等手机回到主机所在的网络

日期：2026-10-09。

## 场景

设备（korvo-1）此前认领在 opi5max（Owner Domain `owner-f774cf8e…` gen 3）。用户在
Mac host（`owner-0342958c…` gen 1）的 App 里点「添加设备或恢复网络」，想把它搬到 Mac。
这是跨 Owner 配网：第一次访问设备时 `prepare_only` 让设备准备候选身份并返回
`requires_voucher=true`，手机随后必须回到主机网络向主机取 voucher，再第二次访问设备提交。

## 现象与证据（平板 `24091RPADC`，Android 16，HyperOS）

- `22:27:55` 手机加入设备热点 `eidolon-f3dfd4`；`22:27:57–22:28:00` 设备侧
  `/eidolon-descriptor`、`/eidolon-trust`（prepare_only，124 ms）、`/prov-scan` 全部 200。
- `22:28:00.766` App 释放设备网络；Android 立即尝试回连家庭 Wi-Fi `rcgy5#305`：
  `CTRL-EVENT-ASSOC-REJECT … assoc_no_resp_received / auth_no_resp_received`，两个 BSSID
  轮流失败；`22:33:18` 与 `22:43:26` 两次
  `Network temporarily disabled due to consecutive failures`。此后手机一直没有 Wi-Fi。
- `22:28:00.929` 起 App 向主机取 voucher：`Failed to connect to /192.168.100.21:9002`，
  按 3 秒间隔重试 4 次后放弃（总耗时还包括每次请求的耗时），`_descriptor` 被丢弃；Mac host 的 `local-api.log` 里从头到尾没有
  `POST /commissioning-vouchers`。
- 主机侧全部正常（15/15、`app-ready`、Hub 8443 证书链与 mDNS 均验证通过）；固件侧设备在
  124 ms 内完成了准备，设置窗口保持打开。

**根因**：两次访问之间的「回到主机网络」是平台与路由器的一步，不是我们的；App 把它当成
短重试窗口内必然完成的事，于是把平台没回网报告成「主机没有签发凭据」，并丢掉设备刚准备好的身份，
用户只能再去碰设备——而设备那边什么都没错。

## 修复（`features/device_setup`）

- `DeviceSetupPage` 新增 `hostReturnBudget`（默认 90 s）与 `hostReturnInterval`（3 s），
  以及与 coordinator 同形的 `clock` 注入。
- 第一次访问结束后，先把 `_candidate / _descriptor / _networks` 落到页面状态，再向主机取
  voucher。取 voucher 的失败按来源分级：
  - 「没到主机」——pinned 传输的 `unreachable / timeout / io / cancelled`、
    `TimeoutException / SocketException / ClientException`，以及重定位结束后的
    `HostLocationException` **且其中每个地址的失败都属于上述沉默类**（按重定位自己的规则，
    本网段新发现的地址优先于只是记得的旧地址）——在预算内每隔一个间隔重试，进度文案说明
    在等手机回到主机所在的网络和已等秒数；
  - `HostControllerAuthorizationException` 按它包着的原因判断：会话层（`_reauthenticate`）
    现在把底层失败放进 `cause`；401 之后重新认证时网络消失（`cause` 是沉默类传输失败、且
    不要求重新认领）同样等待；没有 `cause`、要求重新认领、或 `cause` 是身份不符/格式不兼容，
    立即报告。
  - 其余一律立即报告、不等待：主机答复的拒绝（`LocalApiRequestException`）、某个地址以另一台
    主机的身份应答（`secureChannel` / `SetupTrustException`）、响应格式不兼容。
- 预算用尽进入新步骤 `awaitingHost`：说明设备已准备好、设置模式仍开着、不用再碰设备；
  指引到系统 Wi-Fi 设置连回主机网络；「已连回网络，继续」只重做取 voucher，不再访问设备；
  App 回到前台时自动重试一次；「重新选择设备」回到搜索。
- 等主机期间不再显示「如系统要求连接设备…」的热点提示（那是在等设备时才对的话）。
- `DeviceSetupCoordinator` 的 `admission_unavailable` 文案改用 `failureSentence`，第二次访问
  之后主机暂时不可达时，页面显示的是一句话而不是异常原文。

没有改动主机、Hub 或固件；跨 Owner 的 voucher 路径、设备侧幂等准备与清理均按原协议进行。

## 验证

- `device_setup_page_two_visits_test.dart` 新增 10 项：主机晚回来时等待而不报错且不重访设备；
  超出预算保留已准备设备并可仅重取 voucher；回前台自动重试；主机拒绝立即报告；重定位只遇到
  沉默时等待；某地址以另一台主机身份应答时立即报告；重新认证时断网则等待、三种授权拒绝
  （要求重新认领 / 身份不符 / 未连接）立即报告。
- 会话层：重新认证遇到**沉默类**网络失败时，除了带出 `cause`，还把连接标记为「位置失效」
  （与网络变化通知走同一条 `_relocate()` 路径），下一次请求自行重新定位并认证，不依赖
  手动 `connect()` 或网络变化通知；以错误密钥应答（`secureChannel`）不标记，下一次请求
  立即拒绝。
- `host_product_session_test.dart` 新增 2 项：401 → 重新认证遇到断网 → 异常携带
  `cause=unreachable` 且不要求重新认领 → 网络恢复后**直接重试原操作**成功（不手动
  connect、无网络事件）；重新认证被错误密钥拒绝时下一次请求不再重新定位。
- 设备配网相关测试 50 项通过；`flutter analyze` 无问题；全量测试见本次提交说明。

## 原定真机验收步骤

1. korvo-1 在 Mac host 的 App 里走「添加设备或恢复网络」，第一次访问后观察进度文案；
   若平板仍回不了 Wi-Fi，应看到「手机还没回到主机所在的网络」而不是错误卡片。
2. 在系统设置连回 `rcgy5#305`（必要时先关后开 Wi-Fi）后回到 App，应自动进入「选择家庭 Wi-Fi」，
   设备侧不需要再操作；Mac `local-api.log` 出现 `POST /commissioning-vouchers`。
3. 第二次访问提交后，设备向 Mac 的 Hub 登记，App 自动跟进到「设备已接入这台主机」。
4. opi5max 上的旧记录之后在它自己的 App 里移除。

路由器对平板的关联拒绝（`assoc_no_resp_received`）本身不在 App 可控范围内；若反复出现，
应查路由器侧（频段/信道、客户端隔离、MAC 随机化策略）。


## 2026-10-10 交接复核与串口证据

本节区分已验证事实与待修复项，不表示跨 Owner 流程已全程验收通过。

- Claude 的新 App 在 00:07 首次取 voucher 连接失败后继续等待，手机回网后请求成功，
  Mac 出现 `POST /commissioning-vouchers 200`。第一访问后的等待修复已经踩到并通过。
- 第二访问日志为 00:15:06.387 已下发 Wi-Fi 候选，00:15:51.361 报
  `COMMISSIONING_TERMINAL_TIMEOUT`。触发的是 Android `configureNetwork` 的 **45 秒总 watchdog**，
  不是 30 秒轮询期限。另有收到 apply 响应后开始的 30 秒期限；两者不能混称。
  最后一条约 18 秒的 status 请求被 watchdog 关闭，不能单凭它断言设备成功处理了 18 秒，
  或确认单射频争用就是根因。
- 用户连接 Korvo 调试 USB 后，只读采集 CP2102N 串口，日志确认 SKU `korvo-1`。
  未刷写、未发送复位指令、未清空 NVS、未修改授权数据库。本次启动记录 POWERON；
  因此只能说明本次重启后的结果，不能补证此前卡住时的运行状态。
- 该次启动后 5.090 秒连接 `rcgy5#305`，2.4 GHz channel 6，BSSID
  `82:85:c4:7b:6b:19`；7.310 秒取得 `192.168.100.6`；7.930 秒接受
  Mac Owner `owner-0342958c2e259f177f43` revision 1；8.470 秒记录
  `Canonical EnrollmentProposal recorded; awaiting Decision`，随后进入 `PendingApproval`。
  Mac Hub 中对应申请的状态也为 `pending_review`。这是设备已经进入新 Owner 登记流程的证据，
  尚不是批准、激活或完整迁移验收通过。
- Mac 当前地址已变为 `192.168.100.3`，Korvo 通过原有 mDNS 正确定位。
  平板后来也成功连接 `rcgy5#305`（`192.168.100.7`）。因此不能将此前平板关联失败外推为
  AP 持续拒绝所有新设备。历史故障仍需同期 Korvo disconnect reason、AP 日志或关联帧取证。

### 应统一的恢复语义（待实现）

1. 第二次访问提交后，终态收不到属于“结果未知”，不能当作已回滚，也不能直接标成成功。
   当前 coordinator 将传输异常归为 `provisioning_failed`，checkpoint 变成 `failed`；
   `canResume` 只接受 `networkConfigured`，导致设备后来成功登记时，该 checkpoint 无法沿用
   已有 admission recovery。应保留设备、目标 Owner/generation、操作标识及不确定结果，
   返回主机后通过现有 recovery/proposal 查询确认，而不是引导再次下发 Wi-Fi。
2. 查询必须匹配该候选设备及目标 Owner，不放宽身份校验，不自动批准无关申请；
   主机拒绝、明确回滚和提交结果未知必须分别处理。
3. 先补结果恢复，再统一各阶段的期限和可观测日志。仅延长 App 超时无法覆盖断网、进程退出、
   终态丢失；也不应把固件成功终态提前到 Wi-Fi、Owner 路由验证和持久提交之前。
4. 本轮 Host 删除重加验收还发现：目标 opi5max 不可达、同网段只有 Mac 可达时，
   `AnnouncedAddressSource` 返回其他 Host 候选，`HostLocationException._describe` 又优先采用新候选，
   最终误提示目标 Host 身份不符。它也会使当前 voucher 等待分类提前退出。
   应区分“发现了另一台 Host”与“目标 Host 确认拒绝/身份变更”；保留严格 pin 验证，
   不能把无关 Host 的拒绝当成目标授权失效。该问题和终态未知恢复应分别回归。

上述两项恢复缺口不改变多个 mobile 平等管理 Host 的授权模型；它们分别位于 Host 寻址错误分类
和外设跨 Owner 配网结果恢复。本轮只补充验收与分析记录，尚未修改这些运行时代码。
