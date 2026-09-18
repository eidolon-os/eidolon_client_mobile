# Companion 预设：Mobile 收尾记录

更新日期：2026-09-18。

## 结论

模板内容已迁入 Data，Mobile 支持选择模板直接创建，也保留自定义、独立草稿、重试和创建后进入指定伙伴对话。模板来源通过 Mobile → Admin → Data 记入 provenance。

用户已确认 Mobile 真机测试通过。该反馈替代此前“真机只看到旧版三个模板、端到端尚未验收”的状态；未进一步推断用户测试所用 Host、版本或覆盖的异常路径。本次 review 发现的四项问题已修复，并完成下述自动化验证。

## 本阶段范围

- Data 持有四份结构化模板及目录；SDK 保留契约模型。
- 首屏选模板即可创建，名字和详细设定可选调整；自定义走“继续 → 确认”。
- 每份模板及自定义保留各自草稿，返回列表再进入创建页可继续填写。
- 创建期间禁止重复提交；结果不确定时保留 operation ID 和请求体，重试确认同一次创建。明确拒绝会显示原因并允许修改。
- 原样采用模板时记录 `source_preset_id` / `source_preset_revision`，`origin` 为 `template`；改名不算改写人格。创建后保留独立快照，不随模板更新。
- 男女音色配置、选择与试听留到后续章节；当前语音仍使用 Host 的 Channel 配置。

## 本次修复

### Host 重置恢复

设置页读取 Host 实际提供的目录后，调用应用共享目录的信任校验。只有验证得到 generation 回退才显示“以主机当前状态为准”；签名等其他失败不会开放该操作。

确认时重新验证根、签名和有效期，仅覆盖 generation 回退。接受的是确认页对应的那份目录，同时更新内存与所有关联 Host 的持久化目录，保留配对。操作失败会显示反馈并保留恢复入口。

移除 Host 时按 Owner Domain 清理缓存；只有最后一台关联 Host 被移除才清除域的防回退记录。仍有 Host 时保留共享目录与可用路由。信任变更会使在途读取失效，延迟返回的旧目录不能撤销刚完成的恢复。

回归覆盖：同进程移除再添加、共享域保留、确认与取消、保存失败、其他校验失败、根不可替换、重启后的恢复结果，以及在途旧刷新。

### 创建幂等指纹

未声明的新增来源字段不参与新请求的规范指纹。重放时也接受此前短期部署版本写入的含空来源字段指纹；两个候选均由服务端基于同一份请求计算，调用方不能提供候选指纹。返回原始记录的指纹，保留既有凭据的一致性。

回归覆盖两种历史记录，有无回复偏好均可重试；修改名称、偏好或声明来源仍返回 409，不产生第二个伙伴。该处理仅针对已落库请求的幂等记录，不恢复旧模板目录或旧接口。

### 真实网络表单回归

表单测试先进入自定义，再展开回复偏好与试聊区，覆盖试聊、创建、编辑、回读。另补模板卡片直接创建路径，确认默认名、完整人格快照、回复偏好和来源参数。

## 验证结果

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub`：1056 项通过，8 项按运行条件跳过。
- Data：Owner Workspace、Companion provision、模板资源共 51 项通过；修改文件的 Ruff 检查通过。
- 隔离真实 HTTP 测试：Agent 的 `test_actual_flutter_management_client_over_network` 通过，内含 Flutter 客户端生命周期、模板直建、自定义表单三个流程。使用临时数据库和回环端口，不读写正在使用的 Host 数据。
- 两个项目 `git diff --check` 通过。
- `flutter build apk --debug --no-pub`：构建成功，产物为 `build/app/outputs/flutter-apk/app-debug.apk`。本次未覆盖安装，也未部署 Host。

跨项目网络测试从 `eidolon_agent` 运行，Flutter 放入 PATH，并配置：

```sh
PYTHONPATH=../eidolon_admin/server:../eidolon_data:../eidolon_sdk \
EIDOLON_PERSONA_NETWORK_E2E=1 \
.venv/bin/python -m pytest -q \
  tests/e2e/test_persona_network_journeys.py::test_actual_flutter_management_client_over_network
```

本次自动化测试不是本次修复版本的真机验收。用户此前的真机通过反馈单独记录在上方；本次未重置任何实际 Host 的信任或数据库。
