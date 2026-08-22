#!/usr/bin/env python3
"""Validate Ring-lang's durable Repository Steward workflow contracts."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]

BACKLOG_HEADING = re.compile(
    r"^### B-\d{3} .+?\[(?:feature|design-align|refactor|bugfix|infra)\] "
    r"\[P[0-3]\] \[(?:S|M|L|XL)\] \[(?:mechanical|judgment)\] "
    r"\[(?:queued|planning|waiting-feedback|doing(?::[^\]]+)?)\]"
    r"(?: \[[^\]]+\])*$"
)
AUDIT_HEADING = re.compile(
    r"^### #\d+ .+?\[(?:critical|medium|low)\] "
    r"\[(?:mechanical|judgment)\] \[(?:open|doing)\]"
    r"(?: \[[^\]]+\])*$"
)

SKILL_PROVIDERS = (".agents", ".claude")
SKILL_NAMES = ("steward", "discussion", "full-audit")
CODEX_ROLES = ("implementer", "reviewer", "finder", "skeptic")

LEGACY_ADAPTER_PATTERNS = {
    "Agent({": "Claude Code pseudo Agent API",
    "model: opus": "hard-coded Claude model",
    "node compiler/dist/main.js": "retired JS bootstrap command",
    "opencode serve": "hard-coded legacy provider pipeline",
    "feedback 是唯一的信息通道": "one-shot feedback-only reporting",
    "每个已完成的 item 至少应该有一条": "mandatory implementation-log feedback",
    "积极写 feedback——宁多勿少": "high-noise implementation logging",
    "首批向用户展示分组计划": "per-wave user approval gate",
    "approve 后开始": "per-wave user approval gate",
    "不要自动扩大到下一 wave": "one-wave stop",
    "队列或本次授权范围耗尽后": "request-scoped stop",
    "修复本轮 finding 后，必须由用户手动发起下一轮": (
        "manual next-audit requirement"
    ),
    "下一轮需用户手动触发": "manual next-audit requirement",
    "必须等待用户再次触发 Audit": "manual next-audit requirement",
    "不得在任何修复完成后自动复审": "manual next-audit requirement",
    "你是 orchestrator——写 plan + 调度 subagent，不自己写代码": (
        "implementation-pipeline-only root"
    ),
    "Orchestrator 不实现任务": "implementation-pipeline-only root",
}


@dataclass(frozen=True)
class TextContract:
    name: str
    required_groups: tuple[tuple[str, ...], ...]
    forbidden: tuple[str, ...] = ()
    ordered: tuple[str, ...] = ()


MACRO_CHECKIN_CONTRACT = TextContract(
    "low-noise five-part macro check-in",
    (
        ("低噪声",),
        ("当前总门",),
        ("已获得的 durable claim",),
        ("下一道可证伪验收门",),
        ("全局风险",),
        ("需要用户拍板",),
        ("不报告 subagent", "不要呈现 subagent", "subagent/命令等待"),
        ("命令进度", "命令仍在运行", "命令等待"),
        ("原始日志",),
        ("实现流水",),
        ("[决策]",),
        ("[里程碑]",),
        ("[全局阻塞]",),
    ),
    (
        "向用户汇报 subagent",
        "默认汇报 subagent",
        "逐项汇报命令",
        "每个已完成的 item 至少应该有一条",
    ),
    (
        "当前总门",
        "已获得的 durable claim",
        "下一道可证伪验收门",
        "全局风险",
        "需要用户拍板",
    ),
)


ANTI_OVERENGINEERING_CONTRACT = TextContract(
    "roadmap-first anti-overengineering gate",
    (
        ("总路线图最优先目标",),
        ("当前可证伪",),
        ("最小充分",),
        ("恶意攻击",),
        ("虚构应用场景",),
        ("无意义泛化",),
        ("定期 refactor",),
        ("近期不会产生已知",),
        ("修灯泡空难",),
        ("correctness",),
        ("safety",),
        ("ownership",),
        ("真实外部边界",),
    ),
    (
        "默认内部调用者恶意",
        "为未来可能需求先泛化",
        "顺手重构整个仓库",
    ),
)


STEWARD_BEHAVIOR_CONTRACTS = (
    TextContract(
        "waiting-feedback backfill",
        (
            ("持续推进",),
            ("单个 item",),
            ("waiting-feedback",),
            ("不是全局阻塞",),
            ("必须立即补位",),
            ("达到 clean checkpoint commit",),
            ("测试状态与必要 handoff 已持久化后",),
            ("可以释放 worktree",),
            ("保留 branch/commit",),
            ("未达到时保留 worktree 或先 checkpoint",),
            ("只有全部",),
        ),
        (
            "waiting-feedback 后结束当前阻塞链",
            "停止全局工作，等待用户",
            "单个 item 阻塞时停止",
        ),
        (
            "waiting-feedback",
            "达到 clean checkpoint commit",
            "测试状态与必要 handoff 已持久化后",
            "可以释放 worktree",
            "保留 branch/commit",
        ),
    ),
    MACRO_CHECKIN_CONTRACT,
    TextContract(
        "Argument with independent refutation and root verdict",
        (
            ("Argument",),
            ("至少两个真实候选",),
            ("独立 reviewer",),
            ("主动攻击", "攻击推荐方案", "主动反驳"),
            ("root",),
            ("verdict",),
            ("语言公开语义",),
            ("用户保留决定",),
            ("保持现有公开行为",),
        ),
        (
            "root 可自主修改语言公开语义",
            "root 无需独立反驳即可改变语言公开语义",
            "普通工程判断必须等待用户",
        ),
    ),
    TextContract(
        "risk-triggered bounded Audit",
        (
            ("高风险",),
            ("自主触发新 round",),
            ("bounded",),
            ("不得在同一 round",),
            ("loop-until-dry",),
            ("新的执行任务接管",),
            ("同一 trigger",),
            ("未变 snapshot",),
            ("最多一轮",),
            ("新 commit",),
            ("新 lens 证据",),
            ("新的风险事件",),
            ("队列仍空",),
            ("不得仅因",),
            ("返回维护/队列扫描",),
        ),
        (
            "等待用户手动发起下一轮 audit",
            "在同一 round loop-until-dry",
            "循环到 dry 后再结束",
            "同一 trigger 和未变 snapshot 立即重开",
            "队列仍空就立即重开下一轮",
        ),
    ),
    TextContract(
        "session reconciliation and decision closeout",
        (
            ("Session 恢复",),
            ("planning",),
            ("doing",),
            ("durable branch",),
            ("worktree",),
            ("commit",),
            ("未提交变更",),
            ("reconcile",),
            ("继续恢复",),
            ("orphan",),
            ("记录不一致",),
            ("退回 `queued`",),
            ("用户答复",),
            ("design",),
            ("backlog",),
            ("workflow",),
            ("禁止先删 dossier",),
        ),
        (
            "orphan planning 保持 planning",
            "orphan doing 保持 doing",
            "用户答复后先删 dossier",
        ),
        (
            "先把 verdict / 约束写入",
            "并 commit",
            "再删除 dossier",
            "最后把 `waiting-feedback` 转回 `queued`",
        ),
    ),
    ANTI_OVERENGINEERING_CONTRACT,
    TextContract(
        "long-command exact wait then short completion waits",
        (
            ("长命令",),
            ("5 分钟",),
            ("单一的精确耗时点估计",),
            ("首次计划等待时长必须等于",),
            ("不得添加安全余量",),
            ("预计 25 分钟",),
            ("等待 25 分钟",),
            ("不得给 40 分钟",),
            ("dormant wait / sleep",),
            ("首次完成检查",),
            ("仍未结束",),
            ("短等待",),
            ("不超过 60 秒",),
            ("直到命令完成",),
            ("不得重新估算为更长窗口",),
            ("禁止指数退避",),
            ("增量日志",),
            ("平台有单次等待上限",),
            ("累计等待时长必须恰好达到点估计",),
            ("不得因为分段向上取整",),
        ),
        (
            "保守耗时预估",
            "给出保守预估",
            "第 3 次完成检查后",
            "第 3 次检查后",
            "第 4 次检查前",
            "至少为上一次实际 sleep 的 2 倍",
            "禁止固定频率轮询",
        ),
        (
            "单一的精确耗时点估计",
            "首次计划等待时长必须等于",
            "预计 25 分钟",
            "等待 25 分钟",
            "5 分钟",
            "dormant wait / sleep",
            "首次完成检查",
            "仍未结束",
            "短等待",
            "直到命令完成",
            "平台有单次等待上限",
        ),
    ),
)

LONG_COMMAND_WAIT_CONTRACT = STEWARD_BEHAVIOR_CONTRACTS[-1]

REPOSITORY_CONVERGENCE_CONTRACT = TextContract(
    "repository convergence gate",
    (
        ("Repository convergence gate",),
        ("active worktree",),
        ("不超过 5",),
        ("active item",),
        ("authority",),
        ("branch 只服务",),
        ("Git bundle",),
        ("WIP archive",),
        ("manifest",),
        ("main",),
        ("authority branch",),
        ("cross-item pollution",),
        ("origin/main",),
        ("超过 10 commits",),
        ("超过 24h",),
        ("batch push",),
        ("远端 CI",),
        ("dirty worktree",),
    ),
    (
        "先删除 worktree 再备份",
        "dirty worktree 默认忽略",
        "每个 item 可有多个 authority",
    ),
)

B186_RESOURCE_CROSSING_CONTRACT = TextContract(
    "B-186 one-time resource crossing",
    (
        ("B-186 one-time resource crossing",),
        ("23622320128",),
        ("22 GiB",),
        ("<=5",),
        ("72 分钟",),
        ("90 分钟",),
        ("bootstrap seed",),
        ("12884901888",),
        ("gen2 -> gen3",),
        ("byte-identical",),
        ("#268/#269",),
        ("24/32 GiB",),
        ("pagefile",),
        ("最新 main",),
        ("S-prime",),
        ("A-prime",),
        ("Argument",),
    ),
    (
        "22 GiB 可重复运行",
        "触顶后尝试 32 GiB",
        "提高 pagefile 后重跑",
    ),
)

B186_BACKLOG_CONTRACT = TextContract(
    "B-186 backlog recovery route",
    (
        ("B-186 recovery gate 已由",),
        ("32262726058",),
        ("`B-176` 保持 queued",),
        ("B-180",),
        ("runner anchor-object cache",),
        ("B-190",),
        ("worktree",),
        ("paired-session",),
        ("22 GiB crossing 路线已永久关闭",),
        ("latest main", "S-prime"),
    ),
    ordered=(
        "Canonical dependency chain",
        "#268/#269 -> B-176/B-180",
        "B-176/B-180",
        "B-190",
        "remaining correctness/ABI",
        "B-183",
        "B-174/B-177/B-175",
    ),
)

REPOSITORY_HEALTH_HELPER_CONTRACT = TextContract(
    "repository health executable coverage",
    (
        ("max_worktrees",),
        ("max_dirty_worktrees",),
        ("local branch drift",),
        ("active item/authority drift",),
        ("main/authority board drift",),
        ("cross-item branch pollution",),
        ("origin/main",),
        ("max_main_ahead",),
        ("max_unpushed_age_hours",),
        ("local_backup_artifacts",),
    ),
)

GUARANTEE_BOUNDARY_CONTRACT = TextContract(
    "restore-vs-change guarantee boundary",
    (
        ("修复违反既有公开语义",),
        ("safety",),
        ("ownership",),
        ("恢复既有契约",),
        ("不等于修改保证",),
        (
            "不因出现 safety/ownership 关键词就自动上交",
            "不因 safety/ownership 关键词自动进入用户 Inbox",
        ),
        (
            "候选方案都恢复既有契约",
            "候选都恢复既有契约",
        ),
        ("Argument + 独立反驳",),
        ("选择内部实现",),
        ("接受已知违约",),
        ("降低/豁免保证",),
        ("修改契约",),
        ("才交用户", "才呈交用户"),
    ),
    (
        "任何 safety/ownership bug 都必须等用户",
        "出现 safety 就自动上交",
        "修复 safety bug 属于修改保证",
    ),
)

CODEX_CONTEXT_LEASE = TextContract(
    "Codex context lease",
    (
        ("L/XL",),
        ("invariant",),
        ("验收门",),
        ("continuity units",),
        ("同一个连续 unit 复用原 agent",),
        ("临近 compaction",),
        ("新的独立 continuity unit",),
        ("fresh handoff",),
        ("禁止设置固定 token 数 hard stop",),
    ),
)

DISCUSSION_CONTRACT = TextContract(
    "Discussion decision boundary",
    (
        ("用户保留决定",),
        ("语言公开语义",),
        ("breaking public API/ABI",),
        ("新 P0",),
        ("不可恢复删除",),
        ("普通实现",),
        ("Argument",),
        ("独立 review",),
        ("waiting-feedback",),
        ("[里程碑]",),
        ("[全局阻塞]",),
        ("不要呈现 subagent", "subagent/命令等待"),
    ),
    (
        "所有设计决策必须有用户明确确认",
        "不替用户决定非 trivial",
        "每个已完成的 item 至少应该有一条",
        "用户答复后先删 dossier",
    ),
    (
        "先把 verdict / 约束写入",
        "并 commit",
        "再删除 dossier",
        "最后把对应 item 从 `waiting-feedback` 改回 `queued`",
    ),
)

PAIRED_WORKFLOW_CONTRACT = TextContract(
    "Discussion-Steward paired-session control plane",
    (
        ("Discussion–Steward 双 session 控制面",),
        ("唯一配对",),
        ("Discussion session",),
        ("Steward session",),
        ("durable fallback",),
        ("唤醒 Discussion",),
        ("休眠而非轮询",),
        ("main mutation lease",),
        ("只有一个 session 可写",),
        ("不得变更 main",),
    ),
    (
        "Discussion 与 Steward 可同时写 main",
        "Discussion 持续轮询 Steward",
        "每次唤醒都创建新 session",
    ),
)


def b186_backlog_errors(text: str) -> list[str]:
    errors = check_text_contract(text, B186_BACKLOG_CONTRACT)
    if re.search(r"(?m)^### B-186 ", text):
        errors.append(
            "B-186 backlog recovery route: completed B-186 heading remains active"
        )
    return errors

DISCUSSION_PAIR_CONTRACT = TextContract(
    "Discussion paired-session adapter",
    (
        ("paired Steward session",),
        ("counterpart",),
        ("durable fallback",),
        ("main mutation lease",),
        ("commit SHA",),
        ("唤醒",),
        ("休眠/idle",),
        ("不轮询",),
    ),
)

STEWARD_PAIR_CONTRACT = TextContract(
    "Steward paired-session adapter",
    (
        ("Paired Discussion session",),
        ("counterpart",),
        ("main mutation lease",),
        ("compact packet",),
        ("唤醒",),
        ("休眠/idle",),
        ("不轮询",),
        ("SHA",),
    ),
)

AUDIT_CONTRACT = TextContract(
    "bounded Audit handoff",
    (
        ("repository-wide",),
        ("ordinary PR/commit/diff review belongs to steward",),
        ("每次调用只执行一个",),
        ("bounded round",),
        ("不得在同一 round 中循环到 dry",),
        ("返回 Repository Steward", "返回 Steward"),
        ("自主触发未来的新 round", "自主创建新的 round"),
        ("新的执行任务接管",),
        ("只审不修",),
        ("不报告 finder 等待", "不要报告 finder 等待"),
        ("同一 trigger",),
        ("未变 snapshot",),
        ("最多一轮",),
        ("新 commit",),
        ("新 lens 证据",),
        ("新的风险事件",),
        ("队列仍空",),
        ("不得仅因",),
        ("返回维护/队列扫描",),
    ),
    (
        "下一轮需用户手动触发",
        "用户手动发起下一轮",
        "必须等待用户再次触发 Audit",
        "循环到 dry 后再结束",
        "同一 trigger 和未变 snapshot 立即重开",
        "队列仍空就立即重开下一轮",
    ),
)

AUDIT_EVIDENCE_CONTRACT = TextContract(
    "cross-provider Audit evidence gate",
    (
        ("至少两路独立视角",),
        ("跨 provider",),
        ("不得把同一视角重复计票",),
        ("非原 finder",),
        ("另一独立视角",),
        ("至少两个独立支持判断",),
        ("refutation 已被解释",),
        ("already-tracked",),
        ("不计支持票",),
        ("critical",),
        ("root 亲自读码",),
        ("killed",),
        ("duplicate",),
        ("in-progress",),
        ("insufficient-evidence",),
        ("只进入本 round Summary",),
    ),
    (
        "原 finder 验证自己的候选",
        "already-tracked 计支持票",
        "一个 finder 即可落表",
    ),
)

WORKFLOW_AUDIT_LEDGER_CONTRACT = TextContract(
    "canonical Audit ledger workflow",
    (
        (".agents/scripts/audit_ledger.py",),
        ("refs/notes/ring-steward-audit-ledger",),
        ("Canonical key",),
        ("stable trigger/event id",),
        ("audited source SHA",),
        ("normalized lens set",),
        ("rc-memory",),
        ("type-soundness",),
        ("backend-parity",),
        ("runtime-abi",),
        ("design-drift",),
        ("oracle-blind",),
        ("当前日期、随机 id、递增计数器",),
        ("evidence:commit:<full-sha>",),
        ("不同于 audited source",),
        ("audited source 是它的 ancestor",),
        ("refs/heads/*",),
        ("refs/remotes/*",),
        ("refs/tags/*",),
        ("refs/notes/*",),
        ("reflog",),
        ("object-only",),
        ("dangling commit",),
        ("query",),
        ("check",),
        ("skip-recorded",),
        ("exit 3",),
        ("record",),
        ("findings",),
        ("no-findings",),
        ("Git note commit 不改变 HEAD",),
        ("不算新的 source snapshot",),
    ),
)

STEWARD_LEDGER_ADAPTER_CONTRACT = TextContract(
    "Steward Audit ledger adapter",
    (
        ("docs/workflow.md",),
        ("full-audit",),
        (".agents/scripts/audit_ledger.py",),
        ("不得绕过 ledger",),
    ),
)

FULL_AUDIT_LEDGER_ADAPTER_CONTRACT = TextContract(
    "full-audit ledger adapter",
    (
        ("docs/workflow.md",),
        (".agents/scripts/audit_ledger.py",),
        ("query",),
        ("check",),
        ("skip-recorded",),
        ("exit 3",),
        ("record --outcome findings|no-findings",),
        ("record 成功前 round 未闭环",),
        ("只有共享 helper 可以写 ledger",),
    ),
    ordered=("query", "check", "record --outcome findings|no-findings"),
)

AUDIT_LEDGER_HELPER_CONTRACT = TextContract(
    "Git notes Audit ledger helper",
    (
        ('NOTE_REF = "refs/notes/ring-steward-audit-ledger"',),
        ("INVALID_INPUT_EXIT = 2",),
        ("AUDIT_LENSES = frozenset",),
        ("INCREMENTAL_TRIGGER_SUFFIX = re.compile",),
        ("EVIDENCE_COMMIT = re.compile",),
        ("DURABLE_REF_PREFIXES = (",),
        ('"refs/heads"',),
        ('"refs/remotes"',),
        ('"refs/tags"',),
        ("class EvidenceEvent",),
        ("def parse_evidence_event",),
        ("evidence:commit:<full-sha>",),
        ("if INCREMENTAL_TRIGGER_SUFFIX.search(value)",),
        ("audit:round-2",),
        ("audit:counter-2",),
        ("audit:2",),
        ("queue-empty-round-99",),
        ('"rc-memory"',),
        ('"type-soundness"',),
        ('"backend-parity"',),
        ('"runtime-abi"',),
        ('"design-drift"',),
        ('"oracle-blind"',),
        ("class AuditKey",),
        ("def normalize_trigger_id",),
        ("def normalize_lenses",),
        ("if lens not in AUDIT_LENSES",),
        ("rc-memory.2026-07-29",),
        ("rc-memory.1",),
        ('"made-up-lens"',),
        ("the six-lens closed set was not accepted",),
        ("changed canonical lens set did not reopen",),
        ("def _stored_audit_key",),
        ("schema-v1 counter record lost compatibility",),
        ("def check_start_gate",),
        ("if same_scope and parse_evidence_event(key.trigger_id) is None",),
        ("def _validate_evidence_anchor",),
        ("anchor_sha = self.resolve_source_sha(event.commit_sha)",),
        ("if anchor_sha == key.source_sha",),
        ('"merge-base"',),
        ('"--is-ancestor"',),
        ("if ancestry.returncode == 1",),
        ('"for-each-ref"',),
        ('"--format=%(refname)"',),
        ('f"--contains={anchor_sha}"',),
        ("if not durable_refs",),
        ("refs/notes/*, reflogs",),
        ("unreferenced_descendant",),
        ('("object-only", unreferenced_descendant)',),
        ('("nonexistent", "c" * 40)',),
        ('("same-source", source_one)',),
        ('("unrelated", unrelated_commit)',),
        ("CLI accepted {label} evidence commit",),
        ("same-scope unanchored check did not exit 2",),
        ("same-scope unanchored record did not exit 2",),
        ("anchored evidence event was not durable",),
        ("duplicate evidence anchor did not exit 3",),
        ("def record_outcome",),
        ("class GitAuditLedger",),
        ('"findings"',),
        ('"no-findings"',),
        ("ALREADY_RECORDED_EXIT",),
        ("record = ledger.check_start(key)",),
        ("def self_test_errors",),
    ),
    (),
    (
        "if lens not in AUDIT_LENSES",
        "normalized.add(lens)",
    ),
)

ROLE_CONTRACTS = {
    "implementer": TextContract(
        "implementer role",
        (
            ("implement",),
            ("maintain",),
            ("refactor",),
            ("scoped",),
            ("blocker",),
            ("root",),
            ("先完整读取 AGENTS.md、CLAUDE.md 和 docs/workflow.md。",),
            ("不直接等待或请求用户", "不要直接等待或请求用户"),
            ("同一连续任务复用当前身份",),
        ),
    ),
    "reviewer": TextContract(
        "reviewer role",
        (
            ("read-only",),
            ("implement / maintain / refactor",),
            ("风险",),
            ("Argument",),
            ("反证",),
            ("root",),
            ("先完整读取 AGENTS.md、CLAUDE.md 和 docs/workflow.md。",),
            ("不直接等待或请求用户", "不要直接等待或请求用户"),
        ),
    ),
    "finder": TextContract(
        "finder role",
        (
            ("read-only",),
            ("risk-audit",),
            ("bounded Audit",),
            ("Argument",),
            ("root",),
            ("先完整读取 AGENTS.md、CLAUDE.md 和 docs/workflow.md。",),
            ("不直接等待或请求用户", "不要直接等待或请求用户"),
        ),
    ),
    "skeptic": TextContract(
        "skeptic role",
        (
            ("read-only",),
            ("Argument",),
            ("refute",),
            ("verdict",),
            ("root",),
            ("先完整读取 AGENTS.md、CLAUDE.md 和 docs/workflow.md。",),
            ("不直接等待或请求用户", "不要直接等待或请求用户"),
        ),
    ),
}

ROLE_FORBIDDEN = (
    "直接询问用户",
    "等待用户拍板",
    "向用户请求决定",
)


def check_text_contract(text: str, contract: TextContract) -> list[str]:
    """Return deterministic errors for one structured text contract."""

    errors: list[str] = []
    for alternatives in contract.required_groups:
        if not any(fragment in text for fragment in alternatives):
            rendered = " | ".join(repr(fragment) for fragment in alternatives)
            errors.append(
                f"{contract.name}: missing required fragment ({rendered})"
            )
    for fragment in contract.forbidden:
        if fragment in text:
            errors.append(
                f"{contract.name}: contains forbidden fragment {fragment!r}"
            )
    cursor = -1
    for fragment in contract.ordered:
        position = text.find(fragment, cursor + 1)
        if position < 0:
            errors.append(
                f"{contract.name}: ordered fragment missing or out of order "
                f"after offset {cursor}: {fragment!r}"
            )
            break
        cursor = position
    return errors


def frontmatter_contract_errors(
    relative: str, text: str, expected_name: str
) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return [f"{relative}: missing opening frontmatter delimiter"]

    try:
        end = next(
            index
            for index, line in enumerate(lines[1:], start=1)
            if line.strip() == "---"
        )
    except StopIteration:
        return [f"{relative}: missing closing frontmatter delimiter"]

    fields: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip():
            continue
        if ":" not in line:
            errors.append(f"{relative}: invalid frontmatter line: {line!r}")
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not key or not value:
            errors.append(f"{relative}: empty frontmatter field: {line!r}")
            continue
        if key in fields:
            errors.append(f"{relative}: duplicate frontmatter field: {key}")
        fields[key] = value

    if fields.get("name") != expected_name:
        errors.append(
            f"{relative}: frontmatter name must be {expected_name!r}, "
            f"got {fields.get('name')!r}"
        )
    if not fields.get("description"):
        errors.append(f"{relative}: frontmatter description is required")
    if end + 1 >= len(lines) or not any(
        line.strip() for line in lines[end + 1 :]
    ):
        errors.append(f"{relative}: skill body is empty")
    return errors


def legacy_adapter_errors(relative: str, text: str) -> list[str]:
    errors: list[str] = []
    for pattern, label in LEGACY_ADAPTER_PATTERNS.items():
        if pattern in text:
            errors.append(
                f"{relative}: contains stale {label}: {pattern!r}"
            )
    return errors


def skill_layout_contract_errors(existing_paths: set[str]) -> list[str]:
    """Validate worker-to-steward migration using a pure path fixture."""

    errors: list[str] = []
    for provider in SKILL_PROVIDERS:
        worker_prefix = f"{provider}/skills/worker"
        if any(
            path.startswith(f"{worker_prefix}/")
            for path in existing_paths
        ):
            errors.append(
                f"{provider}/skills/worker: legacy worker skill directory remains"
            )

        steward_file = f"{provider}/skills/steward/SKILL.md"
        if steward_file not in existing_paths:
            errors.append(f"missing migrated skill: {steward_file}")
    return errors


def role_contract_errors(role: str, instructions: str) -> list[str]:
    errors = check_text_contract(instructions, ROLE_CONTRACTS[role])
    for fragment in ROLE_FORBIDDEN:
        if fragment in instructions:
            errors.append(
                f"{role} role: contains forbidden direct-user behavior "
                f"{fragment!r}"
            )
    return errors


class WorkflowValidator:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.errors: list[str] = []

    def read_text(self, relative: str) -> str | None:
        path = self.root / relative
        if not path.is_file():
            self.errors.append(f"missing file: {relative}")
            return None
        try:
            return path.read_text(encoding="utf-8")
        except OSError as error:
            self.errors.append(f"{relative}: {error}")
            return None

    def validate_headings(self) -> tuple[int, int]:
        backlog_count = 0
        backlog = self.read_text("docs/backlog.md")
        if backlog is not None:
            for number, line in enumerate(backlog.splitlines(), start=1):
                if not line.startswith("### B-"):
                    continue
                if BACKLOG_HEADING.fullmatch(line):
                    backlog_count += 1
                else:
                    self.errors.append(
                        f"docs/backlog.md:{number}: invalid backlog "
                        f"heading: {line}"
                    )

        audit_count = 0
        audit = self.read_text("docs/audit-report.md")
        if audit is not None:
            for number, line in enumerate(audit.splitlines(), start=1):
                if not line.startswith("### #"):
                    continue
                if AUDIT_HEADING.fullmatch(line):
                    audit_count += 1
                else:
                    self.errors.append(
                        f"docs/audit-report.md:{number}: invalid audit "
                        f"heading: {line}"
                    )
        return backlog_count, audit_count

    def validate_workflow_contract(self) -> None:
        text = self.read_text("docs/workflow.md")
        if text is None:
            return
        for contract in (
            WORKFLOW_AUDIT_LEDGER_CONTRACT,
            LONG_COMMAND_WAIT_CONTRACT,
            REPOSITORY_CONVERGENCE_CONTRACT,
            B186_RESOURCE_CROSSING_CONTRACT,
            PAIRED_WORKFLOW_CONTRACT,
            MACRO_CHECKIN_CONTRACT,
            ANTI_OVERENGINEERING_CONTRACT,
        ):
            for error in check_text_contract(text, contract):
                self.errors.append(f"docs/workflow.md: {error}")

    def validate_b186_backlog_contract(self) -> None:
        text = self.read_text("docs/backlog.md")
        if text is None:
            return
        for error in b186_backlog_errors(text):
            self.errors.append(f"docs/backlog.md: {error}")

    def validate_skills(self) -> None:
        existing_paths: set[str] = set()
        for provider in SKILL_PROVIDERS:
            skills_root = self.root / provider / "skills"
            if skills_root.exists():
                for path in skills_root.rglob("*"):
                    existing_paths.add(path.relative_to(self.root).as_posix())
        self.errors.extend(skill_layout_contract_errors(existing_paths))

        for provider in SKILL_PROVIDERS:
            for skill_name in SKILL_NAMES:
                relative = f"{provider}/skills/{skill_name}/SKILL.md"
                text = self.read_text(relative)
                if text is None:
                    continue
                frontmatter_errors = frontmatter_contract_errors(
                    relative, text, skill_name
                )
                self.errors.extend(frontmatter_errors)
                self.errors.extend(legacy_adapter_errors(relative, text))
                if frontmatter_errors:
                    continue

                if skill_name == "steward":
                    lines = text.splitlines()
                    frontmatter_end = next(
                        index
                        for index, line in enumerate(lines[1:], start=1)
                        if line.strip() == "---"
                    )
                    description = "\n".join(lines[1:frontmatter_end])
                    for trigger in (
                        "执行",
                        "开始工作",
                        "worker",
                        "implement",
                        "maintain",
                        "review",
                        "refactor",
                        "Argument",
                        "Audit",
                    ):
                        if trigger not in description:
                            self.errors.append(
                                f"{relative}: steward frontmatter missing "
                                f"compatibility trigger {trigger!r}"
                            )
                    for contract in STEWARD_BEHAVIOR_CONTRACTS:
                        for error in check_text_contract(text, contract):
                            self.errors.append(f"{relative}: {error}")
                    for error in check_text_contract(
                        text, GUARANTEE_BOUNDARY_CONTRACT
                    ):
                        self.errors.append(f"{relative}: {error}")
                    for error in check_text_contract(
                        text, STEWARD_LEDGER_ADAPTER_CONTRACT
                    ):
                        self.errors.append(f"{relative}: {error}")
                    for error in check_text_contract(
                        text, STEWARD_PAIR_CONTRACT
                    ):
                        self.errors.append(f"{relative}: {error}")
                    if provider == ".agents":
                        for error in check_text_contract(
                            text, CODEX_CONTEXT_LEASE
                        ):
                            self.errors.append(f"{relative}: {error}")
                elif skill_name == "discussion":
                    for contract in (
                        DISCUSSION_CONTRACT,
                        MACRO_CHECKIN_CONTRACT,
                        ANTI_OVERENGINEERING_CONTRACT,
                        GUARANTEE_BOUNDARY_CONTRACT,
                        DISCUSSION_PAIR_CONTRACT,
                    ):
                        for error in check_text_contract(text, contract):
                            self.errors.append(f"{relative}: {error}")
                else:
                    for contract in (
                        AUDIT_CONTRACT,
                        AUDIT_EVIDENCE_CONTRACT,
                        FULL_AUDIT_LEDGER_ADAPTER_CONTRACT,
                    ):
                        for error in check_text_contract(text, contract):
                            self.errors.append(f"{relative}: {error}")

    def validate_audit_ledger_helper(self) -> None:
        relative = ".agents/scripts/audit_ledger.py"
        text = self.read_text(relative)
        if text is None:
            return
        for error in check_text_contract(
            text, AUDIT_LEDGER_HELPER_CONTRACT
        ):
            self.errors.append(f"{relative}: {error}")

    def validate_repository_health_helper(self) -> None:
        relative = ".agents/scripts/repository_health.py"
        text = self.read_text(relative)
        if text is not None:
            for error in check_text_contract(
                text, REPOSITORY_HEALTH_HELPER_CONTRACT
            ):
                self.errors.append(f"{relative}: {error}")
        config_relative = "docs/repository-health.json"
        config_text = self.read_text(config_relative)
        if config_text is None:
            return
        try:
            config = json.loads(config_text)
        except json.JSONDecodeError as error:
            self.errors.append(f"{config_relative}: {error}")
            return
        if config.get("schema") != "ring.repository-health.v1":
            self.errors.append(f"{config_relative}: schema mismatch")
        if config.get("max_worktrees") != 5:
            self.errors.append(f"{config_relative}: max_worktrees must be 5")

    def validate_codex_config(self) -> None:
        relative = ".codex/config.toml"
        config_path = self.root / relative
        if not config_path.is_file():
            self.errors.append(f"missing file: {relative}")
            return
        try:
            with config_path.open("rb") as handle:
                config = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError) as error:
            self.errors.append(f"{relative}: {error}")
            return

        agents = config.get("agents")
        if not isinstance(agents, dict):
            self.errors.append(".codex/config.toml: missing [agents] table")
            return
        if agents.get("enabled") is not True:
            self.errors.append(".codex/config.toml: agents.enabled must be true")
        concurrency = agents.get("max_concurrent_threads_per_session")
        if (
            not isinstance(concurrency, int)
            or isinstance(concurrency, bool)
            or concurrency < 1
        ):
            self.errors.append(
                ".codex/config.toml: "
                "agents.max_concurrent_threads_per_session must be positive"
            )

        for role in CODEX_ROLES:
            entry = agents.get(role)
            if not isinstance(entry, dict):
                self.errors.append(
                    f".codex/config.toml: missing [agents.{role}]"
                )
                continue
            relative_role = entry.get("config_file")
            if not isinstance(relative_role, str):
                self.errors.append(
                    f".codex/config.toml: agents.{role}.config_file missing"
                )
                continue
            role_path = config_path.parent / relative_role
            if not role_path.is_file():
                self.errors.append(
                    f".codex/config.toml: agents.{role}.config_file not "
                    f"found: {relative_role}"
                )
                continue
            try:
                with role_path.open("rb") as handle:
                    role_config = tomllib.load(handle)
            except (OSError, tomllib.TOMLDecodeError) as error:
                self.errors.append(
                    f"{role_path.relative_to(self.root)}: {error}"
                )
                continue
            instructions = role_config.get("developer_instructions")
            if not isinstance(instructions, str):
                self.errors.append(
                    f"{role_path.relative_to(self.root)}: "
                    "developer_instructions must be a string"
                )
                continue
            for error in role_contract_errors(role, instructions):
                self.errors.append(
                    f"{role_path.relative_to(self.root)}: {error}"
                )

    def run(self) -> tuple[int, int]:
        backlog_count, audit_count = self.validate_headings()
        self.validate_workflow_contract()
        self.validate_b186_backlog_contract()
        self.validate_skills()
        self.validate_audit_ledger_helper()
        self.validate_repository_health_helper()
        self.validate_codex_config()
        return backlog_count, audit_count


def malformed_frontmatter_e2e_errors() -> list[str]:
    """Run validate_skills against a temporary malformed steward skill."""

    with tempfile.TemporaryDirectory(
        prefix="ring-workflow-frontmatter-"
    ) as temporary:
        fixture_root = Path(temporary)
        for provider in SKILL_PROVIDERS:
            shutil.copytree(
                ROOT / provider / "skills",
                fixture_root / provider / "skills",
            )
        malformed = (
            fixture_root / ".agents" / "skills" / "steward" / "SKILL.md"
        )
        malformed.write_text(
            "# Repository Steward\n\nMissing YAML frontmatter.\n",
            encoding="utf-8",
        )

        validator = WorkflowValidator(fixture_root)
        validator.validate_skills()
        return validator.errors


def invalid_heading_status_e2e_errors() -> list[str]:
    """Ensure unknown lifecycle labels cannot hide from heading validation."""

    with tempfile.TemporaryDirectory(
        prefix="ring-workflow-heading-"
    ) as temporary:
        fixture_root = Path(temporary)
        docs = fixture_root / "docs"
        docs.mkdir()
        (docs / "backlog.md").write_text(
            "### B-999 stale [bugfix] [P2] [S] [mechanical] "
            "[phase1-done]\n",
            encoding="utf-8",
        )
        (docs / "audit-report.md").write_text(
            "### #999 stale [low] [mechanical] [deferred]\n",
            encoding="utf-8",
        )

        validator = WorkflowValidator(fixture_root)
        backlog_count, audit_count = validator.validate_headings()
        expected = ("invalid backlog heading", "invalid audit heading")
        if (backlog_count, audit_count) != (0, 0) or not all(
            any(fragment in error for error in validator.errors)
            for fragment in expected
        ):
            return [
                "custom heading status regression was not fully rejected: "
                f"counts={(backlog_count, audit_count)!r}, "
                f"errors={validator.errors!r}"
            ]
        return validator.errors


def relaxed_helper_fixture_errors(
    guard: str,
    replacement: str,
) -> list[str]:
    """Apply one broken helper mutation and run its text contract."""

    helper = ROOT / ".agents/scripts/audit_ledger.py"
    try:
        text = helper.read_text(encoding="utf-8")
    except OSError as error:
        return [f".agents/scripts/audit_ledger.py: {error}"]
    relaxed = text.replace(guard, replacement, 1)
    if relaxed == text:
        return [f"helper fixture setup could not find guard: {guard!r}"]
    return check_text_contract(relaxed, AUDIT_LEDGER_HELPER_CONTRACT)


def open_lens_helper_fixture_errors() -> list[str]:
    return relaxed_helper_fixture_errors(
        "if lens not in AUDIT_LENSES:",
        "if False:  # accepts arbitrary lens",
    )


def counter_trigger_helper_fixture_errors() -> list[str]:
    return relaxed_helper_fixture_errors(
        "if INCREMENTAL_TRIGGER_SUFFIX.search(value):",
        "if False:  # accepts incremental trigger suffix",
    )


def same_scope_helper_fixture_errors() -> list[str]:
    return relaxed_helper_fixture_errors(
        "if same_scope and parse_evidence_event(key.trigger_id) is None:",
        "if False:  # accepts unanchored same-scope restart",
    )


def evidence_anchor_helper_fixture_errors() -> list[str]:
    return relaxed_helper_fixture_errors(
        "anchor_sha = self.resolve_source_sha(event.commit_sha)",
        "anchor_sha = event.commit_sha  # skips durable Git resolution",
    )


def durable_ref_helper_fixture_errors() -> list[str]:
    return relaxed_helper_fixture_errors(
        "if not durable_refs:",
        "if False:  # accepts dangling object-only evidence",
    )


GOOD_STEWARD_FIXTURE = """
持续推进 implement、maintain、review、refactor、Argument 和 Audit。
单个 item 的 waiting-feedback 不是全局阻塞，必须立即补位。
waiting-feedback item 达到 clean checkpoint commit，且测试状态与必要 handoff 已持久化后，
可以释放 worktree，
但必须保留 branch/commit；未达到时保留 worktree 或先 checkpoint。
只有全部有价值工作耗尽或全局阻塞时才停止。
宏观 check-in 保持低噪声：
当前总门、已获得的 durable claim、下一道可证伪验收门、全局风险、需要用户拍板。
默认不报告 subagent 等待、命令进度、原始日志或逐文件实现流水。
所有决策服务于总路线图最优先目标和当前可证伪需求，选择最小充分方案。
内部友善边界不默认恶意攻击，不用虚构应用场景支持无意义泛化。
实现现在可用且近期不会产生已知bug时，留到定期 refactor。
发现修灯泡空难式scope扩张立即停止；简单化不降低correctness/safety/ownership或真实外部边界。
Steward Inbox 只保存 [决策]、[里程碑] 和 [全局阻塞]。
Argument 比较至少两个真实候选，由独立 reviewer 主动攻击推荐方案，
再由 root 给出 verdict。语言公开语义属于用户保留决定，保持现有公开行为。
修复违反既有公开语义、safety 或 ownership 保证的 bug 是恢复既有契约，
不等于修改保证，不因出现 safety/ownership 关键词就自动上交。
候选方案都恢复既有契约时，经 Argument + 独立反驳后选择内部实现；
只有接受已知违约、降低/豁免保证或修改契约才交用户。
高风险节点可自主触发新 round；每次是 bounded Audit，
不得在同一 round 内 loop-until-dry，finding 由新的执行任务接管。
同一 trigger + 未变 snapshot 最多一轮；没有新 commit、新 lens 证据或新的风险事件时，
不得仅因队列仍空就立即重开；无 finding 的 round 返回维护/队列扫描。
Session 恢复要 reconcile planning / doing 与 durable branch、worktree、commit
或未提交变更。有 durable 状态的继续恢复；没有状态的 orphan
要记录不一致并退回 `queued`。
用户答复后，先把 verdict / 约束写入 design、backlog 或 workflow 真值并 commit；
再删除 dossier；最后把 `waiting-feedback` 转回 `queued`。禁止先删 dossier。
长命令启动前形成单一的精确耗时点估计；首次计划等待时长必须等于该点估计，
不得添加安全余量。预计 25 分钟就等待 25 分钟，不得给 40 分钟。
达到 5 分钟时，按精确耗时点估计进入一次 dormant wait / sleep，
首次完成检查只能在该精确等待结束后进行。若仍未结束，改用每次不超过 60 秒的短等待，
直到命令完成；不得重新估算为更长窗口，禁止指数退避。
仅为判断是否结束而读取增量日志属于额外轮询，不得另查状态与日志。
平台有单次等待上限时，分段的累计等待时长必须恰好达到点估计，
不得因为分段向上取整。
"""

GOOD_AUDIT_EVIDENCE_FIXTURE = """
至少两路独立视角，跨 provider 可用时保留不同路线，不得把同一视角重复计票。
由非原 finder reproduce，另一独立视角 refute。
finding 至少两个独立支持判断，refutation 已被解释。
already-tracked 只去重，不计支持票；critical 由 root 亲自读码。
killed、duplicate、in-progress、insufficient-evidence 只进入本 round Summary。
"""

GOOD_CONVERGENCE_FIXTURE = """
### 4.8 Repository convergence gate
active worktree 不超过 5。每个 active item 恰好有一个 authority，且 authority
branch 只服务一个 group。bulk cleanup 前验证 Git bundle、WIP archive 与 manifest。
main 和 authority branch 看板一致；cross-item pollution fail closed。
main ahead origin/main 超过 10 commits 或最老未 push 超过 24h 时先 batch push，
取得远端 CI。报告所有 dirty worktree，不得默认忽略。

### 4.9 B-186 one-time resource crossing
固定 S-prime gen1 只作为 bootstrap seed；23622320128 bytes（22 GiB），process <=5，
首次等待 72 分钟，hard wall 90 分钟。成功后恢复 12884901888 bytes，执行
gen2 -> gen3，只有 C byte-identical 且 #268/#269 全部门通过才关闭。
失败后不试 24/32 GiB 或 pagefile；转最新 main 分别完成 S-prime、A-prime，
不可分时先 Argument。
"""

GOOD_B186_BACKLOG_FIXTURE = """
Canonical dependency chain: #268/#269 -> B-176/B-180 ->
B-190 -> remaining correctness/ABI -> B-183 -> B-174/B-177/B-175.
B-186 recovery gate 已由 main 与 CI 32262726058 完成。
`B-176` 保持 queued；B-180 只保留 runner anchor-object cache。
worktree 不超过 5，origin/main push gate 生效。
paired-session 通过 main mutation lease 串行提交。
固定 archive 缺少 object identity；22 GiB crossing 路线已永久关闭。
fallback 在 latest main 先完成 S-prime，再重放 A-prime。
"""

GOOD_PAIRED_WORKFLOW_FIXTURE = """
## 0. Discussion–Steward 双 session 控制面
唯一配对一个 Discussion session 与一个 Steward session；counterpart 缺失时使用
durable fallback。Steward 只在高层变化时唤醒 Discussion，Discussion 采用休眠而非轮询。
main mutation lease 保证任何时刻只有一个 session 可写；lease 期间另一方不得变更 main。
"""

GOOD_DISCUSSION_PAIR_FIXTURE = """
Discussion 使用 paired Steward session，先发现并复用 counterpart；工具不可用走 durable fallback。
写 main 前取得 main mutation lease，提交后发送 commit SHA。收到消息可被唤醒；
无事时休眠/idle，不轮询实现状态。
"""

GOOD_STEWARD_PAIR_FIXTURE = """
## Paired Discussion session
Steward 复用 counterpart，通过 main mutation lease 串行写 main。
Discussion 休眠/idle 时不轮询；高层变化用 compact packet 唤醒，并核对 verdict SHA。
"""


def deterministic_failure(
    label: str, producer: Any, expected_fragment: str
) -> list[str]:
    """Assert a negative fixture fails identically on repeated evaluation."""

    failures: list[str] = []
    results: list[list[str]] = []
    exceptions: list[str | None] = []
    for _ in range(2):
        try:
            results.append(list(producer()))
            exceptions.append(None)
        except Exception as error:  # noqa: BLE001 - self-test reports crashes
            results.append([])
            exceptions.append(f"{type(error).__name__}: {error}")

    first, second = results
    if any(exceptions):
        failures.append(
            f"{label}: negative fixture raised instead of returning errors: "
            f"{exceptions!r}"
        )
        return failures
    if not first:
        failures.append(f"{label}: negative fixture unexpectedly passed")
    if first != second:
        failures.append(f"{label}: failure output is not deterministic")
    if not any(expected_fragment in error for error in first):
        failures.append(
            f"{label}: expected error containing "
            f"{expected_fragment!r}, got {first!r}"
        )
    return failures


def audit_ledger_process_self_test_errors() -> list[str]:
    """Exercise the shared helper's pure and temporary-Git regressions."""

    relative = ".agents/scripts/audit_ledger.py"
    helper = ROOT / relative
    if not helper.is_file():
        return [f"missing file: {relative}"]
    try:
        result = subprocess.run(
            [sys.executable, str(helper), "--self-test"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            text=True,
            # The temporary-Git notes regression crosses the 30 s boundary on
            # Windows even when it succeeds (30.52 s observed on 2026-08-01).
            # Keep the guard bounded, but leave enough headroom for process and
            # filesystem startup variance instead of turning a pass into a
            # deterministic timeout.
            timeout=90,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return [f"{relative} --self-test could not complete: {error}"]
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        return [
            f"{relative} --self-test failed ({result.returncode}): {detail}"
        ]
    expected = (
        "audit ledger self-test passed: "
        "pure state machine + temporary Git notes/CLI end-to-end"
    )
    if expected not in result.stdout:
        return [
            f"{relative} --self-test missing success marker: "
            f"{result.stdout.strip()!r}"
        ]
    return []


def run_self_tests(*, include_audit_ledger_process: bool) -> list[str]:
    """Exercise cheap fixtures and, when requested, process/Git integration."""

    failures: list[str] = []
    good_errors: list[str] = []
    for contract in STEWARD_BEHAVIOR_CONTRACTS:
        good_errors.extend(check_text_contract(GOOD_STEWARD_FIXTURE, contract))
    good_errors.extend(
        check_text_contract(
            GOOD_STEWARD_FIXTURE, GUARANTEE_BOUNDARY_CONTRACT
        )
    )
    if good_errors:
        failures.append(
            f"self-test good steward fixture rejected: {good_errors!r}"
        )
    evidence_errors = check_text_contract(
        GOOD_AUDIT_EVIDENCE_FIXTURE, AUDIT_EVIDENCE_CONTRACT
    )
    if evidence_errors:
        failures.append(
            f"self-test good audit evidence fixture rejected: "
            f"{evidence_errors!r}"
        )
    for fixture, contract in (
        (GOOD_CONVERGENCE_FIXTURE, REPOSITORY_CONVERGENCE_CONTRACT),
        (GOOD_CONVERGENCE_FIXTURE, B186_RESOURCE_CROSSING_CONTRACT),
        (GOOD_B186_BACKLOG_FIXTURE, B186_BACKLOG_CONTRACT),
        (GOOD_PAIRED_WORKFLOW_FIXTURE, PAIRED_WORKFLOW_CONTRACT),
        (GOOD_DISCUSSION_PAIR_FIXTURE, DISCUSSION_PAIR_CONTRACT),
        (GOOD_STEWARD_PAIR_FIXTURE, STEWARD_PAIR_CONTRACT),
    ):
        fixture_errors = check_text_contract(fixture, contract)
        if fixture_errors:
            failures.append(
                f"self-test good {contract.name} fixture rejected: "
                f"{fixture_errors!r}"
            )
    if include_audit_ledger_process:
        failures.extend(audit_ledger_process_self_test_errors())
    failures.extend(
        deterministic_failure(
            "open Audit lens helper fixture",
            open_lens_helper_fixture_errors,
            "if lens not in AUDIT_LENSES",
        )
    )
    failures.extend(
        deterministic_failure(
            "incremental trigger helper fixture",
            counter_trigger_helper_fixture_errors,
            "if INCREMENTAL_TRIGGER_SUFFIX.search(value)",
        )
    )
    failures.extend(
        deterministic_failure(
            "same-scope evidence helper fixture",
            same_scope_helper_fixture_errors,
            "if same_scope and parse_evidence_event(key.trigger_id) is None",
        )
    )
    failures.extend(
        deterministic_failure(
            "evidence commit resolution helper fixture",
            evidence_anchor_helper_fixture_errors,
            "anchor_sha = self.resolve_source_sha(event.commit_sha)",
        )
    )
    failures.extend(
        deterministic_failure(
            "evidence durable-ref helper fixture",
            durable_ref_helper_fixture_errors,
            "if not durable_refs",
        )
    )

    failures.extend(
        deterministic_failure(
            "malformed frontmatter end-to-end fixture",
            malformed_frontmatter_e2e_errors,
            ".agents/skills/steward/SKILL.md: "
            "missing opening frontmatter delimiter",
        )
    )
    failures.extend(
        deterministic_failure(
            "unknown heading status end-to-end fixture",
            invalid_heading_status_e2e_errors,
            "invalid backlog heading",
        )
    )

    bad_waiting = GOOD_STEWARD_FIXTURE.replace(
        "单个 item 的 waiting-feedback 不是全局阻塞，必须立即补位。",
        "单个 item 进入 waiting-feedback 后停止全局工作，等待用户。",
    )
    failures.extend(
        deterministic_failure(
            "waiting-feedback backfill fixture",
            lambda: check_text_contract(
                bad_waiting, STEWARD_BEHAVIOR_CONTRACTS[0]
            ),
            "waiting-feedback backfill",
        )
    )
    bad_waiting_handoff = GOOD_STEWARD_FIXTURE.replace(
        "waiting-feedback item 达到 clean checkpoint commit，且测试状态与必要 handoff 已持久化后，\n"
        "可以释放 worktree，\n"
        "但必须保留 branch/commit；未达到时保留 worktree 或先 checkpoint。",
        "waiting-feedback item 一律立即释放 worktree。",
    )
    failures.extend(
        deterministic_failure(
            "waiting-feedback handoff fixture",
            lambda: check_text_contract(
                bad_waiting_handoff, STEWARD_BEHAVIOR_CONTRACTS[0]
            ),
            "waiting-feedback backfill",
        )
    )

    bad_checkin = GOOD_STEWARD_FIXTURE.replace(
        "宏观 check-in 保持低噪声：\n"
        "当前总门、已获得的 durable claim、下一道可证伪验收门、全局风险、需要用户拍板。\n"
        "默认不报告 subagent 等待、命令进度、原始日志或逐文件实现流水。",
        "向用户汇报 subagent、逐项汇报命令和全部实现过程。",
    )
    failures.extend(
        deterministic_failure(
            "low-noise check-in fixture",
            lambda: check_text_contract(
                bad_checkin, STEWARD_BEHAVIOR_CONTRACTS[1]
            ),
            "low-noise five-part macro check-in",
        )
    )

    bad_checkin_order = GOOD_STEWARD_FIXTURE.replace(
        "当前总门、已获得的 durable claim、下一道可证伪验收门、全局风险、需要用户拍板。",
        "需要用户拍板、当前总门、全局风险、已获得的 durable claim、下一道可证伪验收门。",
    )
    failures.extend(
        deterministic_failure(
            "macro check-in order fixture",
            lambda: check_text_contract(
                bad_checkin_order, MACRO_CHECKIN_CONTRACT
            ),
            "low-noise five-part macro check-in",
        )
    )

    bad_overengineering = GOOD_STEWARD_FIXTURE.replace(
        "所有决策服务于总路线图最优先目标和当前可证伪需求，选择最小充分方案。\n"
        "内部友善边界不默认恶意攻击，不用虚构应用场景支持无意义泛化。\n"
        "实现现在可用且近期不会产生已知bug时，留到定期 refactor。\n"
        "发现修灯泡空难式scope扩张立即停止；简单化不降低correctness/safety/ownership或真实外部边界。",
        "默认内部调用者恶意，为未来可能需求先泛化，并顺手重构整个仓库。",
    )
    failures.extend(
        deterministic_failure(
            "anti-overengineering fixture",
            lambda: check_text_contract(
                bad_overengineering, ANTI_OVERENGINEERING_CONTRACT
            ),
            "roadmap-first anti-overengineering gate",
        )
    )

    bad_argument = GOOD_STEWARD_FIXTURE.replace(
        "Argument 比较至少两个真实候选，由独立 reviewer 主动攻击推荐方案，\n"
        "再由 root 给出 verdict。语言公开语义属于用户保留决定，保持现有公开行为。",
        "root 无需独立反驳即可改变语言公开语义。",
    )
    failures.extend(
        deterministic_failure(
            "Argument authority fixture",
            lambda: check_text_contract(
                bad_argument, STEWARD_BEHAVIOR_CONTRACTS[2]
            ),
            "Argument with independent refutation and root verdict",
        )
    )

    bad_guarantee_boundary = GOOD_STEWARD_FIXTURE.replace(
        "修复违反既有公开语义、safety 或 ownership 保证的 bug 是恢复既有契约，\n"
        "不等于修改保证，不因出现 safety/ownership 关键词就自动上交。\n"
        "候选方案都恢复既有契约时，经 Argument + 独立反驳后选择内部实现；\n"
        "只有接受已知违约、降低/豁免保证或修改契约才交用户。",
        "任何 safety/ownership bug 都必须等用户；"
        "修复 safety bug 属于修改保证。",
    )
    failures.extend(
        deterministic_failure(
            "guarantee restore-vs-change fixture",
            lambda: check_text_contract(
                bad_guarantee_boundary, GUARANTEE_BOUNDARY_CONTRACT
            ),
            "restore-vs-change guarantee boundary",
        )
    )

    bad_audit = GOOD_STEWARD_FIXTURE.replace(
        "高风险节点可自主触发新 round；每次是 bounded Audit，\n"
        "不得在同一 round 内 loop-until-dry，finding 由新的执行任务接管。\n"
        "同一 trigger + 未变 snapshot 最多一轮；没有新 commit、新 lens 证据或新的风险事件时，\n"
        "不得仅因队列仍空就立即重开；无 finding 的 round 返回维护/队列扫描。",
        "高风险后等待用户手动发起下一轮 audit，"
        "并在同一 round loop-until-dry；"
        "同一 trigger 和未变 snapshot 因队列仍空立即重开。",
    )
    failures.extend(
        deterministic_failure(
            "bounded Audit fixture",
            lambda: check_text_contract(
                bad_audit, STEWARD_BEHAVIOR_CONTRACTS[3]
            ),
            "risk-triggered bounded Audit",
        )
    )

    bad_recovery = GOOD_STEWARD_FIXTURE.replace(
        "Session 恢复要 reconcile planning / doing 与 durable branch、worktree、commit\n"
        "或未提交变更。有 durable 状态的继续恢复；没有状态的 orphan\n"
        "要记录不一致并退回 `queued`。\n"
        "用户答复后，先把 verdict / 约束写入 design、backlog 或 workflow 真值并 commit；\n"
        "再删除 dossier；最后把 `waiting-feedback` 转回 `queued`。禁止先删 dossier。",
        "Session 恢复只看 doing；orphan planning 保持 planning。\n"
        "用户答复后先删 dossier，再考虑是否记录 verdict。",
    )
    failures.extend(
        deterministic_failure(
            "session reconciliation fixture",
            lambda: check_text_contract(
                bad_recovery, STEWARD_BEHAVIOR_CONTRACTS[4]
            ),
            "session reconciliation and decision closeout",
        )
    )

    bad_decision_order = GOOD_STEWARD_FIXTURE.replace(
        "用户答复后，先把 verdict / 约束写入 design、backlog 或 workflow 真值并 commit；\n"
        "再删除 dossier；最后把 `waiting-feedback` 转回 `queued`。禁止先删 dossier。",
        "用户答复后，再删除 dossier；先把 verdict / 约束写入 "
        "design、backlog 或 workflow 真值并 commit；"
        "最后把 `waiting-feedback` 转回 `queued`。禁止先删 dossier。",
    )
    failures.extend(
        deterministic_failure(
            "decision closeout ordering fixture",
            lambda: check_text_contract(
                bad_decision_order, STEWARD_BEHAVIOR_CONTRACTS[4]
            ),
            "ordered fragment missing or out of order",
        )
    )

    bad_convergence = GOOD_CONVERGENCE_FIXTURE.replace(
        "bulk cleanup 前验证 Git bundle、WIP archive 与 manifest。",
        "先删除 worktree 再备份；dirty worktree 默认忽略。",
    )
    failures.extend(
        deterministic_failure(
            "repository convergence archive fixture",
            lambda: check_text_contract(
                bad_convergence, REPOSITORY_CONVERGENCE_CONTRACT
            ),
            "repository convergence gate",
        )
    )
    bad_resource_crossing = GOOD_CONVERGENCE_FIXTURE.replace(
        "失败后不试 24/32 GiB 或 pagefile；转最新 main 分别完成 S-prime、A-prime，",
        "22 GiB 可重复运行；触顶后尝试 32 GiB，提高 pagefile 后重跑；",
    )
    failures.extend(
        deterministic_failure(
            "B-186 resource escalation fixture",
            lambda: check_text_contract(
                bad_resource_crossing, B186_RESOURCE_CROSSING_CONTRACT
            ),
            "B-186 one-time resource crossing",
        )
    )
    bad_b186_route = GOOD_B186_BACKLOG_FIXTURE.replace(
        "#268/#269 -> B-176/B-180 ->\n"
        "B-190 -> remaining correctness/ABI -> B-183 -> B-174/B-177/B-175",
        "B-176/B-180 -> B-174/B-177/B-175 -> B-183 -> #268/#269",
    )
    failures.extend(
        deterministic_failure(
            "B-186 canonical route fixture",
            lambda: check_text_contract(
                bad_b186_route, B186_BACKLOG_CONTRACT
            ),
            "B-186 backlog recovery route",
        )
    )
    lingering_b186 = (
        GOOD_B186_BACKLOG_FIXTURE
        + "\n### B-186 stale [infra] [P0] [M] [judgment] [doing]\n"
    )
    failures.extend(
        deterministic_failure(
            "completed B-186 heading fixture",
            lambda: b186_backlog_errors(lingering_b186),
            "completed B-186 heading remains active",
        )
    )

    bad_paired_lease = GOOD_PAIRED_WORKFLOW_FIXTURE.replace(
        "main mutation lease 保证任何时刻只有一个 session 可写；lease 期间另一方不得变更 main。",
        "Discussion 与 Steward 可同时写 main，并持续轮询彼此。",
    )
    failures.extend(
        deterministic_failure(
            "paired-session main lease fixture",
            lambda: check_text_contract(
                bad_paired_lease, PAIRED_WORKFLOW_CONTRACT
            ),
            "Discussion-Steward paired-session control plane",
        )
    )

    bad_long_command_wait = GOOD_STEWARD_FIXTURE.replace(
        "长命令启动前形成单一的精确耗时点估计；首次计划等待时长必须等于该点估计，\n"
        "不得添加安全余量。预计 25 分钟就等待 25 分钟，不得给 40 分钟。\n"
        "达到 5 分钟时，按精确耗时点估计进入一次 dormant wait / sleep，\n"
        "首次完成检查只能在该精确等待结束后进行。若仍未结束，改用每次不超过 60 秒的短等待，\n"
        "直到命令完成；不得重新估算为更长窗口，禁止指数退避。\n"
        "仅为判断是否结束而读取增量日志属于额外轮询，不得另查状态与日志。\n"
        "平台有单次等待上限时，分段的累计等待时长必须恰好达到点估计，\n"
        "不得因为分段向上取整。",
        "长命令启动前先做保守耗时预估，预计 25 分钟给 40 分钟窗口；"
        "第 3 次检查后仍未结束就指数退避。",
    )
    failures.extend(
        deterministic_failure(
            "long-command exact-wait fixture",
            lambda: check_text_contract(
                bad_long_command_wait, LONG_COMMAND_WAIT_CONTRACT
            ),
            "long-command exact wait then short completion waits",
        )
    )

    bad_evidence = (
        "一个 finder 即可落表并验证自己的候选。"
        "already-tracked 计支持票；critical 无需 root 读码。"
        "killed 候选直接丢弃。"
    )
    failures.extend(
        deterministic_failure(
            "cross-provider evidence fixture",
            lambda: check_text_contract(
                bad_evidence, AUDIT_EVIDENCE_CONTRACT
            ),
            "cross-provider Audit evidence gate",
        )
    )

    old_layout = {
        ".agents/skills/worker/SKILL.md",
        ".agents/skills/discussion/SKILL.md",
        ".agents/skills/full-audit/SKILL.md",
        ".claude/skills/worker/SKILL.md",
        ".claude/skills/discussion/SKILL.md",
        ".claude/skills/full-audit/SKILL.md",
    }
    failures.extend(
        deterministic_failure(
            "legacy skill layout fixture",
            lambda: skill_layout_contract_errors(old_layout),
            "legacy worker skill directory remains",
        )
    )

    old_role = (
        "你是 implementer。只实现 backlog；遇到非 trivial 方向等待用户拍板。"
    )
    failures.extend(
        deterministic_failure(
            "legacy implementer role fixture",
            lambda: role_contract_errors("implementer", old_role),
            "implementer role",
        )
    )

    old_frontmatter = """---
name: worker
description: Execute one wave.
---
# Worker
"""
    failures.extend(
        deterministic_failure(
            "legacy frontmatter fixture",
            lambda: frontmatter_contract_errors(
                ".agents/skills/steward/SKILL.md",
                old_frontmatter,
                "steward",
            ),
            "frontmatter name must be 'steward'",
        )
    )
    return failures


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args == ["--self-test"]:
        failures = run_self_tests(include_audit_ledger_process=True)
        if failures:
            print("workflow validator self-test failed:")
            for failure in failures:
                print(f"- {failure}")
            return 1
        print(
            "workflow validator self-test passed: "
            "25 legacy/broken fixtures rejected deterministically; "
            "2 durable-ledger regressions passed"
        )
        return 0
    if args:
        print("usage: validate_workflow.py [--self-test]", file=sys.stderr)
        return 2

    self_test_failures = run_self_tests(
        include_audit_ledger_process=False
    )
    if self_test_failures:
        print("workflow validator internal self-test failed:")
        for failure in self_test_failures:
            print(f"- {failure}")
        return 1

    validator = WorkflowValidator(ROOT)
    backlog_count, audit_count = validator.run()
    if validator.errors:
        print("workflow validation failed:")
        for error in validator.errors:
            print(f"- {error}")
        return 1

    print(
        "workflow validation passed: "
        f"{backlog_count} active backlog items, "
        f"{audit_count} active audit items, "
        "2 steward adapters, 4 Codex roles, "
        "25 fast negative fixtures; "
        "run --self-test for 2 durable-ledger process regressions"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
