# Claude 单会话允许 / 拒绝真实验收

## 环境与范围

Claude Code 2.1.195，已安装的 Agent Notch Release（主回合迟到子任务修复版），
本机 ad-hoc 签名，非公证发行。主二进制 SHA-256：
`171d9d47e578bad75babc507a13ea3bffb8793354bac73974515b40cd8f88083`。

临时目录中的测试脚本只有两个分支：`allow` 和 `deny`，分别创建对应执行标记，
输出固定验收字符串。不读写项目、用户文件、网络或凭据。
只在本次 Claude 子进程设置 `NOTCH_APPROVAL_MODE=ask`，并用临时 CLI settings
对这个脚本要求审批；全局默认仍为完全信任，未编辑任何持久化 Hook/审批配置。
刘海菜单因此仍显示全局默认“完全信任”，但本回合的实际请求是人工审批。

一次非交互 `--print` 尝试直接返回工具未授权，没有出现刘海的 PermissionRequest。
该尝试不计为 UI 审批验收。以下结果来自同一个真实交互 CLI 进程和会话的两个连续回合。

## 允许一次

- UTC `15:08:47.403`：Bash 请求进入真实 JSONL。
- 刘海自动显示“需要审批”，命令精确对应临时脚本的 `allow` 分支，具有拒绝、允许一次按钮。
- 点击前执行标记不存在，真实 Hook 进程仍阻塞。
- 从原生 UI 点击“允许一次”，`15:09:34.436` 的 `hook_permission_decision` 为 `allow`，
  `toolUseID` 与原请求完全相同。
- `15:09:34.637` 的对应工具结果 `is_error: false`，输出
  `PERMISSION_ACCEPTANCE_allow_EXECUTED`，执行标记出现。
- `15:09:35.134` 最终回复 `ALLOWED`。
- 原生诊断记录 `PermissionRequest` 工作中 → 等待审批，随后
  `interaction.approved` 等待审批 → 工作中，再由 Stop 转为等待输入。
  完成后待处理审批 0、JSONL 监听器 0；迟到 SubagentStop 被忽略。

## 拒绝

- 同一进程和会话的新回合，`15:10:22.471` 请求临时脚本的 `deny` 分支。
- 刘海审批卡展示新命令，不再指向上一轮 `allow` 请求；从原生 UI 点击“拒绝”。
- `15:10:50.329` 的决策为 `deny`，`toolUseID` 与新请求完全相同。
- 同时对应工具结果 `is_error: true`，内容为 `Denied by user via Agent Notch`。
  `deny` 分支的执行标记始终不存在，没有重试或其他工具调用。
- `15:10:50.938` 最终回复 `DENIED`。
- 原生诊断记录 `interaction.denied` 清理该请求，随后 Stop 转为等待输入。
  待处理审批 0、监听器 0，迟到 SubagentStop 被忽略。结束后正常退出测试 CLI。

## 可重复检查与自动化边界

新增 `scripts/verify-claude-permission.py` 只读核验该隔离会话的 JSONL：
两轮命令、目录和会话归属、请求 ID、PermissionRequest 决策、工具结果、最终回复、
发生顺序，以及允许执行 / 拒绝不执行的标记。报告不包含原始会话 ID、命令或路径。
本次真实日志检查返回 `passed: true`。

使用方式（替换为自己的隔离测试参数，不读取无关会话）：

```sh
python3 -B scripts/verify-claude-permission.py \
  --transcript /absolute/path/to/isolated-session.jsonl \
  --session-id YOUR-ISOLATED-SESSION-UUID \
  --fixture-dir /absolute/path/to/isolated-fixture
```

检查器有 12 项反例/正例测试，包含跨请求回写、跨会话/目录、重复 ID、错误决策/结果、
乱序/缺失/重复事件、错误命令、拒绝后意外执行、非法消息形状及标记符号链接等。
加上已有问题验收检查器，`scripts/tests` 共 17 项。检查器本身不生成请求、不点击界面、不模拟生产回写，
因此其通过不能替代上面的原生 UI 和真实 CLI 证据。

本轮没有覆盖审批超时、同会话同时挂起的两个请求、双会话并行、重启中挂起审批、
CodeBuddy 或刘海动画逐帧表现。验收矩阵仍保留这些待验证项。

后续补充已覆盖双会话同时待审批并分别允许/拒绝，以及应用侧无人应答超时清理。
原生审批回退可操作性、同会话 FIFO 和其他限制仍未确认。
新增并行模式与 11 项测试，verifier 总数变为 28；详见[并行与超时验收](2026-10-08-parallel-permission-acceptance.md)。
