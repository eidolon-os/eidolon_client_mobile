# Host 关机

入口：进入一台 Host → 右上角「主机设置」→「电源」→「关闭主机」。电源分区位于「管理手机」与「恢复」之间。

点击后确认目标主机名称，并说明会停止所有服务、断开连接，需要开机后才能再次使用。离线、旧 Host、操作系统不支持或特权服务未提供能力时禁用入口并显示原因。请求期间禁用重复操作。

## 接口与执行

- `GET /api/management/v1/host/power` 返回 `can_power_off` 和不可用原因。
- `POST /api/management/v1/host/poweroff` 只接受 `request_id`，返回 HTTP 202、固定 `system.poweroff` 操作、对应请求编号和 `accepted` 状态。
- 两个接口均校验当前 Controller 授权，经带服务凭证的 Admin `/api/host/power`、`/api/host/poweroff` 转发至 System `/api/system/v1/power`、`/api/system/v1/poweroff`；响应不缓存。
- 正式 Linux 配置复用已有特权执行服务：调用方必须属于 `eidolond.service`，目标必须是固定的 `@host`。读取能力不执行命令，实际关机由 root 服务执行固定的 `/usr/sbin/poweroff`（或 `/sbin/poweroff`）。保留 eidolond 的 `NoNewPrivileges` 等现有限制。
- 未配置特权执行服务的 Linux 开发环境使用 `/usr/bin/sudo -n -- /usr/sbin/poweroff`（或 `/sbin/poweroff`）；进程本身为 root 时直接执行。`-n` 防止等待密码，主机需要自行具备相应免密 sudo 权限。本改动不安装 sudoers 规则。
- 当前 macOS 不提供此能力。任何请求都不能指定命令、参数、路径或另一台 Host。

## 结果语义

只有实际命令成功退出，才返回“关机指令已接受”；这不代表已经确认硬件断电。关机可能先切断网络，手机此时显示“结果未确认”，不会将断线判为成功，也不会自动重发。手机校验响应状态、操作名和请求编号。

手机收到接受结果或无法确认的结果后，停止当前管理会话并清理在线状态，保留 Host 记录和本机备注。重新连接需要用户明确操作。主机在当前进程内串行执行，接受后同一编号复用结果，其他编号被拒绝；执行超时后也不再次执行。特权服务接受关机或超时后同样阻止重复调用。

## 上线范围

需要同时更新 `eidolon_sdk`、`eidolon_kernel`（eidolond 及特权执行服务）、`eidolon_admin`（Admin 和 Local API）及手机 App。旧组件没有接口或特权协议时，App 会提示不可用。已安装的正式 Host 需要部署更新后的版本才能使用。

自动验证使用模拟命令，覆盖认证、撤销授权、固定目标、拒绝任意命令、重复请求、超时、丢失响应、移动端确认/取消与旧 Host 兼容。没有通过真实关机来验收，也没有自动部署到在线 Host。

## 本次验证

- System 回归：133 passed、1 skipped。
- Admin 接口与契约生成检查：53 passed（8 条已有 pytest 标记警告）。
- SDK 关机契约：7 passed。
- 移动端完整回归初次为 1007 passed、7 skipped，3 项旧测试依赖“恢复”入口仍在可见区域。改为滚动定位后，关机/设置/恢复相关 27 项复测全部通过。
- Dart 静态分析通过；Android debug APK 构建成功，输出 `build/app/outputs/flutter-apk/app-debug.apk`。
