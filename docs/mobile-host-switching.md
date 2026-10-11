# Mobile Host 切换：数据作用域与生命周期

## 当前边界（2026-10-11）

设备公钥及 `device_instance_id` 独立于 Host / Owner Domain；切换网络、Host 或管理域不会生成新设备身份。Android 只使用既有稳定设备 Keystore alias，Controller 签名密钥仍独立。

Host 地址、信任目录、Claim / DeviceRef 和临时 handoff 属于各自 Owner。现有 scoped Claim 存储只是可重新验证的引用缓存，不是授权依据；不能把 A 的 Claim 发送给 B。每次返回由原 Host 根据同一设备身份查询记录，并按现有流程验证或重新签发授权。撤销后必须重新获得授权。

临时 handoff scope 与持久身份分离，避免旧请求清理另一 Host 的临时密钥。沿用现有串行切换和事务边界，不新增身份映射或身份历史仓库。首次迁移仅搬移旧 Claim，保留其 Owner 边界；旧版本按域创建的其他设备身份不会冒充稳定设备的 Claim。

### 本轮验收（2026-10-11）

- Mobile `a03afc5` 已安装到小米平板；ESP32 `ca2e1b1c` 已以 app-only 更新 Box-3 和 StackChan，启动 buildstamp 均通过校验。
- 平板完成 Pi5 → Mac → Pi5。两个 Host 的列表均显示稳定身份 `08b2358fd82bf6c46c182251d5bfb3ab7aea4384e06ca24858921453cfdf268d`；Mac 走已有登记恢复，返回 Pi5 无需重新登记，列表没有增加记录。
- 首次通过现有产品移除流程撤销 Pi5 的四条历史身份：旧 StackChan `0a077354…`、旧 Box-3 `e7e8b4a0…`、旧 Android `646fcf32…` 与 `cbaca296…`。当时列表各剩一条，但遗漏了另一条旧 Box-3 身份 `8d733176…`，不能据此认定历史数据已清理完成。
- 首次验收时 StackChan 在 Pi5 在线；Box-3 实际连接 Mac（192.168.100.6），身份为 `8fd7b927…`，启动日志达到 `operational_ready=1`。Mac 列表仍显示连接状态未知，本轮未更新 Mac 的状态观测服务。
- Mobile 相关回归 118 项通过、1 项跳过，静态分析通过；Hub 既有授权回归 13 项通过。ESP32 事务回归覆盖 7 个 Owner 间连续切换 50 次保持身份，以及真实 NVS 掉电恢复、100 次网络维护事务。实体设备跨 Host 来回配网未在本轮真机重做，不能以这些测试替代真机验收。

### Box-3 返回 Pi5 与历史记录补清理（同日）

- 用户将 Box-3 从 Mac 配置回 Pi5 后出现两条记录。只读核验确认：Pi5 的 `8d733176…` 于 12:26 登记；Mac 的 `8fd7b927…` 于 20:20 登记，早于修复固件 20:28 的构建；20:45 返回 Pi5 使用的仍是 `8fd7b927…`。时间均为 Asia/Shanghai。这次切换保留了身份，新增显示来自旧身份未退出使用。
- 首次收尾把 `8d733176…` 当作应保留的当前记录，没有与设备实际运行的 `8fd7b927…` 对照，是历史迁移清理与验收的遗漏。稳定密钥修复不能自动恢复或关联此前被替换的密钥，不能按设备名称推断身份并合并授权。
- 经用户授权，通过平板现有“移除设备”流程移除 `8d733176…`，界面确认撤销生效；返回并刷新 Pi5 列表，仅保留 Box-3 `8fd7b927…`，状态在线。未改代码、未直接修改数据库，也未修改当前设备身份或配网。
- 此次清理时仅证明修复后的 Mac → Pi5 单程保持身份；后续完整往返验收见下。

### 清理后的完整往返核验（同日 21:03–21:07）

- 用户完成 Box-3 的 Pi5 → Mac → Pi5 配网往返。只读查询两台 Host 的 Hub：Mac 在 21:03:56、Pi5 在 21:05:41 更新同一 `8fd7b927…` 的 Claim，两边均为 `active`、`claim_generation=2`。
- 两边公钥登记时间仍分别为 Mac 20:20:16、Pi5 20:45:15，没有生成新身份记录。Pi5 的旧 `8d733176…` 仍为 `revoked`。身份保持及复用记录验收通过。
- 在线状态与页面刷新验收未通过：21:06:54 Pi5 实时观测 StackChan 在线、Box-3 离线。平板两次读取均显示“主机尚未建立 Owner Workspace，不能读取设备”，保留最后成功读取于 21:04:36 的三条缓存记录，连接状态均为未知。不能以缓存列表证明当前在线，也不能据此断定 Workspace 实际不存在或 Box-3 离线的原因。
- 本轮只读核验，未修改业务代码或服务配置。身份问题的往返验收通过，不等于刷新与在线状态主线已全部通过；后两项仍需排查。

以下记录为此前“每个 Owner 独立设备密钥”的历史实现与验收，不再作为当前身份规则。

## 目标与架构边界

Mobile App 能管理多台 Host，也能承载多个独立的标准虚拟 Device。**一个 DeviceInstance 仍只属于一个 Owner Domain**。不同 Owner 使用不同 operational key／DeviceInstance／Claim；同一 Owner 的多个 Host 只是不同入口，复用其 Device。软件发布号、IP 地址、Companion 或对话模式都不是设备身份的分区键。

Controller 密钥、Host pin 和管理会话继续走原有管理链路。设备登记、签名、Claim、Manifest 与 Channel 继续走标准 Device 协议。没有新增服务端 Mobile 分支、协议或多 Owner Claim 机制。

## 排查结果与处理

| 数据／操作 | 原问题或已确认边界 | 处理 |
| --- | --- | --- |
| operational key、DeviceInstance | 全 App 一个 Android Keystore alias，两台不同 Owner 的 Host 使用了同一个 DeviceInstance | 为每个 Owner 固定 Device scope；同一不可变 PlatformBridge 的取公钥、签名及 handoff 操作始终使用该 scope。Controller alias 不可由此选择 |
| Claim、DeviceRef、未完成 ACK | 全 App 单份记录，恢复另一台 Host 会覆盖当前记录 | 每个 Owner 独立保存；跨 Owner 保存和恢复被拒绝；迁移保留旧 DeviceRef、代际、密钥、ACK 命令及证明 |
| 临时 handoff key | Android 只有一个 holder，第二次登记会替换第一个密钥 | 每个 Device scope 一个现有 HandoffKeyHolder；领取、签名、查询、销毁都按 scope 操作 |
| 登记运行状态 | 只有一个 `_scope`，切 Owner 会替换 Session，进行中的登记被全局阻塞 | 按 Owner 保留登记 Session；切换管理入口时更新同 Owner 的管理能力，不挪用另一 Owner 的 proposal／command／proof |
| 对话／音轨／回调 | 新页面可能与旧页面异步关闭重叠；慢的旧 open 可能晚于新选择完成 | 打开按请求顺序和 revision 控制；先等待旧 Flow 关闭；关闭可等待且幂等；已退出 Flow 不再启动或继续伙伴写入 |
| Owner 目录与 Host 地址 | `putIfAbsent` 固定第一次路由；延迟 locator 覆盖后选的路由；同 Owner 的旧 Host 缓存可能降回旧 descriptor | 显式采用当前选择的 Host 地址；旧 lookup 不覆盖后选路由；保留已接受的最新签名 descriptor；续期不把一台 Host 的地址复制给所有 Host |
| 首次登记的管理准备 | 安装的 Device trust 可先恢复，Admission 查询早于 Controller ready，误报 Workspace 未完成 | Admission adapter 等待与 roster／bootstrap 共用的 Host 准备 Future；已有 Claim 的 Device 配置请求仍不依赖 Controller |
| 偏好文档并发 | 各实例有各自写队列或没有队列，整份 JSON 的读改写可能互相覆盖 | 复用一个按偏好文档串行的写入原语，覆盖 Host registry、Claim、Owner 目录、反回退状态及 Device Setup checkpoint；完成后释放队列状态 |
| Host 资料异步回写 | 后台观察与删除／改名／重新认领交错，可能覆盖较新资料或重新写回已删除 Host | 原子 updateObservation：仅更新仍存在且同一登记的 Host，保留名字与 pin，较新连接资料优先；已 dispose Controller 的连接结果不再持久化 |
| Companion、mode、字幕、错误、Room token | 原本属于页面／会话；多 Host 不应共用 | 每次新 Flow 新建 ClientController；选择和字幕不跨 Host 搬运；绑定从当前 Owner 的挂载读取，模式仍要求入房前选择 |
| Controller 管理会话 | HostProductSession 原本固定一个 ManagedHost 和 pin；不是全局 token | 保留；补上关闭后的异步认证结果不得重新填充会话 |
| 外部实体设备 Setup checkpoint | 已包含 Owner 目标且页面恢复按 Owner 筛选 | 保留已有筛选与协议；共享写入串行化，避免不同 Host 页面保存丢条目 |

## 迁移行为

1. 首次升级读取旧 Claim 与当前 legacy operational key 的匹配关系，将 legacy key 永久分配给该 Claim 的 Owner。
2. 先写入该 Owner 的 Claim 槽，再清理旧槽；中途中断可重试，不覆盖较新的 scoped Claim。清理／撤销后不会再次导入旧记录。
3. 如果没有可用旧 Claim，首次验证的 Owner 占用 legacy key，以保留可能尚未结束的旧 enrollment；以后不再把此 key 分给别的 Owner。
4. 其他 Owner 使用自己的新 operational key，按已有登记与 Owner 确认流程接入一次。不能把旧共享 DeviceInstance 的历史 Claim 伪装成新实例的 Claim；不自动删除远端历史设备。
5. Android 偏好写入确认实际落盘后才向 Dart 返回成功。私钥仍留在 Keystore；handoff 私钥仍只在内存中，App 被杀后的恢复边维持原合同。

## 验证记录

- Flutter 最终全套 **912 项通过、5 跳过**；静态检查通过；`git diff --check` 通过。
- Android 原生单元测试 47 项通过；APK 构建通过。
- 真机升级保留香橙派的原设备 `device-instance-08b2358f…`，Owner generation=3、Claim generation=1、trust epoch=1，ACK 时间仍是 2026-09-08T14:07:59.566036Z。
- Mac 使用新 DeviceInstance `device-instance-c56a833e…`，走标准登记成功到达待批准；未把香橙派 Claim 发给 Mac。
- Mac 待批准期间切到香橙派，直接恢复原伙伴 `mac` 的准备页，没有登记不匹配，也没有丢失香橙派 Claim。香橙派服务日志确认 00:28:41 以 `ptt` 接通原 Room `eidolon-device-5582b08fb6be2decd55a46c3` 并发送 `session_started`，00:29:49 空闲正常结束。
- ADB 断开后已恢复连接，完成后续验收。第一次 Mac proposal 于 00:26:04 创建、00:41:04 到期，服务端 00:41:07 标记 expired，属于正常 15 分钟超时。随后 00:42:26 重新提出登记，完成“Mac 待批准 → 香橙派准备页 → Mac 待批准”往返，再于 00:44:12 成功批准／领取／ACK；证明临时密钥和登记运行状态在切换时保留。
- 已登记后的 Mac → 香橙派 → Mac：分别于 **00:44:13、00:46:11、00:46:58** 收到服务端 `session_started`，全部使用 PTT。每次返回读取各自伙伴（Mac 的 `Eidolon`、香橙派的 `mac`），没有再次登记、恢复或不匹配提示。
- 安装提交 `1bfdf1b` 的最终 APK，执行 App force-stop 后重新启动。冷启动后的 Mac → 香橙派 → Mac 分别于 **00:48:20、00:49:14、00:50:36** 收到 `session_started`。Mac 始终使用 Room `eidolon-device-d6d42f74715993602d36a388`，香橙派始终使用 Room `eidolon-device-5582b08fb6be2decd55a46c3`。
- 对两个 Owner 的完整 Claim 文档进行排序 JSON 后 SHA-256 比较，重装覆盖、冷启动和两轮往返后与基线完全相同。DeviceInstance、DeviceRef、代际、Grant 和 ACK 记录均保留。最终已结束测试对话，停在准备页。
- **本次 Host 切换真机验收通过**。这项结论针对登记隔离、未完成登记往返、接通、关闭及冷启动持久化，不等同于 ASR→LLM→TTS 全链路语音验收。
- 本次没有改服务端或发布 Host；原先 LLM 2048-token 上下文限制不属于 Host 切换修复，未在这里改变。
