# Mobile Body 登记恢复：根因、修复与真机验证

2026-09-20。阻塞已解除，保留数据覆盖安装。平板在当前 Pi5 上完成正常准入，原 operational key / device_instance_id 不变；首次连接和冷启动后的第二次连接均成功。最后已结束会话，停在烁烁 / 按住说话 /「开始对话」准备页。实际声音与 BOX-3 表达验收交回原桌面陪伴任务。

## 根因与证据

这是历史 Authority 分叉叠加 Mobile 恢复状态机缺口。不是今天 Data 形象迁移造成的丢记录，也不是 Controller 认证失败。

| 层次 | 实际证据 | 判断 |
| --- | --- | --- |
| 平板 Body | 原 device ID `device-instance-cbaca296ba9f3016de9a5957731288b1272b691d3108091ec3c4e8106f8beec0`；Owner `owner-b0a862b0aab941d64554`；本地 DeviceRef 为 **9 / 1 / 1**（Owner generation / Claim generation / trust epoch） | 密钥仍在，旧 Claim 引用可以被本机读取和签名，但不代表当前主机有这份 Claim |
| 旧完成收据 | `enrollment_6ilETSGQdZSFDTXLCXSL4pUb`，`grant_NNtwMifemnGLbj7tCeSs4056`，ACK `2026-09-10T05:31:49.030684Z` | 是第 9 代的历史接入，不可凭本地收据向第 8 代直接补写授权 |
| 平板可信目录 | 已接受 Owner generation **8** / directory revision **1**；本轮前后完全未变 | 目录信任早已对齐当前主机，Body 检查点却仍停在第 9 代 |
| 当前 Pi5 Hub | `hub_authority_state` 为 generation **8**、`authority-state_LJxSTZE2bamD2OGWCj-2BazBbosGT_AE`；修复前 9 条 Claim、15 条 Proposal，无上述平板 ID / Enrollment / ACK | 恢复查不到是权威事实，不是网络超时 |
| 请求与拒绝 | 日志记录 Configuration pull 拒绝：`device=...cbaca296... generation=9/1/1 code=STALE_GENERATION`；诊断 `DeviceControlRefusal(409): STALE_GENERATION` | 该码在当前 Hub 的这个分支表示没有匹配 Owner+device 的 Claim，不是单纯 Claim generation 太旧 |
| 点击恢复 | 真机实际点击「恢复已有登记」→「核验并恢复」，返回「此主机没有可恢复的已完成登记」 | 恢复只列举当前主机登记；旧板记录不存在，重试也不能创造它 |

历史来源已在 [Pi5 世代分叉调查](../../../eidolon_ops/docs/pi5-owner-generation-divergence-2026-09-16.md) 记录：9 月 10 日另一块新 Pi5 用同一套 Host / Owner 身份安装，建立第 9 代；之后原第 8 代板换回台架。两板曾共用 Host 身份、Owner 根、签名证书及 Hub TLS 身份，所以同名、同 Host ID、证书校验通过，都不能证明两边共享同一份 Claim 账本。现板并未从 9 回滚到 8。

9 月 18 日的 [Owner 授权单一账本实施](../../../eidolon_ops/docs/owner-authority-single-ledger-2026-09-18.md) 已处理 Ops 工作站镜像与换板边界，但没有把平板历史 Body 检查点转成当前 Authority 的登记事实。本轮没有更改证书、目录、generation、Host 身份或 Ops 材料。

实际调用链：正常准备页使用 Body 签名调用 `POST /api/device-control/v1/configuration:pull`；恢复按钮调用 `ClientController.recoverEnrollment → MobileConversationProvisioner.recoverClaim → DeviceAdmissionPort.listRecovery`，经 Controller 认证的 `GET /api/local/v1/device-enrollments` 转发为 Hub `GET /api/admission/v1/enrollments?states=pending_review,approved_awaiting_handoff,grant_delivered,grant_acknowledged&limit=50`。列表按原设备 ID 过滤为零，因此恢复在本地资格检查处终止，没有进入设备证明或保存引用阶段。

## Review：权威归属与缺陷位置

1. **P1：Mobile 把「持有同 Owner 的本地引用」当成直达 Device Control 的充分条件。** `mobile_conversation_provisioner.dart::provision` 原来只检查 Owner ID，不检查该引用与当前可信目录是否为同一 Owner generation。目录 realign 成功后，旧 Claim 继续绕过 Admission 核对，形成永远 409 的路径。
2. **P1：恢复资格和页面动作不闭合。** `product_conversation_page.dart::_actions` 根据 `deviceFactsStale` 就画「恢复已有登记」；`recoverClaim` 却要求当前 Authority 存在已批准、已 ACK 的活动记录。当前权威无记录时，失败保留检查点，下次又走第一条，无法进入正常登记。本地检查点是定位线索，不是恢复资格证明。
3. **P1：配置响应可越过可信目录改写 Owner generation。** 原回归把 Owner generation、Claim generation、trust epoch 一起递进当作普通引用校正；前者是 Authority 边界，后两者可以在同一 Authority 内演进。现在单独校验 Owner generation，一致后才校正 Claim generation / epoch。
4. **待 ACK 边界同样必须隔离。** 旧检查点尚未 ACK 时不能往另一个 generation 重放 ACK。本轮加入明确拒绝并保留记录。

各层职责：

| 模块 | 权威 / 责任 |
| --- | --- |
| Android Keystore | Body operational key；其 SPKI 派生 device_instance_id。Controller 管理凭据是另一份身份 |
| DeviceOwnerDirectory | 验证签名目录、Owner 根及已接受的目录状态；realign 不授予 Body Claim |
| MobileBodyClaimStore | 设备本地检查点，说明「上次持有哪份引用」；不自行证明当前授权 |
| Hub Admission | Proposal / ApprovalDecision / Grant / ACK / Claim 的权威 |
| Device Control | 持有 operational key 的设备证明与当前配置 / 通道；不靠 Controller 登录替代 Body 证明 |
| Admin / Local API | Controller 管理授权和准入决策门面；可读伙伴、改设备不等于平板已成为 Body |
| Kernel | 消费 Claim 后的挂载、Body 伙伴绑定 |
| Channel / Agent | 准入之后的真实会话与音频处理；此次初始 409 尚未到这些层 |

## 修复与状态转换

只修改 Mobile 现有模块，没有新增恢复服务、数据库、身份体系或后台授权旁路。

- 同 Owner、同 generation 且持有完成 Claim：仍直接使用 Device Control，不依赖 Controller 历史队列。
- 已信任当前目录，但检查点 generation 不同：保留检查点，先用原设备 ID 查当前 Authority。
- 当前权威已有活动且已完成的登记：提供原有显式恢复；设备签名核验成功后才保存权威引用。
- 当前权威有未完成登记：回到原准入状态机处理该 Proposal，不另建一份。
- 当前权威成功应答且没有可恢复登记：新状态 `registrationRequired`，明确显示「在当前主机登记本机」；不声称能恢复旧板授权。
- 权威不可用、Owner 不同、响应与可信目录 generation 不同：保持失败，不把未知当作可以登记或已经授权。
- 待 ACK 检查点属于其他 generation：拒绝跨代重放，保留原记录。

现场必要动作是**给原设备身份在当前主机建立一次经过批准的登记**：

`旧板已 ACK 检查点 + 当前 Authority 无登记 → 显示事实 → 用户动作提出 Proposal → pending_review → 明确批准 → collect Grant → durable checkpoint → ACK → active Claim → Kernel 挂载/绑定 → Device configuration → LiveKit connected`

没有把第 9 代的旧 Grant 修成第 8 代，没有导入旧板数据库，也没有通过清数据、移除设备、卸载 App、重建密钥或自动批准来消除错误。旧公开检查点保存在本报告证据中；应用内直到新 Grant/ACK 过程才按原协议更新当前检查点。

改动位置：

- `lib/src/features/conversation/mobile_conversation_provisioner.dart`：检查点与可信 Authority 对照、原有列表分支复用、配置响应 generation 校验。
- `lib/src/features/conversation/mobile_body_standing.dart`：新增可明确登记的状态及事实文案。
- `lib/src/features/conversation/product_conversation_page.dart`：对应操作标签。
- `lib/src/features/device_setup/mobile_body_enrollment_session.dart`：动作映射、跨 generation ACK 拒绝。

## 验证与部署兼容性

Mobile 全量 **1126 passed / 8 skipped**，`flutter analyze --no-pub` 无问题，debug APK 构建通过，`git diff --check` 通过。新增覆盖：跨代检查点保留/重复打开、已有当前登记走恢复、当前 pending 优先、网络失败不变成可登记、跨代 ACK 不重放、配置不能擅自换代、UI 正确动作且无自动写入。原同代 Claim generation/epoch 校正测试继续通过。

APK SHA-256：`823884e688cfe5d85c705193ee649152eabf8a3e7e0ca00d6f020bf833c5a8ee`。已通过 `adb install -r` 安装到 `df331f93`。源代码及脱敏证据随本次收尾提交至本地 main；未推送远端。

Pi5 保持 `pi5-companion-desktop-20260920c`：Hub `87d16a5`、Kernel `c8a2e72`、Admin `209da61`、Data `b06023d`、Channel `1c43d73`、Agent `b07aa5a82268ed2015cbd4849408099df4796784`。没有全量升级或服务端改代码。现部署成功完成准入与两次会话建立，足以排除本次登记阻塞来自该组合接口不兼容；不把此结论扩大成所有音频能力均已验收。

## 真机结果与数据保留

- 原故障通过真实 UI 再次复现，见 [恢复失败](mobile-body-recovery-20260920/01-recovery-failed.png)。
- 更新后读到当前权威无登记，显示 [当前主机登记](mobile-body-recovery-20260920/02-authority-reconciled.png)，原 fingerprint 完全相同。
- 提出后明确停在 [待批准](mobile-body-recovery-20260920/03-pending-owner-decision.png)。选择烁烁 / 按住说话，再点击「确认接入并开始对话」。
- 当前 Pi5 新 Proposal：`enrollment_nISHXc4lPMogc2A1BVyAY6e1`；Grant：`grant_cRLwcL6LrNtUaruD7mE5hEal`；ACK：`2026-09-20T11:05:52.000208Z`；Claim **8 / 1 / 1 active**。
- [首次会话](mobile-body-recovery-20260920/04-session-connected.png)、[connected 诊断](mobile-body-recovery-20260920/05-connected-diagnostics.png)。
- 结束会话、force-stop、冷启动后，[直接准备对话](mobile-body-recovery-20260920/06-cold-start-ready.png)，无需再登记/恢复；再次启动后进入「按住按钮说话」，[第二次 connected](mobile-body-recovery-20260920/07-cold-start-connected.png)。最后已结束会话，麦克风关闭。
- Hub 原 9 条 Claim、15 条 Proposal、9 条设备目录记录逐行保持原值，分别仅新增 1 条平板记录；Authority marker 完全不变。
- BOX-3 仍绑定 `cp_a723362066e34ab8af2d3a0b229532f1`（小禾），revision **5**；原 output policy 保持 speech/expression/audio_cue=true、dialogue_text=false。stackchan 原 Claim 与目录也未变。
- 伙伴总数仍 **7**，默认仍 **Sanjiu**。平板的其他 Owner 检查点及 accepted directory 前后完全相同。

完整脱敏数据：[前检查点](mobile-body-recovery-20260920/before-public-checkpoints.json)、[前权威](mobile-body-recovery-20260920/before-host-public-state.json)、[后检查点](mobile-body-recovery-20260920/after-public-checkpoints.json)、[后权威与请求日志](mobile-body-recovery-20260920/after-host-public-state.json)、[逐行比较结果](mobile-body-recovery-20260920/checks.json)。不含私钥、Controller bearer 或音频内容。

## 交回原桌面陪伴任务

本任务已停止操作平板和 Pi5。平板停在 Pi5 对话准备页，已选烁烁与按住说话，可直接「开始对话」。下一步：

1. 真实说一句话，核对平板麦克风输入、STT、正确伙伴回复、扬声器播放、文字/形象及结束对话后的收音停止。
2. 再测轮流说话与自由对话的打断和停止；用对应会话日志佐证，避免用 connected 代替声音验证。
3. BOX-3 接入实物反馈或串口后，继续原小禾绑定及表达设置验收；无串口/现场反馈时明确保留未验收项。

本轮未声称已经完成听感、实际口语输入、BOX-3 屏幕/扬声器/表情、持续长跑测试。另观察到长时间停在待批准页时原 UI 会显示通道准备超时，但批准按钮仍可用；这是独立的等待文案问题，不是本次恢复阻塞，未扩大修改范围。

## 原任务现场验收与收尾

独立任务交回后，用户在原任务现场验证按住说话的字幕与语音回复、结束并彻底关闭 App 后无需重新登记、切换伙伴后的形象/身份/声音对应，并明确反馈“都验证了。回复正常”。Mobile 真机阻塞已解除。本次验收不包含自由对话打断、BOX-3 物理输出或持续长跑。修复沿用现有准入与设备控制机制，未引入替代授权链路。
