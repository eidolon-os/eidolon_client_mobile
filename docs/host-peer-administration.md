# Host 多 mobile 平等管理

Host Identity 独立于管理手机。每个 mobile 安装实例持有自己的 Controller 密钥，Host
为其签发独立的 `host_admin` Grant。所有有效管理员平等；最早加入、邀请者和受邀者
没有权限差别。邀请者退出不影响受邀者。Host 的 Owner Domain、Workspace、Companion、
记忆和外设准入不属于 Controller Grant 生命周期。

## 状态与权限

- `claim_state=claimed` 仅汇总“Host 有有效管理员”，不表示独占，也不阻止添加其他手机。
- Setup 窗口控制是否可新增授权，与已有管理员认证互不依赖。开发常开窗口遵循 Host 的既有策略。
- Setup 码只负责登记管理员；持有 Setup 身份不允许 configure、confirm 或 rollback 网络。
- 新增授权不依赖 Wi-Fi 已连接。新增后仍须完成私钥 challenge 签名，才能操作网络。
- BLE 和 LAN 共用 Grant 权威及撤销规则。BLE 能在 Host 离线时工作；LAN 需要地址可达。
- Grant 创建、窗口消费是原子事务。重复提交恢复已有有效结果，不重复创建授权。

## mobile 接入

1. 发现 Host 并验证签名身份及 TLS pin。没有 Setup 窗口的 Host 也参与发现。
2. 优先验证本机已有 Controller 密钥；成功后恢复本机 Host 记录，不要求输入 Setup 码。
3. 没有授权时，通过有效 Setup 码添加当前手机；不影响其他手机的授权。
4. 将授权成功对应的 Host 记录立即保存，再建立管理员会话。
5. 按需设置 Wi-Fi，可保留当前网络或稍后设置。首次配置与换网复用同一 configure → confirm 流程；确认失败请求 rollback，Host 的检查点仍提供超时回滚。
6. 分别呈现授权完成、网络配置完成、业务连接可达。手机无需先加入目标 Wi-Fi；局域网不可达不能推翻前两项事实。

同一 Host 同时只允许一个网络事务，沿用现有 operation ID 与活动事务约束。
各管理员权限相同，均可对已知的活动 operation ID 确认或回滚；不引入主手机或事务租约。

## 删除、撤销与恢复

| 动作 | 效果 |
| --- | --- |
| 从本机列表移除 | 清理本机记录，不清除 Controller 密钥，不改变 Host 授权；重新发现后可恢复 |
| 撤销一台管理手机 | 该 Controller 后续请求和会话重验被拒绝；其他管理员继续使用 |
| 用新邀请重新添加被撤销的同一密钥 | 明确重新授予该身份管理权限；旧已消费 Setup 凭据不能用于恢复 |
| 手机重装、密钥丢失 | 通过另一管理员邀请或 Host 本地 Setup 码新增该安装实例的授权 |
| 撤销全部管理员 | 显式 controller-reset；普通恢复不会调用它 |

保留最后一个管理员保护：普通撤销不能留下零个管理员；显式 reset 负责全量撤销并开放恢复入口。
恢复单个手机不修改 Host Identity、Owner、伙伴、记忆、设备归属或 Wi-Fi。
重新授权同一密钥表示重新信任该 Controller 身份，不新增一套并行的授权版本模型。

## 验证与交付

回归覆盖离线添加两个管理员、双方配网、旧授权恢复、窗口开放时删除重加、配网失败保留授权、
Setup 身份拒绝网络操作、同一 BLE 链路内新增授权后密钥验证、单个撤销及新邀请恢复。

本次删除旧的 initial_network 分支和 already_claimed 拒绝码。mobile 与 Host 应一起发布；
不保留旧的“先联网后授权”协议路径。已有有效 Grant 和 Host 身份不需要重置。

2026-10-09 验证结果：mobile 全量测试 1224 通过、8 跳过，Flutter analyze 无问题；
Host Bootstrap 及关联管理员 API、设备准入、NetworkManager 和 Local API CLI 测试共 138 通过；
Android debug APK 构建成功。

## 已有 Host 升级

SQLite schema 9 → 10 在新 Host 服务首次启动时自动完成，仅一次性把历史 initial_network
标签归一为 change_network，不删除授权或重置 Host；拉取代码后无需手动执行 SQL 或重新认领。
mobile 应保留应用数据覆盖安装。

通过 Ops 发布时，先备份已有组件数据，再使用 `deploy --activate --cutover-mode forward-only`。
发布器会拒绝跨 Bootstrap schema 的普通可回滚发布，不能只切回旧代码读取已升级数据库。
有线发布不要求先配置 Wi-Fi；未联网时应用就绪检查可能无法完成，需由 mobile 配网后验证业务连通性。

## 部署后验收（2026-10-10）

- opi5max 本次升级版本为 `rk3588-peer-admin-20261009-2`（Admin `aa88486`），数据库为 schema 10。
  初次发布时 Channel/Channel Provider 健康检查超时；用户通过 mobile 配网后，本轮 Ops
  `doctor` 返回 `healthy`。最新 `change_network` 事务为 `succeeded`，2 条有效授权均为
  `host_admin`。平板实机打开管理页显示该发布版本和“已安全连接”，可以读取伙伴和记忆概览。
- 单机删除重加实测通过：从本机移除 opi5max 后重新发现并添加，未输入新的 Setup 码；
  回到 `eidolon` 网络后点击重新连接，显示“已安全连接”，可读取 3 位伙伴、11 条记忆、5 台设备。
  验收时其他任务已将运行版本更新为 `rk3588-c10-b160-20261010-1`，保留上述 Admin 修复。
  Host 仍有原先 2 条有效管理员授权，创建日期仍为 9 月 8 日和 9 月 15 日，reset epoch 均为 0。
- Mac Host 在标准组件备份完成后重启，schema 9 自动升到 10；升级前后 4 条 Controller
  授权的整表校验摘要一致。`doctor` 返回 `healthy`，管理页面 9001 返回 HTTP 200。
- 最新 mobile 联合回归 70 项通过，覆盖添加、删除恢复、LAN 发现、管理员会话和设备配网恢复；
  Host 平等管理员专项 3 项通过（包含内存/SQLite 两种存储）。
- 本轮未由运维命令配置 Wi-Fi，也未手动修改 Host 数据库。当前平板和 opi5max 同处
  `10.242.98.0/24`；未重新执行“手机与目标热点不同网”的整段实机配网，不能用当前连通性代替该验收。
- 用户确认暂时没有第二台 mobile，双 mobile 同时管理的实机验收暂缓；对应授权与网络权限
  行为已由自动化覆盖，不将其记作双设备实测通过。
