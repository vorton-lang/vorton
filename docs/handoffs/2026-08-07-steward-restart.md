# Repository Steward 重启恢复点（2026-08-07 09:47 +09:00）

> 本文件是用户重启 Codex 桌面软件前的耐久恢复点。恢复工作时先完整读取
> `AGENTS.md`、`docs/workflow.md` 与 `.agents/skills/steward/SKILL.md`，再按本文核验
> Git/进程/证据状态；不要把本文记录的运行中或失效样本当作通过证据。

## 用户当前优先级与授权

1. **先清零 critical**：当前先完成 audit #268/#269，再完成 #260。B176 剩余完整
   baseline 与 B180 必须等这些 critical 清零后恢复。
2. critical 清零后，工具链性能仍是第一优先级：完成 B176 → B180，不先做其他发布
   feature 或非 critical backlog。
3. 项目尚未发布；已批准的 breaking change 应采用最简单的原子 clean break。不要为了
   向后兼容增加 alias、双 ABI、兼容 shim 或旧路径。
4. 用户要求持续推进，不在普通执行边界停下等待确认。discussion 任务可能提交文档，
   不会碰源码；保留并正常集成，不要回滚。
5. 对外与 agent prompt 只使用正面、准确的项目描述：Ring-lang 是编程语言编译器、标准
   库与本地构建/测试实现；不要引入无关话题。

## Main 与远端状态

- 工作区：`C:\Users\Yufeng Ying\Desktop\Ring-lang`
- `main`：`4b89c7004e86ac6c2e2d1f08c364fd1cb9009c5a`
- `origin/main`：`32eeb7306184e1dbc82cfcd7715ba692835497c8`
- 记录时 main tracked worktree clean，本地领先 1 个提交；`4b89c700` 尚未 push。
- 用户在 2026-08-07 表示 GitHub CI 已恢复。此前 Actions 服务降级期间没有继续 poll/rerun。
  重启后先用 GitHub API/CLI 核对官方状态和先前异常 run，再 push/rerun；远端验证可与
  critical 本地实现并行，但不得再次取代 critical 主线。

Main 上已落的相关耐久提交：

- `6e15d54` `docs: adopt pre-release clean-break policy`
- `7fd228d` `docs: remove pre-release io compatibility alias`
- `32eeb730` `docs: add pre-release break review gate`
- `4b89c700` `refactor(runtime): remove unused list clone shim`
- Json #260 Stage A 已通过 merge `bb9ae18` 进入 main（实现提交 `5f8f4ce`）。

## B176 continuity unit（代码完成，完整 baseline 冻结）

- Worktree：`.worktrees/b176-phase-timing`
- Branch：`codex/b176-phase-timing`
- HEAD：`9aed3a85ef434e385ba0e04aa8065fb937bf0898`
- 记录前最后一次核验：tracked clean；`ring.exe` 5,512,704 B，SHA-256
  `a8ce79a6b598ab0d34ddadd797f69d70b4fb93b0eac74db4ff9755844aa7c480`。
- B176 尚未 final review、尚未合入 main、尚未生成 `docs/performance-baseline.md`，因此不得
  标记 backlog complete。

关键提交：

- `719c99ff`：关闭 phase timing / harness 旧 review 的主要证据缺口。
- `a35388d9`：固定 Windows `git archive -c core.autocrlf=false` 字节身份并把检查前置。
- `9d2235af`：把 checker 实际消费的 11 个 `std/*.ring` 绑定为逐文件 Git/archive 身份，
  复制到 neutral `stage/std`，避免 subject source tree 成为隐藏输入。
- `9aed3a85`：clean break 把不唯一的 `filtered_e2e_hello` 改为
  `filtered_e2e_bool_ops`；真实 runner 恰好 1 pass，旧 lane ID 未保留。

已验证实现事实：

- bench/check 72/72，native matrix 实际执行、0 skip；Python compile 与 diff-check 通过。
- compiler fixed point：`compiler/dist-c/main.c` 15,524,067 B，SHA-256
  `88d3cd51935add505453714c5f660d66f8b5a5ddd900ac8e4df7ef21e9184d34`。
- 候选 compiler/main source check 曾自然通过；同一 product/compiler snapshot 的完整本地门
  曾得到 1551 pass / 1 skip。该次 ignored raw 后来被误删，不能声称为仍可读附件；最终
  合入最新 main 后必须重新跑 combined fixed point 与完整本地门。

最终 disabled-default-path 强门禁：

- 路径：
  `.worktrees/b176-phase-timing/bench/check/results/b176-disabled-path-gate-9aed3a85-formal-03`
- `evidence.json`：153,570 B，SHA-256
  `41c4e44ad7f36b3a6b6ec474ce018076b83de1f0b775e1f3771da8dad8e818db`
- checked-in verifier 独立重算 PASS；5 warm-up pairs + 41 measured AB/BA pairs，92/92
  exit 0、无 timeout、无 measurement error、stdout/stderr 契约精确。
- median candidate/base ratio `1.0010129902406768`；median delta `+91,300 ns`；阈值为
  ratio `<= 1.02` 且 delta `<= 2,000,000 ns`。
- 成功后 heavy stage 已按契约清除；bundle 209 files / 154,061 B，必须保留。

最终 formal baseline wave（**部分完成后冻结**）：

- 路径：
  `.worktrees/b176-phase-timing/bench/check/results/b176-formal-baseline-9aed3a85`
- warm-seed receipt：SHA-256
  `d0b6fc3f6651acfb14cbc156f5c4b6cf16741673ce5a8c0e13bce02b2ef1e20f`
- manifest：SHA-256
  `9a24c59cb592f9c560626ae6e142e4e5d4391a3fba06fde49b578f1faa39fd38`
- seed inventory：3 files / 8,507,141 B，canonical SHA-256
  `f8a1210231992706c4f0057b80122fb236ee54699f115e12960482dde1ae49a8`。
- `01-direct-cold` 与 `01-direct-warm` 完成：每状态 126 included + 6 warm-ups，所有 RSS
  complete、measurement errors empty。
- `02-compiler-cold` 完成：6/6 included；`compiler_main_check` median
  `441,470,523,800 ns`，`compiler_main_rc_check` median `444,830,173,100 ns`。
- `02-compiler-warm` 在写本文时仍由 cell 544 运行。root 为响应重启请求已在同机执行本文的
  Git/文件 I/O，因此即使 cell 544 随后自然结束，这一 warm batch 也视为受到外部活动干扰，
  **不可计入、不可续算、不可自动重试**。重启后不要从文件数量或进程退出推断成功。
- 用户已纠偏：无论 warm 是否完成，都冻结 B176 baseline，不启动 03-aux 或后续
  e2e/golden/RC/self-compile/full-gate，不 combine、不写 baseline doc，直至 critical 清零。

保留但不得复用的诊断现场：

- `b176-disabled-path-gate-a35388d9-formal-01`：neutral std 缺失导致 `print` undefined。
- 更早 `719c99ff` formal attempt：Windows archive CRLF 改写导致 blob identity 失败。
- `b176-formal-baseline-9d2235af`：旧 manifest wave；`hello.ring` filter 同时匹配正例与
  `diagnostic:clean-check-llm`，actual pass=2 / contract pass=1，已 fail-closed。
- 这些目录以及 `b176-followup-validation`、formal-03、新 wave 都位于被忽略的
  `bench/check/results/`。**禁止对该父目录或其子项使用 `git clean`**；即使给精确 pathspec，
  Git 也可能折叠 ignored parent 并删除整个 `results/`。需要清理时先停下重新定界，当前阶段
  不清理任何证据。

## Critical #268/#269 ownership truth

- Worktree：`.worktrees/ownership-truth`
- Branch：`codex/ownership-truth`
- HEAD：`102495371cfc97f9e5bd737ed067b399d74fde07`
- Base：`0c80598914a7d58210ba02bef7b94f49b6da6f8a`
- 最后核验 worktree clean；独立 reviewer 对 exact
  `0c805989..10249537` 给出 APPROVE，无 finding。
- **Unit 1 不得单独 merge**：当前只是 ownership metadata transport，equality/unification/
  lowering 尚未消费 ownership 行为。

耐久提交：

- `fb9bd2b381c1a39e2181eaf934dd0e5ccfe479d9`：shadow ownership metadata transport。
- `6370a047255743c554a36d0f332dd32cd2669683`：修复 callable ownership identity transport。
- `102495371cfc97f9e5bd737ed067b399d74fde07`：delegate wrapper 严格复用 exact DefId；缺失
  impl/scheme/DefId/callable type 均 fail loud，无 fresh/name fallback。

已定设计：

- 动态 callable descriptor 使用规范内容派生的稳定负 `Int`；固定模式必须归一到 `0..10`。
  不得依赖 Map 顺序、DefId、路径、进程 hash seed 或有 UB 的 overflow；本地 intern、module
  merge、最终 HIR union 三处不同内容碰撞均 fail loud。
- `OwnershipShape` 增加 `direct_drop`，且 `direct_drop => may_own`；只认权威 builtin Drop
  trait identity。codegen impl scan 只能做迁移期 assertion，不能成为第二真值。
- 最终实现必须删除 legacy direct-drop/block moved-name/callee-name guesses，完成 symbolic
  solver -> shape fixed point -> 临时 CFG dataflow -> 显式 HIR `Take`/源槽置空，并覆盖
  direct/method/fn-value/HOF/trait/reexport/SCC/branch/loop/closure/container/Drop 测试矩阵。

与 B176/latest-main 的已知集成边界：

- `compiler/compiler_mod.ring` 两处 `HParam.is_mutable` 读取需改用 accessor。
- 同文件重建 `HProgram` 的位置需传 `ownership_metadata`。
- 先让 B176 continuity unit 通过最终双 review，并合入/重生最新 main anchor；随后 merge 最新
  main 到 ownership branch，由 root 精确处理上述 3 处，再跑 candidate/fixed point。
- 表示 A/B gate：FnMeta heap 对比 flat 4-slot，main workload
  `check compiler/infer.ring --error-format=llm`，2 warm-ups + 7 alternating AB/BA pairs，严格
  output、wall + peak WS；这是 critical 实现选择所需证据，不属于恢复完整 B176 baseline。

## Critical #260 Json

- Worktree：`.worktrees/audit-260-json-trait`
- Branch：`codex/audit-260-json-trait`
- HEAD：`5f8f4ce4d00ddb8211d6dd42e1681ea3e06d9944`
- Stage A 已进入 main：公开 API/规范的第一阶段修复完成。
- 完整 atomic cutover 仍待做：Json derive/runtime ownership 收口并删除旧
  `ring_json_stringify` native runtime。不要在完整切换前单独删除 runtime；也不要增加兼容
  alias/shim。

## 新缺陷候选 #270

Delegate 非-self `mut` 参数没有写回。最小复现中先调用普通 `write(value)`、再调用
`outer.write(value)`，实际最终值为 `1`、预期 `11`。暂定 medium correctness，不得混入
ownership DefId transport unit；B176 合入后由 root 按 `docs/audit-report.md` 格式立案，排在
critical 与 B176/B180 主线之后，不加兼容 shim。

## 冻结 worktree

`.worktrees/audit-268-transitive-drop` / `codex/audit-268-transitive-drop` 位于
`c4cbfc6d9c079d247fcf443054dc99ab23dd357d`。这是旧失败方案，保持冻结；不得 merge、remove、
patch 或作为 ownership 真值。

## 重启后的精确恢复顺序

1. 完整读取仓库与 steward 指令。
2. 只读检查 `git status`、所有 worktree HEAD、main/origin 差异，以及 Ring-lang scoped
   `python.exe`/`ring.exe`/`clang.exe`/`lld-link.exe` 进程。若 cell 544 被中断，只按精确
   executable/command/parent 定界；Job Object 正常应在 owner 退出时清理整棵进程树。不得用
   broad kill，也不得把后台完成/timeout 当证据。
3. 核对 GitHub Actions 已恢复；push main 当前领先提交并处理先前异常 run。远端 CI 与本地
   critical 可并行。
4. 对 B176 exact `0c805989..9aed3a85` 发起两个独立 final review：
   - harness reviewer 复核旧 7 项 finding、formal-03、Job/Schema/provenance/neutral std/
     unique filter；
   - compiler reviewer 复核 disabled lazy path、controlled failure、native/fixed point 与
     formal-03 overhead。
   本次只批准 continuity unit，不声称 B176 baseline 已完成。
5. review 通过后，把最新 main 合入 B176 branch；精确解决 source/runtime 冲突，从合并后的
   Ring source 重生 `compiler/dist-c/main.c` 两次并要求 byte fixed point，跑一次完整本地门，
   再合入 main。不要手工保留旧生成 C。
6. 立即把最新 main 合入 ownership branch，处理 `compiler_mod.ring` 3 个已知边界，完成表示
   A/B 与 #268/#269 的 solver -> shape -> CFG/Take 原子切换；通过独立 review、fixed point、
   完整本地门后一次合入。
7. 完成 #260 Json derive/runtime 原子清理并删除旧 runtime 路径。
8. 三个 critical 清零后，回到 B176 新 wave：运行前重新决定现有 partial warm 是否因重启/
   主机干扰而整体作废；继续时必须使用 clean HEAD、相同 manifest/ring/seed 身份和 fresh
   non-overlapping batch。完整 combine/doc/review 收口后进入 B180 2x。
