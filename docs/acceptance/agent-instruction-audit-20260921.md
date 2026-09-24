# AGENTS 与 Skills 指令审阅及修订

2026-09-21。用户明确要求直接修改，然后继续开发。

## 范围与结论

重点审阅实际使用的项目 AGENTS、用户提供的工程原则模板，以及影响
自主执行/澄清/审批/完成的 10 个本地工作流 Skill。不是对所有插件的穷尽审计。
未改系统/开发者指令、插件缓存、凭据、权限配置或生产服务。
`/Users/mason/.codex/AGENTS.md` 是空文件，未凭空写入全局规则。

核心问题不是缺少更多流程，而是技能中的绝对规则与 AGENTS 已有的按风险
执行原则冲突。此次修改复用已给出的授权，保留真正的审批和验收边界。

修改前完整备份：`/Users/mason/.codex/instruction-audit-backup-9UPSnm/`。
下列原文均来自该备份；当前文件已修订，不再包含全部旧表述。
技能路径前缀为 `/Users/mason/.codex/skills/`。

## 优先问题、原文及已实施修改

### 1. 高：任何改动都重走设计审批，批准后还要再批一次

文件：`brainstorming/SKILL.md`。
原文：“This applies to EVERY project regardless of perceived simplicity.”；
“you MUST present it and get approval.”；书面规格阶段又要求
“Wait for the user's response.” / “Only proceed once the user approves.”

影响：一个明确的小修复也可能经过方案、分段确认、书面规格确认；已经批准的
开发在恢复上下文后又重新等待。与 AGENTS 的“小改动不需要独立审批”相冲突。

已修改：仅对未解决的实质设计选择使用该流程；复用已批准决定；一次连贯审批，
不按段和文件重复确认；已要求实现时直接继续。

### 2. 高：验证必须在同一条消息重新运行，导致审阅循环重复测试

文件：`verification-before-completion/SKILL.md`。
原文：“If you haven't run the verification command in this message, you cannot
claim it passes.”；“RUN: Execute the FULL command (fresh, complete)”。
对照 `subagent-driven-development/SKILL.md`：“Do not ask a reviewer to re-run
tests the implementer already ran on the same code”。

影响：实现者、协调者、审阅者重复完整构建，哪怕代码、环境和结果未变。

已修改：检查实际日志、退出码、修订/文件哈希和配置后可复用证据；代码、环境、
覆盖或风险变化才重跑相应检查。仍禁止把代理口头报告当验收证据，仍区分
单测、签名构建、安装、真机交互、线上服务和商店审批。

### 3. 高：任何测试失败或缺失依赖都要求立刻找用户

文件：`executing-plans/SKILL.md`。
原文：“STOP executing immediately when: … Hit a blocker (missing dependency,
test fails, instruction unclear)”；“Ask for clarification rather than guessing.”
另见 `using-git-worktrees/SKILL.md`：“If tests fail: Report failures, ask whether
to proceed or investigate.”

影响：正常调试被当成审批点；无关基线测试失败也让全部开发停住。

已修改：先自行诊断、修复范围内回归，记录无关基线失败并继续不受影响的工作。
涉及发布门槛的真实失败仍阻止对应发布，不伪称全套通过。

### 4. 高：规划要求先写完整代码，并额外询问执行方式

文件：`writing-plans/SKILL.md`。
原文：“Complete code in every step — if a step changes code, show the code”；
“After saving the plan, offer execution choice”；“Which approach?”

影响：实现前重复写一遍实现；用户已说“继续开发”仍被执行方式选择挡住。

已修改：计划只需目标、文件、接口、行为、验收和风险；按可验证交付切片，
不强求完整代码。已授权开发则自动选可用方式继续；仅规划请求才止于计划。

### 5. 高：把流程违规变成删除工作成果

文件：`test-driven-development/SKILL.md`、`writing-skills/SKILL.md`。
原文均包括：“Delete it. Start over.”；“Delete means delete”。
后者还规定每个修改“5+ reps per variant”以及不得批量修改技能。

影响：测试后补或文档小修可能导致不必要重写；强制代理测试又产生多轮开销。
删除指令还容易触及用户已有变更。

已修改：保留行为测试优先和有意义的 RED/GREEN；已有代码补回归并安全验证
测试能发现缺陷，不把删除作为惩罚。文档/生成代码/视觉改动采用匹配的检查。
技能改动按风险验证，相关修订可批量评估；不自动推送或发布。

### 6. 高（安全）：只按目录名判断工作树可删除

文件：`finishing-a-development-branch/SKILL.md`。
原文：“If worktree path is under `.worktrees/` or `worktrees/`: Superpowers
created this worktree — we own cleanup.”

影响：目录命名不能证明来源或授权，可能误删其他任务/用户成果。

已修改：检查实际创建记录、明确清理范围以及未提交/用户数据；无法证明则保留。
这是加强安全，不是取消必要确认。分支收尾也不再强制弹出四选一来中断已授权安装。

### 7. 中高：可用工具与可用代理容量混淆，缺少本地回退

文件：`subagent-driven-development/SKILL.md`。
原文：“Dispatch fix subagent with specific instructions”；
“Don't try to fix manually (context pollution)”；必须每任务使用新代理。

影响：代理名额耗尽时无事可做；过细切片导致大量上下文和审阅往返。

已修改：按可验证交付切片；无容量/无工具则本地继续并明确审阅独立性限制。
明确要求独立审阅的发布门槛仍保留，不能把自审说成独立审阅。

### 8. 中：1% 相关性触发无限技能链

文件：`using-superpowers/SKILL.md`。
原文：“even a 1% chance a skill might apply … ABSOLUTELY MUST invoke”；
“BEFORE any response or action”。

影响：先读大量流程才能回应或检查一个文件；无关技能触发更多强制步骤。

已修改：使用用户点名或任务明确匹配的最小技能集合，完整读取选中技能；允许先
简短告知进展，不扩散到无关流程。不会覆盖宿主更高优先级的技能要求。

### 9. 中：AGENTS 原則正确，但冲突处理与“阻塞”定义不够可操作

文件：`/Users/mason/Downloads/Codex工程开发原则/AGENTS.md` 与当前项目
`/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone/AGENTS.md`。
原文：“If a local skill introduces a conflicting pause or approval rule,
identify its source and reconcile it with the user's existing authorization…”；
“At a genuine blocker, report what is blocked…”

影响：没有明确如何复用批准、何时继续排查；代理可能把“协调冲突”理解成再问用户。

已修改：两份文件同步加入执行/审批决策规则、工具不可用的回退、证据复用、
基线失败与回归的区别，以及以请求的用户可见成果作为完成标准。保留项目特有边界。

## 必须保留的安全与审批

- 新的实质产品、安全、隐私、兼容性、费用选择，不能凭“大胆干”臆断。
- 泛化的“继续”不授权新生产变更、凭据操作、外发消息、开支、发布或破坏性操作。
- 同一范围的明确批准无需重问；范围/风险变化仍需判断是否需新批准。
- 保留用户未提交工作、设备身份、收到的文件、手动配对和既定兼容性要求。
- 不能为了通过测试删数据、削弱断言或关闭安全机制。
- 源码/单测/构建不等于已在手机可用，更不等于已上架。

## 验证记录

- 修订前独立六场景冲突审阅：`/tmp/dropmesh-instruction-baseline.md`。
- 10 份技能的 YAML 元数据、名称和代码块配对 Ruby 检查全部通过。
- 官方 quick_validate 已尝试；当前 python3 缺 PyYAML，未改系统环境，采用
  Ruby 标准 YAML 解析替代。不是声称官方验证器通过。
- 项目 `git diff --check` 通过。
- 独立修订后七场景决策审阅通过。发现的两处残留（代理模板旧要求、工作树无条件
  安装/提交）已修订并定向复审通过；四个相关文件哈希写入
  `/tmp/dropmesh-instruction-forward-review.md`。模板在复审期间也发生更新，
  按最新内容重新读取并保留，没有用旧副本覆盖。
- 本审阅不证明所有未来 Agent 行为；它消除已确认的规则冲突并保留安全界限。

## 开发继续

账号自动配对仍按已批准双通道方案推进。原开发代理持续实现账号连接生命周期；
这些规则修改不触碰它的代码、测试缓存或正在进行的测试。真机 iPhone 已再次
检查为 connected；尚不能声称账号自动配对已安装或完成真机验收。
