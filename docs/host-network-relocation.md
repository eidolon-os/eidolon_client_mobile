# Host 换网重定位与扫描去重

日期：2026-09-10。

## 目标与边界

Mobile 保存 Host 身份与管理授权。IP 是可失效的连接线索，换网不会创建新的 Host 记录，也不需要重新认领。复用现有 HostLocator、HostProductSession、HostRegistry 和标准身份/TLS/Controller 验证。

`hostId` 由 Host 公钥派生；现有登记按 hostId 去重。不同 IP 的同一身份归入同一记录。不同公钥不能仅凭相同名称或相同物理机器描述自动合并；Host 重装或身份重建仍走显式恢复流程。

## 修复内容

- **列表重新定位**：列表进入前台、刷新、网络变化时运行局域网定位，使用现有身份校验和认证。一次列表刷新共享一次 discovery survey；平台 mDNS 和网段探测的并发调用共享正在执行的探测，完成结果不跨轮缓存。列表不请求 BLE 权限。
- **旧结果失效**：列表刷新串行合并，网络变化后忽略旧轮结果。登记观察更新沿用原有认领代次、身份和时间检查，不覆盖备注、恢复已移除的主机或倒退到更旧地址。
- **统一连接发布**：显式连接和请求失败后的自动重定位，都由 HostProductSession 发布认证成功的地址。HostProductController 从同一入口同步当前连接与原登记。单个 session 的并发连接复用一个任务；连接期间网络变化时重新定位，不发布旧网络结果。
- **候选不是目标身份**：旧 IP 上的其他设备、其他 Host 的广播不能终止目标 Host 的定位。每个候选继续使用同样的信任校验。已经验证的目标 Host 拒绝 Controller 授权时，仍直接报告授权错误，不继续尝试其他地址规避拒绝。
- **真实网络变化**：Android 通过现有 NetworkChanges 接口接入 ConnectivityManager 的默认网络与 LinkProperties 变化，观察网络身份和本地地址，覆盖 Wi-Fi → Wi-Fi 及同网 DHCP 地址变化。Dart 多个订阅共用平台事件流。其他平台保留 connectivity_plus 回退。
- **保留主机名线索**：使用已认证机器资料中的 hostname，以及已有 URL 中的主机名。连接地址保存为数字 IP 后仍可重新按名定位。
- **已知主机重新扫描**：常规 BLE 添加入口验证出已保存身份后进入“连接已有主机”，不发送 Wi-Fi 配置、Setup 认证或 claim.complete。开发 LAN 入口对已知身份不要求新 Setup 窗口，按 Host 身份合并多个地址，显示“已添加”并返回原记录。显式恢复授权入口仍可执行重新认领。
- **界面**：列表显示“正在查找主机 / 可连接 / 当前网络未找到”等状态；上次 IP 放在主机详情，不把旧地址显示为当前在线证据。重新发现保留原名称与认领时间。

## 首轮自动化验证

- Flutter 全量：928 项通过，5 项既有跳过。
- Flutter analyze：无问题。
- Android debug APK：构建通过。
- App 原生单元测试：47 项通过。
- 新增/扩展回归覆盖：旧 IP 失效后列表保存新地址且记录仍唯一；共享发现轮次；旧 IP 被其他设备占用后继续查找；并发连接与网络变化期间的迟到结果；自动重定位回写；主机名保留；列表网络变化刷新；BLE 已知 Host 不重复认领；LAN 多地址合并、过期 Setup 窗口不拦已知 Host 重连；平台网络事件多订阅及独立释放。

一条原测试要求遇到错误 LAN 身份后不再尝试 BLE，本次按新的定位边界改为“继续寻找，但仍不得接受错误身份”。目标 Host 的授权拒绝仍保留原测试约束。

## 首轮待验收清单

首轮实现时未切换用户的 Wi-Fi、未修改 Mac Host 网络、未清空身份或安装新 APK。后续覆盖安装及真机结果见文末。以下完整换网场景仍应逐项验收：

1. Mac Host 与 Mobile 从网络 A 一起切到网络 B；原列表卡片自动更新可连接，打开后能连接同一 Host，备注与授权保留。
2. App 留在后台时双方换网，再回到列表；不依赖旧 IP 超时后的人工重新添加。
3. 在添加入口重新扫描这台 Host；进入已有记录，列表保持一项，不重复配网/认领。
4. 同时点击刷新和连接；不产生重复平台发现错误或被旧结果覆盖。
5. Host 确实离线时保留原记录并显示当前网络未找到；授权撤销、身份变化与网络不可达分别处理。

现有定位能力的范围仍是 mDNS、已知主机名、私有 IPv4 /24 的有界探测及显式连接中的 BLE 兜底；未扩展为跨网远程访问或重写服务端发现协议。


## 刷新断路复盘与公共传输生命周期修复（2026-09-10）

### 确认的问题

- Dart 的候选竞速和多 Host 并发，实际落在 Android 的单线程 HTTP executor 上；一个旧地址的 8 秒连接等待会阻塞其他主机。
- Local API 的 Dart Future 超时没有取消原生请求。默认 session factory 创建的 pinned HTTP client 被包装成借用对象，`LocalApiClient.close()` / `ManagementClient.close()` 没有关闭它。页面失效后旧请求仍然排队、连接。
- 列表只丢弃旧轮结果，没有结束旧轮连接；新一轮要等旧工作收尾。主机名解析也没有使用发现轮次的时间预算。
- 同一发现结果会作为不同已保存 Host 的候选。其他 Host 的 pin 拒绝不等于目标 Host 改了身份；原有最终错误选择和列表 catch-all 把不同事实混成身份异常或“未找到”。

### 最终实现

- Android 使用 OkHttp Dispatcher 的异步调度，最多 16 个并发请求、每地址最多 4 个。PinnedHttpsCalls 只管理 requestId 与 Call 的所有权及取消，不实现第二套网络调度器。
- Dart transport 为请求分配 ID；整体请求预算包括平台排队等待。超时与 client.close() 都通过平台桥执行 Call.cancel()。取消有独立类别，关闭后的 client 不接受新请求；取消不会自动重放管理操作。
- Typed API client 允许显式移交 HTTP client 所有权，保持原有外部注入默认借用语义；session 的平台 factory 对自己创建的 client 负责。Session 统一管理请求资源，关闭或网络失效时释放；竞速胜出立即取消其他候选，只对胜出的已验证 Host 认证一次。
- 列表刷新、换网、后台、离开列表及销毁会取消本轮 session。新网络无需等待旧连接结束；仍用原来的 revision 和 registry observation 校验阻止迟到结果覆盖新状态。
- HostLocationException 保存候选来源、地址和原始失败，不把任一未验证候选的拒绝提升成已保存主机的身份变化。目标 Host 已经验证后的 Controller 授权拒绝仍直达原恢复流程。
- 列表展示查找、连接、管理授权验证、已连接后的资料读取，以及超时/安全验证/无法确认等结果。不会把已发现地址的连接超时显示为“没有发现任何主机”。
- 已知主机名解析使用现有发现预算，超时后不会再启动迟到的端口探测。没有扩展网段扫描范围或新增跨网发现协议。
- 原生诊断记录 requestId、目标 pin 的短后缀、origin、阶段、耗时及结果；不记录认证头、请求体、响应体或 URL 查询参数。

仍遵循稳定 Host 身份 → 定位候选 → 原有 TLS / Host 身份验证 → Controller 认证 → 原登记更新。未新增 Mobile 专用服务入口，未改变认领、Owner 或服务端鉴权协议。

### 最终验证

- Flutter 全量 934 项通过，5 项既有跳过；analyze 无问题。
- Android App 原生 49 项通过。新增真实 socket 验证：一个不回应的连接不阻塞另一个请求；取消实际关闭 socket；已取消的队列请求不发送。
- 新增 Dart 回归覆盖 transport 超时取消及 client 隔离、候选竞速的资源释放、关闭期间迟到发现不再发请求、新网络不等待旧轮、未验证候选拒绝与连接超时的区分、DNS 超时不阻塞已发现服务。
- APK 构建成功，已通过 `adb install -r` 覆盖安装到平板 df331f93，随后启动验证。未清数据。
- 12:22 第一轮：Mac 在 192.168.1.32 上约 0.8 秒内完成主机读取、认证及资料读取（不含前面的发现等待）；香橙派的 192.168.1.33 此时 TCP 连接超时，未阻塞 Mac。竞速中 Mac 对香橙派地址的未完成连接在约 388 ms 被取消。
- 12:24 第二轮：两台主机完成标准连接、认证与资料读取，界面均显示“可连接”。香橙派四次 HTTP 请求约为 581 / 268 / 96 / 785 ms。本轮没有尝试已失效的旧地址。
- 安装前后 registry 仍为同两条 hostId；每条记录只有 last_known_base_url 和 last_connected_at 变化，分别更新为 192.168.1.33 与 192.168.1.32。其余 Host 字段与其他 preference 值保持不变。

### 主机侧仍需区分的无线链路问题

香橙派同样出现独立 SSH 的 TCP 超时，服务监听为 0.0.0.0:9002，平板邻居 MAC 与香橙派 wlan0 一致。内核日志确认 Wi-Fi 反复 Link Down / Link UP，例如 12:25:53 断开、12:26:00 重连。Wi-Fi 省电为开启状态，但这不足以确认掉线由省电导致。

进一步对齐原始刷新时段：11:50:50 断开、11:50:57 重连；11:51:54 再断开、11:52:01 重连。App 的一次 TCP 超时记录在 11:51:57，位于该断连区间。NetworkManager 同时记录 completed → disconnected → scanning，确认这不是仅有 App 内部的超时。

旧刷新时段的服务日志在 11:51:17 也记录了来自平板的 host GET、auth challenge、auth session 全部 200。因此不能把整个过程归结为持续找不到香橙派，也不能宣称修复 App 请求排队就修好了无线链路。此次没有修改主机网络、省电、驱动或部署；链路反复掉线的诱因尚未查实。

## 从主机连接到设备服务的地址分裂修复（2026-09-10）

### 根因与边界

主机管理与虚拟设备使用不同身份访问不同服务，这是原有架构；两条链路各自保存地址则不是必要边界。

13:19 的原始请求显示：HostRegistry 已通过 192.168.1.33:9002 完成主机验证、Controller 认证及 onboarding target 读取，但 DeviceOwnerDirectory 仍把 `last_reached_address=192.168.100.19` 传给 Owner transport。原实现等待 Controller bootstrap 3 秒后便返回旧 target；实际主机发现本身可能耗时 5 秒。bootstrap 迟到后即使更新了目录，已经创建的客户端仍在向旧 IP 的 9443 端口连接。

这是 Room 之前的配置链路断点，不是 ASR/LLM 超时。Owner 目录当时仍在有效期内；不需要重新认领、换证书或提高登记版本。香橙派另有已确认的 Wi-Fi Link Down/UP，两个问题同时存在，不能互相代替。

### 最终实现

- **信任与位置分开。** DeviceOnboardingTarget 删除 `hostAddress`、`addressHints`、`reachedAt`；DeviceOwnerDirectory 只保存并验证 Owner 根、签名目录和 signer 证书。旧 `last_reached_address` 读取时忽略，保存对应目录时移除，不需要清数据。
- **一个 Owner HTTP 路由入口。** DeviceOwnerDirectory 的公开目录续期、Admission、Device Control 共用 OwnerAuthorityRoutes。它从现有 HostRegistry 读取已选 Host 的地址观察，并复用 HostLocator、已有发现/DNS 与平台 TLS transport。没有新增持久化地址表、发现协议、Host 身份或服务端端点。
- **请求时定位。** 已创建的客户端在下一次请求时重新检查 registry 地址；本机网络变化使临时路线失效并取消旧 HTTP。新地址观察会取消还在等待旧地址的定位，旧结果不能写回新路线。请求失败清除对应路线，下次由同一定位入口重新寻找。
- **定位不授予权限。** 候选仅用于连接地址。对原签名 HTTPS origin 做不携带设备签名或 Controller token 的 HEAD 探测，由既有 Owner 根与 hostname TLS 验证筛选；404/405 也只表示该 TLS origin 已响应，不表示配置或 Room 就绪。随后实际 Device 请求继续使用原 URL、请求体、签名及信任根。远端签名 authority 使用正常 DNS，不经选中 Host 转发。
- **共享既有竞速机制。** HostProductSession 的候选调度提取到 HostLocator 的 `raceHostAddresses`，Host 身份读取与 Owner 公共 TLS 探测共用；失败及落败候选都释放连接。没有竞速业务 POST。
- **明确请求所有权。** 并发 Owner API 共用同一 origin 的定位，关闭一个等待方不会中断其他等待方；最后一个等待方退出会取消探测。网络变更只允许重做尚未发送业务请求的定位，不自动重放已发出的登记、确认、声明或配置请求。Device Control 的调用方在结束时关闭其 transport，App 销毁时释放 Owner 路由服务。
- **保留设备独立性。** 已安装 Owner 信任时，不再调用 Controller bootstrap，也没有“等 3 秒再走旧 IP”的分支；目录从其签名公开 URI 续期。有效缓存可在续期暂时失败时使用，过期、签名、Owner 身份与防回滚校验继续执行。首次安装信任仍走原有 onboarding bootstrap。

标准链路保持：选择稳定 Host → 用已安装的 Owner 信任定位设备服务 → 设备密钥读取/声明配置 → 选择 companion 与 mode → 原有 Room 接入。Host 管理的 Controller 权限与设备自己的 Admission/Device Control 权限继续分离，Mobile 没有增加特殊服务入口。

### 验证

- Flutter 全量 943 项通过，5 项既有跳过；随后补充“新 registry 地址取消旧定位”边界，Owner 路由定向 11 项全部通过。最终 analyze 无问题。
- Android App 原生 49 项通过，APK 构建通过。
- 回归覆盖旧目录 IP 的无损移除、Controller 已撤销时使用安装信任、公开续期及过期拒绝、Owner 身份/根不可替换、防止旧目录覆盖新目录、已创建客户端换地址、错误 TLS 候选不发送 Device 请求、并发共享定位及独立取消、本机网络变化、Host 掉线后的重新定位、已发送 POST 不重放、远端 authority 不被本地 Host 接管。
- 最终 APK 通过 `adb install -r` 覆盖安装到平板 df331f93，无卸载或清数据。列表保留当前三台主机。与此前保存的偏好快照相比，原有 Mac/香橙派的 Host 身份字段不变，只有最近连接时间更新；既有三项 mobile-body-claim 值相同。香橙派 Owner 记录只删除 `last_reached_address`，根与签名目录保持相同。
- 13:55 真机从香橙派卡片点击“开始对话”。Owner 逻辑 origin 仍是 `https://eidolon-hub-f89c0ecca5d0070a7989.local:9443`；平台请求依次为公共探测、目录 GET、设备配置 POST。香橙派日志记录 HEAD `/` 404、GET descriptor 200、POST `configuration:pull` 200。随后 Controller auth challenge/session 才完成，实证设备读取不依赖管理登录完成。
- 本轮平台探测耗时约 7.37 秒，随后目录 GET 76 ms、配置 POST 150 ms。主机日志显示 13:55:41 Wi-Fi 断开、13:55:48 恢复，随后服务于 13:55:49 响应；这是实际无线中断造成的等待，本次未改动主机网络配置。
- 页面最终显示已选伙伴 `mac`、待选“按住说话 / 轮流说话 / 自由对话”，提示“选好伙伴和对话方式后再接通”，麦克风保持关闭。本次实测覆盖主机列表至设备配置/对话准备；没有把它记为新一轮 Room、ASR、LLM、TTS 全链路语音验收。

无线链路稳定性仍取决于主机网络；本次修复的是应用地址事实分裂、请求生命周期和同类 Owner API 的共同路径，不宣称已修复香橙派 Wi-Fi 掉线诱因。

## Host 媒体服务的网络生命周期（2026-09-10）

Mac 的管理地址更新后，运行中的 LiveKit 仍使用启动时的旧网卡信息，因此“找到 Host”不等于“Room 媒体已就绪”。本轮修正在共享 Host 生命周期中完成，不增加 Mobile 专用入口。

- 稳定身份、同机 loopback/Unix socket、监听地址、动态对外地址、显式公网/NAT 策略分别处理。NATS 的同机地址继续使用 loopback。
- Mac/Linux 启动器都移除自动探测后注入 `rtc.node_ip` 的逻辑；原生 ICE 收集合适的接口，显式部署覆盖保留。示例配置默认采用动态观察。
- 既有 eidolond 协调循环按共享 manifest 的 `restart_on_network_change` 声明处理网络变化。目前 LiveKit 声明该依赖，NATS 不声明。网络稳定 10 秒才刷新，失败至少间隔 30 秒重试，断网或抖动时不反复重启。
- 可丢弃的运行观察缓存绑定网络指纹和进程实例，防止守护进程重启、服务自行重启或启动期间换网造成误判。设备登记、Owner 身份、Companion 解析与期望状态版本均不参与该判断。
- Ops 通过既有服务目录读取明确的 `network_current` 事实，旧进程只有普通 `ready` 时不能通过；不再从 YAML 中的地址推断媒体进程已经更新。Linux 沙箱复用已有网络观测所需的 AF_NETLINK，仍无网络管理权限。

完整决策和边界见 [Kernel ADR 0017](../../eidolon_kernel/docs/adr/0017-network-dependent-service-lifecycle.md)。

验证：Kernel 全量 463 项通过、1 项跳过，最终 system 定向 121 项通过、1 项跳过；Ops 全量 1068 项通过；Channel LiveKit 52 项、Admin 服务客户端 13 项通过。香橙派临时 systemd 沙箱以 eidolon 用户、无额外 capability 成功运行本次网络观测源码，未修改其现有部署。Mac 独立真实 LiveKit + supervisord + SDK 测试观察到旧 TCP 候选超时，生命周期刷新后进程实例变化，两个客户端成功收发 WebRTC 数据，再次协调不重复重启。同机新启动实例可能通过 UDP 候选连通，因此该 TCP 测试没有被描述成真实跨 Wi-Fi 复现。

本轮仅提交源码，暂不激活到日常运行的 Mac/香橙派部署；后续需通过标准部署流程同步 Kernel、Ops 和生成的 manifest。真实 Wi-Fi 切换后的 Room/语音验收仍待执行，不以单元测试、端口响应或隔离媒体测试代替。
