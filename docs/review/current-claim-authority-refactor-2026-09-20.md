# 当前设备授权与登记事务收敛（2026-09-20）

## 问题与决定

此前 Host/Ops 重构收敛了新安装、升级和 Authority 丢失的处理，但 Mobile 仍用历史 Enrollment → Decision → Grant → ACK 链发现已授权设备。本地 Claim 引用又独立保存 Owner generation。历史双机共用身份后，目录已对齐 generation 8、本地记录仍为 9，两个恢复依据发生分歧。此前修复打通了重新登记入口；本次删除恢复对完整审批历史的依赖。

当前 Claim 是设备授权的唯一依据。管理端只定位公开引用，设备必须用已有 operational key 向 Device Control 证明身份，才能恢复本地引用和获取通道。Hub 在 ACK 验证成功的事务中激活 Claim；客户端不再重复证明这个事务曾经发生。

## 现有层的职责

| 层 | 保存或判断什么 | 不承担什么 |
| --- | --- | --- |
| Host/Ops | Host 唯一身份、部署事实、Authority 数据存在性；新 Host 新身份、普通升级保持身份 | 不由客户端发现失败触发重新创建 Authority |
| 签名 Owner Directory | 信任根、委派、当前 endpoint 与兼容 generation | 不证明某台设备已经获准 |
| Hub 当前 Claim + Device Control | 当前 active/suspended/revoked 授权、私钥证明、通道配置 | 不要求客户端读全审批历史 |
| Enrollment/Decision/Grant/ACK | 明确批准、未完成事务、幂等重放与审计 | 不充当第二份当前授权状态 |
| 本地设备记录 | 公开 DeviceRef 提示、可选历史 receipt、待 ACK 的精确证据 | 不声明自己仍被授权，不伪造 Grant/ACK 时间 |

继续复用 Android Keystore P-256、已有签名/TLS 校验、SDK DeviceRef 解析、Admin `/api/local/v1/device-claims`、Hub `configuration:pull` 和现有 ACK 幂等机制。没有新服务、新加密协议、新身份注册表或数据库迁移。

## 确定的行为

- 已有当前引用：直接 Device Control；Controller 不可用不影响正常设备会话。
- 引用丢失、历史 generation 不同，或旧协议返回 `STALE_GENERATION`：查询当前 Claim。读取失败不能推断“没有授权”。
- 当前 active：提供显式恢复；恢复时设备私钥证明成功才保存当前引用，不查历史 ACK。
- 当前 suspended：提示授权不可用，不能通过重新登记绕过。
- 当前 revoked：显示撤销，重新登记仍必须明确批准。
- 当前 Claim 不存在：才查看未完成登记。已完成历史不重新产生授权；无未完成事务则允许明确提出新登记，保留旧引用和设备身份。
- 待 ACK：只按原 command、Grant、proof 重放；跨 Owner 或跨 Authority generation 拒绝。旧版不完整记录仍保留身份归属线索，在重放边界拒绝，不静默转成“已完成”或删除。
- 本机 key、Claim、所选 Authority 或登记操作在核验期间改变：拒绝写入晚到的结果。正常配置响应也做相同检查，避免覆盖新的登记或被旧撤销响应清掉新记录。
- Claim 查询分页完整读取，重复 cursor、重复本机 Claim、错误 Owner/generation 均拒绝；不同 Owner 不提供“恢复”按钮。
- 一次 propose/ACK 使用同一目标快照；进行中的登记不能随目录刷新转到另一代 Authority。相同 Authority 的 endpoint 更新仍可重绑定。

## generation 的边界

`owner_domain_generation` 保留在线协议与历史设备兼容用途；不新增自增规则，也不把比较大小当成迁移决策。`claim_generation` 仍用于一次授权的写操作隔离；`trust_epoch` 保留现有协议字段，本次不扩展未实现的轮换机制；`directory_revision` 仍只表示目录版本。

本次不宣称磁盘级防回滚或同身份多机迁移已经解决。整盘一致回滚不能由同盘 marker 证明；Host 授权库确实丢失仍应由 Ops 判定事故并停止自动重建。旧双机身份问题必须按原主机恢复或新主机新身份处理，不能靠客户端调 generation 解决。

## 验证

重点覆盖：没有任何历史记录也能恢复、历史存在但当前授权缺失、撤销/暂停优先、分页、私钥拒绝、nonce 错误、并发切换/新登记、旧检查点迁移、跨代际 ACK 拒绝、正常连接不访问 Controller，以及 Hub 的读修复和写操作代际隔离。


- `flutter test --no-pub`：1140 通过，8 项既有跳过。
- `flutter analyze --no-pub`：无问题；debug APK 构建成功。
- Hub `test_stale_device_ref_recovery.py`、`test_device_delivery_http.py`、`test_manifest_self_heal.py`：24 通过（1 项既有 Pydantic 测试数据警告）。
- Ops `test_install_decision.py`、`test_owner_domain_assets.py`、`test_authority_restore.py`：68 通过。
- APK SHA-256：`29fd2a12044cae3be52863be4693efe80dc5fa937616961e90a360dbc58ebeda`，已 `adb install -r` 保留数据安装，随后 force-stop 冷启动。
- 真机已确认：Pi5 当前地址由 mDNS 解析为 `192.168.100.15`，主机页已安全连接；设备 ID/密钥指纹仍为原值。对话准备页未要求重新登记。检查前后 Hub 10 个 Claim、16 个 Proposal、10 个 ACK 及全部本地 Claim 检查点完全一致。本地 Claim 还与此前已验收安装的记录一致。
- 真机限制：本轮未完成 LiveKit 通道连接或语音验收。伙伴列表与设备清单上游读取被拒绝，无法选择伙伴；只读检查时 LiveKit 服务处于重启状态。未改主机配置或重建授权来绕过此问题。
- `before.json` 是 APK 安装后、进入对话前的快照，不能被表述为 APK 安装前快照。首次旧 IP 采集超时，随后使用解析地址完成采集。

证据：[检查结果](current-claim-authority-20260920/checks.json)、[会话检查前](current-claim-authority-20260920/before.json)、[检查后](current-claim-authority-20260920/after.json)、[真机诊断](current-claim-authority-20260920/diagnostics.png)。
