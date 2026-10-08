# Claude 双会话审批与超时清理真实验收

## 环境与边界

Claude Code 2.1.195，已安装的 Agent Notch Release，主二进制 SHA-256：
`171d9d47e578bad75babc507a13ea3bffb8793354bac73974515b40cd8f88083`。
本机 ad-hoc 签名，不是公证发行。本轮未修改或重新安装应用二进制。

每个真实交互 CLI 使用独立临时目录；脚本仅在自己的目录创建 `tool-executed`，
输出固定标记，不读取项目、用户文件、网络或凭据。
只在测试子进程设置 `NOTCH_APPROVAL_MODE=ask`，临时 settings 对精确命令要求审批；
全局默认仍为完全信任，未修改持久化 Hook、审批策略或模型配置。

## 超时清理：应用侧通过，原生回退仍待确认

- UTC `15:20:50.323` 提交隔离提示，`15:20:51.651` 真实 Bash 请求进入 JSONL。
- 刘海显示精确命令及“需要审批”。`15:21:14` 原生诊断为待审批 1、监听 1；
  测试脚本未执行，Hook 进程仍等待响应。
- 原生 Hook 脚本当前预算固定为 90 秒，Socket 在预算后 2 秒清理；不能把通用 Bridge
  的超时环境变量当作该原生脚本的短时预算。
- 未点击允许或拒绝。`15:22:27` 的诊断已变为待审批 0、监听 0，
  `interaction.deliveryFailed` 被接受，等待审批 → 空闲；Hook 进程已退出，脚本未执行。
  该时间是观察时间，不是精确超时回调时间。
- CLI 仍活着，但本次终端输出没有显示可核验的原生 Yes/No 审批提示。
  `15:24:42.087` 手动 Escape 后才得到工具拒绝结果，随后正常退出 CLI。
  没有 `hook_permission_decision`；不能把手动取消归因于超时自动拒绝。

结论：本次证明应用侧不会长期保留无人应答的审批卡或监听器，且未执行工具。
**未证明 Claude 原生审批提示可见或可继续操作**，不将整个回退链路标记为通过。

## 双会话：并存、不同决策、无跨请求回写通过

前两次操作预算内未完成双决策：一次允许 A 后 B 仍独立待审批，随后 B 超时；
另一次两个请求均超时。它们只证明并存/部分隔离，不算完整允许与拒绝验收。
未完成的请求用 Escape 取消。下面结果来自两个相同交互进程各自的新提示回合，
不是重试旧请求；检查器通过明确的新工具 ID 选择完整提示边界，不覆盖前面的失败尝试。

| 事件（UTC） | 会话 A | 会话 B |
| --- | --- | --- |
| 新提示提交 | 15:37:39.230 | 15:37:39.230 |
| Bash 请求记录 | 15:37:40.677 | 15:37:40.851 |
| 刘海会话列表 | 两个精确脚本请求同时显示待审批 | 两个精确脚本请求同时显示待审批 |
| 原生列表按钮 | 点击允许 | A 转为工作中时 B 仍待审批；随后点击拒绝 |
| PermissionRequest 决策 | 15:38:17.053，allow | 15:38:17.942，deny |
| 工具结果 | 15:38:17.250，成功、固定 A 标记 | 15:38:17.942，错误、Denied by user via Agent Notch |
| 最终回复 | 15:38:18.153，A_ALLOWED | 15:38:18.614，B_DENIED |
| 执行效果 | A 执行标记存在 | B 执行标记不存在 |

两者会话 ID、目录和工具 ID 均不同；各自决策与工具结果精确匹配各自请求 ID。
两个工具请求时间都早于任一决策；原生 UI 补充证明它们确实同时待审批，
而非只有工具日志时间重叠。

`15:38:42` 原生诊断为待审批 0、监听 0，两个 Claude 会话均为等待输入。
诊断分别记录 `interaction.approved`、`interaction.denied`、各自 Stop，
迟到 SubagentStop 被忽略，没有重新激活主回合。两个测试 CLI 最终正常退出，exit 0。

## 只读回归检查

复用 `scripts/verify-claude-permission.py` 的会话/命令/决策/结果解析，新增并行模式：

```sh
python3 -B scripts/verify-claude-permission.py \
  --transcript /absolute/path/to/A.jsonl \
  --session-id A-SESSION-UUID --fixture-dir /absolute/path/to/A \
  --parallel-transcript /absolute/path/to/B.jsonl \
  --parallel-session-id B-SESSION-UUID --parallel-fixture-dir /absolute/path/to/B \
  --allow-tool-id EXACT-A-TOOL-ID --deny-tool-id EXACT-B-TOOL-ID
```

主参数对应 A 允许，parallel 参数对应 B 拒绝；脚本名均为 `parallel-tool.sh`。
检查器验证明确选中的整个提示回合，每回合恰好一个请求/决策/结果，无额外工具或重试，
最终回复、目录/会话归属、请求 ID、时间顺序、严格重叠区间及执行标记一致。
缺失/重复 ID、跨请求回写、串行或仅相接区间、错误时间/工具/结果、额外工具、
缺少提示边界、执行标记符号链接和不完整 CLI 参数均被拒绝。
报告不输出原始 ID、命令或路径，并明确排除其他提示回合。
本次两份真实日志返回 `passed: true`。

新增 11 项并行检查测试，连同原有检查器共 28 项；发布闸门也要求审批检查脚本和测试文件存在。
检查器不生成请求、不点击界面，也不证明 UI、超时或同会话 FIFO。

剩余边界：同会话双请求 FIFO、一个请求超时同时另一个仍待审批、审批中重启、
Claude 原生回退可操作性、CodeBuddy、真实刘海动画逐帧表现。
