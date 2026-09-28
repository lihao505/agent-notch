# 生命周期真实验收记录

日期：2026-09-28

版本：Agent Notch 0.9.0，本机从当前源码构建的 Release，ad-hoc 签名；不是公证发行。

## 本轮证据

- 隔离夹具：在 App/SessionStore 启动前写入正在运行的 Codex rollout，周期检查间隔设为
  30 秒；启动后立即发现并进入 `processing`，裁决为 `codexDiscovery / discoveredActiveTurn`。
  夹具不读取用户真实会话目录。
- 轮换夹具：固定父目录修改时间，删除旧 rollout 路径并创建替代路径；完整解析和发现轮询
  均能找到新路径，不再依赖目录修改时间必定前进。
- 安装态：先通过应用菜单退出旧版，确认进程与本地 socket 消失；安装签名后的 Release，
  主二进制与签名后的构建产物 SHA-256 均为
  `6691415bcb6f30d63c1657bcfd861fec616b8e729b675266133638724a19de75`。
  在当前 Codex 回合进行中启动 App，原生辅助功能树看到任务“工作中”；诊断设置页可访问，
  显示桥接正在监听、Codex 活动会话和最近裁决，安装态截图未见截断。
- 这次安装态回合同时出现 Hook 与原生发现证据，不能据此把状态恢复归因于纯原生发现；
  更不能外推到 Claude Code、CodeBuddy、权限回写或真实物理中断。

## 真实回合矩阵

| 场景 | 当前结论 | 缺少的证据 |
| --- | --- | --- |
| 1. Codex 回合先运行、再启动 App | 部分通过 | 已看到“工作中”；还需无新 Hook 的真实工具中途启动与耗时测量 |
| 2. Codex 快速连续两轮 | 未执行 | 旧完成/中断与新回合的真实时间线 |
| 3. Codex 工具及子 Agent | 未执行 | 工具、子 Agent 与完成态的真实顺序 |
| 4. Claude Code 正常回合 | 未执行 | Hook、Transcript、Stop 对齐 |
| 5. Claude 回合中重启 App | 未执行 | 恢复任务及 watcher 状态 |
| 6. Claude PermissionRequest | 未执行 | 允许、拒绝、超时的精确请求回写 |
| 7. Claude 同会话双请求 | 未执行 | FIFO 展示与处理后的卡片一致性 |
| 8. Claude 双会话并行请求 | 未执行 | 无跨会话回写 |
| 9. Claude 中断后快速新回合 | 未执行 | 旧 interrupt 被拒且新 watcher 保持工作 |
| 10. 关闭问题自动展开 | 未执行 | 问题、普通批准和计划审查的各自行为 |
| CodeBuddy（Experimental）对应矩阵 | 未执行 | 独立完整回合，不能宣称稳定支持 |

本轮自动化闸门：238 项 Swift、79 项 Bridge、5 项 verifier 测试通过；Debug 和 Release
无签名构建、发布脚本通过。自动化与安装态观察均不替代上表尚未执行的真实回合。
