# Pi5 同 SSID 网络迁移导致 LiveKit 不可用

## 已确认的根因

2026-09-10，Pi5 从 `192.168.1.37` 迁到 `10.183.24.39`。SSID 和密码保持不变，设备自动连上新网络；它们不代表网络地址保持不变。

部署前证据：

- Pi5 正在运行发布 `20260910-pi5-new-board-v1`，Kernel 为 `24ed5b3dbbe666169a38cba3d4593f511aac70c6`。
- LiveKit PID `2156` 从 17:39:16 起持续运行。旧启动器自动选取启动时的地址，写入 `/run/eidolon/livekit/livekit.yaml` 的 `rtc.node_ip`；该值仍为 `192.168.1.37`。Host 没有显式设置 `EIDOLON_LIVEKIT_NODE_IP`。
- BOX-3 已获得新信令地址 `ws://10.183.24.39:7880`；配网、登记和准入已成功。LiveKit 失败日志仍向对端提供 `tcp4 host 192.168.1.37:7881`，BOX-3 的候选地址已经是 `10.183.24.236`。
- 已部署的 eidolond 没有网络生命周期观察器，无法重建持有旧网络地址的 LiveKit 进程。
- Channel 的 ListRooms 健康检查只证明信令 API 可访问，不能证明 RTC 能连通。

故障链：网络地址变化 → 管理与信令发现更新 → LiveKit 启动配置及进程内接口快照仍旧 → ICE 无法连接 → 服务 API 正常但媒体不可用。

## 架构修复

使用已经提交的 Kernel `41ed793d3c3b0eaab16ea6c0a8e2657a633212fe` 和配套 Ops 发布、就绪检查。设计见 Kernel `docs/adr/0017-network-dependent-service-lifecycle.md`。

1. 启动器默认不写 `node_ip`，使用原生 ICE 收集有效地址。固定地址只接受明确的部署配置。
2. eidolond 根据实际网卡地址、掩码和默认路由源地址观察网络，不以 SSID 判断网络是否改变。
3. 网络稳定 10 秒后，只重建声明 `restart_on_network_change` 的受管服务；LiveKit 声明此策略。断网和抖动期间撤下受影响服务的 ready endpoints，失败重试有 30 秒间隔。
4. 将网络指纹与实际进程实例关联；eidolond 自身重启不无条件重启已协调的 LiveKit。重建过程中再次换网时不能错误地记录完成。
5. Ops 检查显式 `network_current`，旧 daemon 或旧 manifest 的普通 ready 不足以通过验收。

本轮进一步核对发现，Ops 已提交实现只将这个门禁用于 Mac（`HostKind.SOURCE`），Linux agent 没有该项检查。因此补齐了共享 readiness 合约与 Pi5 agent：通过 `/run/eidolon/system.sock` 读取 `/api/system/v1/services/livekit`，要求正确的 service_id、`ready` 和显式 `network_current: true`。响应不可用、旧版本缺少字段、刷新未完成均不通过，报告保留实际服务状态供诊断。

仅删 `node_ip` 不够：当前 LiveKit 1.11.0 的 Pion 网络对象在创建时捕获接口清单，需要重建进程才能刷新。方案不承诺保留换网期间正在进行的语音轮次，客户端仍需重连。

## 验证与发布记录

- 本轮 Kernel 定向测试：网络协调、LiveKit 地址策略、manifest 合约、systemd 部署，共 39 项通过。
- 本轮 Ops 新增 Pi5 门禁后：目标 readiness、目标 agent、socket probes 共 185 项通过；覆盖信令可达但网络状态旧、缺失、不可读或未就绪。真实 Unix socket 测试同时覆盖工作站和目标 agent 实现。Ruff 和 diff whitespace 检查通过。
- 与旧发布比对：运行代码只新增 Kernel 上述提交；Channel 新增一项地址职责说明文档。其他运行组件提交相同。
- 正式发布候选：`20260910-pi5-network-lifecycle`，通过 Ops `deploy` 准备；有线连接 `169.254.182.252` / Mac `en7`。可回滚模式，数据库迁移列表为空。
- 发布已激活：`20260910-pi5-network-lifecycle`，`status=activated`，`persistent_state_mutated=false`，`database_migrations=[]`。正式 app-ready 全项通过，包含 `livekit_network_current=true`。
- 已核对 Pi5 当前链接指向新发布；实际 runtime YAML 不再含 `node_ip`；生成的 manifest 含 `restart_on_network_change: true`。LiveKit PID `20528`，启动时间 18:25:06。
- 18:25:13，原已准入 BOX-3 `device-instance-61ab1901ecb28bca6080c29b81b4c4fab48f6cf72a38f00139d76e378be815c8` 自动连接。LiveKit 记录 `participant active`，选中本地 `10.183.24.39:56748` 与设备 `10.183.24.236:52085`，并记录 `mediaTrack published`。
- 同时串口记录 `DTLS: SRTP connected OK`、`operational_ready=1 reason=channel_connected`、`SetState ServerUnreachable -> ConfigReady`。本次恢复未要求用户重新配网、移除设备或手动审批。
- 验收边界：已验证当前故障恢复、真实 RTC 连接及轨道发布；未声称已进行第二次物理 Wi-Fi 迁移或人工听音验收。网络变化、稳定窗口、进程重建及失败闭合的自动协调行为有回归覆盖。

## 与先前问题的边界

先前 `owner trust was not stored` 的确切失败分支缺少发生当时的串口证据，本结论不将其归因于 LiveKit。用户已确认目前配网及准入成功，保留当前设备。此次修复不需要删除、重新认领设备或手动审批。
