"""
Guardrail for Spectrum-owned player-facing chat output.

Scans parent/child addon Lua (excluding vendored libraries) for chat-emission
call sites, compares them to an audited baseline allowlist, and fails CI when
unapproved sites appear or when an approved site moves into a recurring hot path
without an explicit hotpath_ok marker.

Matching is occurrence-aware: (path, kind, signature) may appear multiple times.
Additional identical call sites fail until approved. Line-number movement alone
does not invalidate an existing approval.

Approve intentional new output by updating the baseline:
  python3 .github/scripts/check_chat_output.py --write-baseline

Canonical policy: SpectrumFederation/AGENTS.md (User-visible messaging).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict, deque
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = REPO_ROOT / ".github" / "chat_output_baseline.json"

ADDON_ROOTS = (
    "SpectrumFederation",
    "SpectrumFederation_CursedSurgeTracker",
    "SpectrumFederation_RCLootCouncilIntegration",
)

SKIP_DIR_NAMES = {
    "Libs",
    "libs",
    ".git",
}

# Recurring-path name hints (named functions).
HOTPATH_NAME_RE = re.compile(
    r"(?i)("
    r"OnUpdate|Heartbeat|HeartBeat|Tick|Ticker|Poll|Retry|Flush|"
    r"Drain|ProcessQueue|OnComm|CommMessage|TimerCallback|OnTimer|"
    r"Schedule|Periodic|MonitorMissed"
    r")"
)

# Anonymous WoW callback contexts that are frequently recurring.
SCRIPT_HANDLER_RE = re.compile(
    r"""(?:SetScript|HookScript)\s*\(\s*['"]"""
    r"""(OnUpdate|OnEvent|OnShow|OnHide|OnSizeChanged)['"]"""
)
TIMER_CALLBACK_RE = re.compile(
    r"""C_Timer\s*\.\s*(NewTicker|NewTimer|After)\s*\("""
)

CALL_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("PrintSuccess", re.compile(r"\b(?:SF:)?PrintSuccess\s*\(")),
    ("PrintInfo", re.compile(r"\b(?:SF:)?PrintInfo\s*\(")),
    ("PrintWarning", re.compile(r"\b(?:SF:)?PrintWarning\s*\(")),
    ("PrintError", re.compile(r"\b(?:SF:)?PrintError\s*\(")),
    ("SystemMessage", re.compile(r"\b(?:SF:)?SystemMessage\s*\(")),
    ("print", re.compile(r"(?<![\w.])print\s*\(")),
    ("DEFAULT_CHAT_FRAME:AddMessage", re.compile(r"\bDEFAULT_CHAT_FRAME\s*:\s*AddMessage\s*\(")),
    ("SendChatMessage", re.compile(r"\bSendChatMessage\s*\(")),
    ("printWithPrefix", re.compile(r"\bprintWithPrefix\s*\(")),
]

FUNCTION_START_RE = re.compile(
    r"^\s*(?:local\s+)?function\s+([A-Za-z_][\w\.:]*)\s*\("
)
ASSIGNED_FUNCTION_RE = re.compile(
    r"^\s*(?:local\s+)?([A-Za-z_][\w\.:]*)\s*=\s*function\s*\("
)
ANON_FUNCTION_RE = re.compile(r"function\s*\(")


@dataclass(frozen=True)
class ChatSite:
    path: str
    line: int
    kind: str
    signature: str
    enclosing: str
    hotpath: bool

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.path, self.kind, self.signature)


def _is_skipped_path(path: Path) -> bool:
    parts = set(path.parts)
    return bool(parts & SKIP_DIR_NAMES)


def _iter_lua_files(roots: Iterable[str]) -> list[Path]:
    files: list[Path] = []
    for root_name in roots:
        root = REPO_ROOT / root_name
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.lua")):
            if _is_skipped_path(path.relative_to(REPO_ROOT)):
                continue
            files.append(path)
    return files


def _strip_line_comment(line: str) -> str:
    """Remove `--` comments outside of simple quoted strings."""
    in_single = False
    in_double = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and (in_single or in_double):
            i += 2
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif (
            ch == "-"
            and not in_single
            and not in_double
            and i + 1 < len(line)
            and line[i + 1] == "-"
        ):
            return line[:i]
        i += 1
    return line


def _mask_string_literals(line: str) -> str:
    """Replace quoted string contents so patterns inside literals are ignored."""

    def repl(match: re.Match[str]) -> str:
        return match.group(0)[0] + (" " * (len(match.group(0)) - 2)) + match.group(0)[-1]

    return re.sub(r"'([^'\\]|\\.)*'|\"([^\"\\]|\\.)*\"", repl, line)


def _normalize_signature(kind: str, raw_line: str) -> str:
    code = " ".join(_strip_line_comment(raw_line).split())
    return f"{kind}|{code[:160]}"


def _callback_context_name(code: str) -> str | None:
    script = SCRIPT_HANDLER_RE.search(code)
    if script:
        return f"<SetScript:{script.group(1)}>"
    timer = TIMER_CALLBACK_RE.search(code)
    if timer:
        return f"<C_Timer.{timer.group(1)}>"
    return None


def _is_hotpath_enclosing(enclosing: str) -> bool:
    if HOTPATH_NAME_RE.search(enclosing):
        return True
    # Anonymous recurring contexts use <SetScript:OnUpdate> / <C_Timer.NewTicker>.
    return enclosing.startswith(("<SetScript:", "<C_Timer."))


def scan_file(path: Path) -> list[ChatSite]:
    rel = path.relative_to(REPO_ROOT).as_posix()
    text = path.read_text(encoding="utf-8", errors="replace")
    sites: list[ChatSite] = []
    # Stack of (indent, name). Indent-based end tracking is approximate.
    stack: list[tuple[int, str]] = []
    # Pending anonymous callback opened by SetScript/NewTicker on a prior line.
    pending_callback: str | None = None

    in_block_comment = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw
        if in_block_comment:
            end = line.find("]]")
            if end == -1:
                continue
            line = line[end + 2 :]
            in_block_comment = False

        while True:
            start = line.find("--[[")
            if start == -1:
                break
            end = line.find("]]", start + 4)
            if end == -1:
                line = line[:start]
                in_block_comment = True
                break
            line = line[:start] + line[end + 2 :]

        code = _strip_line_comment(line)
        indent = len(code) - len(code.lstrip(" \t"))
        # Keep string literals when detecting SetScript("OnUpdate", ...); mask
        # only when matching chat-emission call patterns.
        masked = _mask_string_literals(code)

        callback_name = _callback_context_name(code)
        if callback_name:
            # Same-line anonymous function: frame:SetScript("OnUpdate", function(...)
            if ANON_FUNCTION_RE.search(code):
                while stack and stack[-1][0] >= indent:
                    stack.pop()
                stack.append((indent, callback_name))
                pending_callback = None
            else:
                pending_callback = callback_name

        fn_match = FUNCTION_START_RE.match(code) or ASSIGNED_FUNCTION_RE.match(code)
        if fn_match:
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, fn_match.group(1)))
            pending_callback = None
        elif pending_callback and ANON_FUNCTION_RE.search(code) and not fn_match:
            # Multi-line: SetScript("OnUpdate",\n  function(self, elapsed)
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, pending_callback))
            pending_callback = None
        elif re.match(r"^\s*end\b", code) and stack and indent <= stack[-1][0]:
            if indent == stack[-1][0]:
                stack.pop()

        enclosing = stack[-1][1] if stack else "<module>"
        hotpath = _is_hotpath_enclosing(enclosing)

        for kind, pattern in CALL_PATTERNS:
            if pattern.search(masked):
                signature = _normalize_signature(kind, code)
                sites.append(
                    ChatSite(
                        path=rel,
                        line=lineno,
                        kind=kind,
                        signature=signature,
                        enclosing=enclosing,
                        hotpath=hotpath,
                    )
                )
                break
    return sites


def scan_repo(roots: Iterable[str] = ADDON_ROOTS) -> list[ChatSite]:
    sites: list[ChatSite] = []
    for path in _iter_lua_files(roots):
        sites.extend(scan_file(path))
    sites.sort(key=lambda s: (s.path, s.line, s.kind))
    return sites


def load_baseline(path: Path) -> dict:
    if not path.exists():
        return {"version": 1, "sites": []}
    return json.loads(path.read_text(encoding="utf-8"))


def baseline_entries(data: dict) -> list[dict]:
    sites = data.get("sites") or []
    if not isinstance(sites, list):
        raise TypeError("baseline.sites must be a list")
    return sites


def _entry_key(entry: dict) -> tuple[str, str, str]:
    return (entry["path"], entry["kind"], entry["signature"])


def write_baseline(path: Path, sites: list[ChatSite], previous: dict | None = None) -> None:
    prev_queues: dict[tuple[str, str, str], deque[dict]] = defaultdict(deque)
    if previous:
        for entry in baseline_entries(previous):
            prev_queues[_entry_key(entry)].append(entry)

    out_sites = []
    for site in sites:
        prev_queue = prev_queues.get(site.key)
        prev = prev_queue.popleft() if prev_queue else {}
        out_sites.append(
            {
                "path": site.path,
                "line": site.line,
                "kind": site.kind,
                "signature": site.signature,
                "enclosing": site.enclosing,
                "hotpath_ok": bool(prev.get("hotpath_ok", False)),
                "note": prev.get("note", ""),
            }
        )
    payload = {
        "version": 2,
        "description": (
            "Audited Spectrum-owned player-facing chat output sites. "
            "Matching is occurrence-aware: duplicate identical call sites each "
            "need approval. New sites or hotpath/callback moves require owner "
            "authorization; update with: "
            "python3 .github/scripts/check_chat_output.py --write-baseline"
        ),
        "policy": "SpectrumFederation/AGENTS.md#user-visible-messaging",
        "sites": out_sites,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def compare(sites: list[ChatSite], baseline: dict) -> tuple[list[str], list[str], list[str]]:
    """Return (new_errors, hotpath_errors, removed_warnings).

    Occurrence-aware: each baseline entry covers one matching current site.
    Extra identical (path, kind, signature) occurrences are unapproved.
    """
    entries = baseline_entries(baseline)
    baseline_queues: dict[tuple[str, str, str], deque[dict]] = defaultdict(deque)
    for entry in entries:
        baseline_queues[_entry_key(entry)].append(entry)

    current_queues: dict[tuple[str, str, str], deque[ChatSite]] = defaultdict(deque)
    for site in sites:
        current_queues[site.key].append(site)

    new_errors: list[str] = []
    hotpath_errors: list[str] = []
    removed: list[str] = []

    all_keys = set(baseline_queues) | set(current_queues)
    for key in sorted(all_keys):
        baseline_list = list(baseline_queues.get(key, ()))
        current_list = list(current_queues.get(key, ()))
        shared = min(len(baseline_list), len(current_list))

        for i in range(shared):
            site = current_list[i]
            entry = baseline_list[i]
            if site.hotpath and not entry.get("hotpath_ok"):
                hotpath_errors.append(
                    f"{site.path}:{site.line}: approved chat output moved/resides in "
                    f"recurring path '{site.enclosing}' without hotpath_ok "
                    f"({site.kind})"
                )

        for site in current_list[shared:]:
            new_errors.append(
                f"{site.path}:{site.line}: unapproved chat output ({site.kind}) "
                f"in {site.enclosing}: {site.signature.split('|', 1)[-1][:100]}"
            )

        for entry in baseline_list[shared:]:
            removed.append(
                f"{entry.get('path')}: baseline entry no longer found "
                f"({entry.get('kind')}: {str(entry.get('signature', ''))[:100]})"
            )

    return new_errors, hotpath_errors, removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=DEFAULT_BASELINE,
        help="Path to chat-output baseline JSON",
    )
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="Rewrite the baseline from the current scan (preserves hotpath_ok/note)",
    )
    parser.add_argument(
        "--allow-removed",
        action="store_true",
        help="Do not fail when baseline entries disappear (still fail on new/hotpath)",
    )
    args = parser.parse_args(argv)

    sites = scan_repo()
    if args.write_baseline:
        previous = load_baseline(args.baseline) if args.baseline.exists() else None
        write_baseline(args.baseline, sites, previous)
        print(f"[chat-output] Wrote {len(sites)} sites to {args.baseline}")
        return 0

    if not args.baseline.exists():
        print(
            f"[chat-output] Missing baseline {args.baseline}. "
            "Generate with --write-baseline after owner review.",
            file=sys.stderr,
        )
        return 1

    baseline = load_baseline(args.baseline)
    new_errors, hotpath_errors, removed = compare(sites, baseline)

    print(f"[chat-output] Scanned {len(sites)} chat-emission sites")
    print(f"[chat-output] Baseline has {len(baseline_entries(baseline))} approved sites")

    failed = False
    if new_errors:
        failed = True
        print("\n[chat-output] NEW unapproved chat-output sites:", file=sys.stderr)
        for line in new_errors:
            print(f"  - {line}", file=sys.stderr)
        print(
            "\n[chat-output] New player-facing chat output requires explicit owner "
            "authorization. Prefer SF.Debug. If authorized, update the baseline:\n"
            "  python3 .github/scripts/check_chat_output.py --write-baseline",
            file=sys.stderr,
        )

    if hotpath_errors:
        failed = True
        print("\n[chat-output] Hot-path chat-output violations:", file=sys.stderr)
        for line in hotpath_errors:
            print(f"  - {line}", file=sys.stderr)
        print(
            "\n[chat-output] Recurring paths must not gain chat output without "
            "hotpath_ok (and anti-spam design). Set hotpath_ok in the baseline "
            "only after owner authorization.",
            file=sys.stderr,
        )

    if removed:
        print("\n[chat-output] Baseline entries missing from scan:")
        for line in removed:
            print(f"  - {line}")
        if not args.allow_removed:
            failed = True
            print(
                "\n[chat-output] Update the baseline after intentional removals:\n"
                "  python3 .github/scripts/check_chat_output.py --write-baseline",
                file=sys.stderr,
            )

    if failed:
        print("[chat-output] FAILED", file=sys.stderr)
        return 1

    print("[chat-output] PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
