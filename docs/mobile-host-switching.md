# Mobile Host 切换：数据作用域与生命周期

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

## 已验证与剩余验收

- Flutter 最终全套 **912 项通过、5 跳过**；静态检查通过；`git diff --check` 通过。
- Android 原生单元测试 47 项通过；APK 构建通过。
- 真机升级保留香橙派的原设备 `device-instance-08b2358f…`，Owner generation=3、Claim generation=1、trust epoch=1，ACK 时间仍是 2026-09-08T14:07:59.566036Z。
- Mac 使用新 DeviceInstance `device-instance-c56a833e…`，走标准登记成功到达待批准；未把香橙派 Claim 发给 Mac。
- Mac 待批准期间切到香橙派，直接恢复原伙伴 `mac` 的准备页，没有登记不匹配，也没有丢失香橙派 Claim。香橙派服务日志确认 00:28:41 以 `ptt` 接通原 Room `eidolon-device-5582b08fb6be2decd55a46c3` 并发送 `session_started`，00:29:49 空闲正常结束。
- 2026-09-10 00:28 后 ADB 设备断开。**Mac 返回后继续领取、双方完成登记后的 A→B→A，以及 App 重启后的往返真机验收尚未完成**，不能记为全部验收通过。自动化已覆盖对应的作用域持久化、runtime 往返与延迟响应。
- 本次没有改服务端或发布 Host；原先 LLM 2048-token 上下文限制不属于 Host 切换修复，未在这里改变。
