# 可变运行环境：职责、失效与恢复

## 原则

把一个值放在哪里，取决于谁能知道它、有效多久、变化后谁必须采取动作。配置声明部署意图，运行时观察说明当前环境，客户端连接结果才证明它实际可达。SSID 不是网络身份，IP 不是 Host 或 Owner 身份。

| 类别 | 示例 | 所有者与处理方式 |
| --- | --- | --- |
| 稳定身份 | Host 公钥、Owner、DeviceRef、Claim generation | 身份/授权域；换地址不重建、不重认领 |
| 部署策略 | 本地/远端 LiveKit、端口、显式固定地址 | 配置；保留明确覆盖，不能把自动探测结果写成覆盖 |
| 环境观察 | 活跃网卡、地址、掩码、默认出口 | 从 OS 按需读取或定期协调；默认出口只作为候选排序线索 |
| 路由候选 | 发现记录、信令 URL、上次成功地址 | 有限有效期的线索；失败后刷新，不能作为身份验证依据 |
| 绑定有效性 | 凭据有效期、运行环境是否仍匹配 | Provider 分别判断；凭据没过期不代表旧地址仍有效 |
| 持有环境的资源 | mDNS socket/组播成员、LiveKit/Pion 实例 | 资源所属组件负责重建，不能仅改配置或广播内容 |
| 就绪与实测 | network_current、信令健康、RTC/音频 | 各自报告自己的事实；进程存活不能替代跨端连接验证 |

同 Host 的服务调用继续走 loopback/Unix socket。跨语言契约放在 SDK；各组件的 OS 读取放在自身适配器。共享的是职责和失效语义，不增加一个全局地址缓存、第二个生命周期守护进程或由 Mobile 代管 Host 服务的机制。

## 本次修复的完整链路

1. **Hub 发现**：观察地址及网卡身份，变化时关闭旧 Zeroconf 实例并重新注册。断网撤下旧资源；无网络启动不阻止 Hub 本地服务启动；注册失败可重试；注册期间再次变网不采纳过期实例；停止与刷新串行化。
2. **Channel 地址**：每次签发从活跃网卡读取本地 IPv4 候选，排除 loopback、link-local、未指定及组播地址。默认路由只影响顺序，不是本地服务的前提。明确的远端 URL 保持原策略。
3. **绑定失效传播**：LiveKit adapter 将签发时的候选保存在私有 handle，查询当前绑定时重新比较。Provider 使用可选 `refresh_required` 表达运行环境已变，保留原绑定和凭据时间。Hub 经原来的幂等 refresh 操作推进绑定，不能回到 provision、伪造过期时间或重新审批。
4. **客户端选择**：绑定 v2 保留 `server_url`；可选 `server_urls` 表示同一凭据和房间的有序候选，首项必须等于 `server_url`，不得为空或重复。Mobile 清理失败 Room 后继续，取消或新连接阻止旧尝试复活；ESP32 在原有重试、看门狗和 generation fencing 下轮换候选，优先保留最近成功位置，网络恢复后重新开始。
5. **Ops 就绪检查**：Mac/Pi 均从当前本地地址中选择检测入口，没有默认路由时仍可检测可用局域网。上一轮已经部署的 LiveKit `network_current` 门禁继续生效。

失效传播闭环为：网络变化 → mDNS 网络资源更新 / LiveKit 自动协调 → Provider 发现旧绑定路由失效 → Hub refresh → 客户端获取并尝试新候选 → 实际连接成功后恢复 operational 状态。

## 兼容及边界

- 既有单地址 v2 绑定仍有效；新候选字段由 SDK golden 定义，生产端、Mobile 和 ESP32 使用同一份正反例。
- `refresh_required` 是 Provider 的通用运行时有效性判断；Hub 不解析 LiveKit opaque payload。Hub 与 Provider 需要一起更新；旧客户端只能使用首项，完整的多网卡恢复需要更新客户端。
- 不修改 Owner、Claim、Wi-Fi 凭据，不清除 NVS 或审批记录。上次保存的路由只是可恢复缓存。
- 候选来源仍是受信任配置/已验证绑定，不能把任何“能连通的主机”替代已认领 Host。此改动不承诺跨 VLAN、防火墙、AP 隔离或 NAT 的任意可达性。
- 不把“无默认路由”等同于“断互联网”：默认路由存在但上游不通，与局域网没有默认出口是两种情况。
- 不承诺保留换网期间正在进行的一轮语音；客户端必须按原有会话恢复逻辑重连。

## 验证结果（2026-09-10）

| 层次 | 结果与范围 |
| --- | --- |
| SDK | conformance 与 generation --check 通过；契约版本 `bfb9441eb4bcef449ce3e2adc6e94ac44169a061`，两端锁定同步 |
| Hub + Provider 联测 | 23 项通过：mDNS 生命周期单测及 Channel reconciliation（含真实 Provider/SQLite/本地 HTTP 适配路径）；网卡变更使用模拟观察 |
| Channel Provider | 170 项通过：完整 Provider 测试集，含未到期运行时刷新、旧观察不能替换新 active 记录、显式服务地址变更 |
| Ops | target agent/readiness/probes 共 186 项通过；最终活跃网卡过滤修改后 target agent 133 项再次通过 |
| Mobile | 47 项通过：绑定、会话、恢复及候选失败/取消/替换竞态；修改文件静态检查无问题 |
| ESP32 | onboarding protocol 和 channel recovery 两组原生 C++ 测试通过，包含 SDK 共享候选正反例 |
| BOX-3 固件 | 官方 `scripts/eidolon/eidolon-esp-box-3.sh build` 编译、链接、镜像及分区大小检查通过，应用分区余量 8% |

构建曾被 GitHub 检查依赖更新失败打断。最终仅对本次构建设置官方
`IDF_COMPONENT_CHECK_NEW_VERSION=0`，使用现有锁定依赖并保留校验；未修改 manifest、
依赖版本或全局 Git 配置。

## 部署与验收边界

本轮跨组件改动尚未部署 Pi5、安装 Mobile 或烧录 BOX-3。此前已部署的 LiveKit
网络生命周期修复仍是设备上运行的版本。本轮代码测试和固件构建不等同于物理换网验收。

发布时一起更新 Hub/Provider，更新 Ops 检测逻辑，再安装带相同 SDK 契约的两端客户端。
保留 Claim、Owner、NVS 和审批数据。部署后的验收包括：

1. 同 SSID/密码更换网络，核对新 DHCP 地址、mDNS 重发现、LiveKit network_current，
   以及绑定从旧 operation 推进到新 operation；无需重新认领或人工审批。
2. 双网卡中首候选不可达，确认客户端使用后续候选且没有残留旧连接或成功状态误报。
3. 无默认路由但局域网仍可用，以及断网后恢复；确认候选、就绪状态与实际可达性一致。
4. 最终核对真实 ICE 连接和双向音频，并核对 Claim generation 未改变。
