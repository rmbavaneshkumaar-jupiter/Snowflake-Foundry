#!/usr/bin/env python3
"""
foundry_hook.py - hook script for the Foundry DE plugin (CoCo / Cortex Code).

Standard library only (no jq, no pip installs). Python 3.8 or newer.
Works on Windows, macOS and Linux.

HOOK COMMANDS (CoCo calls these and sends one JSON object on stdin):
  session-start   Hook 1 "session-resume": prints batch, approved skills and the next skill.
  prompt-submit   Hook 2 "phase-order-gate" (chat side) and Hook 3 "report-check":
                  - "APPROVE <skill>" typed by the human: records approval, but only if
                    the skill's report file exists and all earlier skills are approved.
                  - a prompt that runs a skill ($skill, /skill, "run skill"): blocked
                    unless every earlier skill is approved.
  pre-tool        Hook 2 "phase-order-gate" (tool side): blocks the agent from loading a
                  skill out of order, and from approving / changing state by itself.

HUMAN COMMANDS (you type these in a terminal):
  python hooks/foundry_hook.py status
  python hooks/foundry_hook.py approve <skill> [--workspace <folder>]
  python hooks/foundry_hook.py revoke  <skill>
  python hooks/foundry_hook.py reset --yes

EXIT CODES (CoCo rule): 0 = allow, 2 = block (the text on stderr is the reason).

FAIL CLOSED: if the config or state file cannot be read, or the hook input is not
valid JSON, skill runs and approvals are BLOCKED with a loud message. The hook never
silently allows a skill it cannot check. It does not depend on COCO_SKILL_NAME
(it uses that variable only as an extra hint when it is set).

All Snowflake names, skill names, batch ids and folders come from
config/foundry-config.json. Nothing about a domain is written in this script.
"""

import datetime
import glob
import json
import os
import re
import sys

TAG = "[foundry]"
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(HOOK_DIR)
CONFIG_PATH = os.environ.get(
    "FOUNDRY_CONFIG", os.path.join(PLUGIN_ROOT, "config", "foundry-config.json")
)
STATE_PATH = os.environ.get(
    "FOUNDRY_STATE", os.path.join(PLUGIN_ROOT, "state", "foundry_state.json")
)

ALLOW = 0
BLOCK = 2


class HookError(Exception):
    """A problem that must block (fail closed)."""


# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

_OUT = []


def say(text):
    """Text for the agent / user. Buffered, printed at the end when the hook allows.
    CoCo adds plain stdout as context."""
    _OUT.append(text.rstrip())


def flush_out():
    if _OUT:
        sys.stdout.write("\n".join(_OUT) + "\n")
        del _OUT[:]


def block(reason):
    """Block in BOTH ways the CoCo docs describe, so either one works:
    1) stdout is ONLY a JSON object {"decision": "block", "reason": ...}
    2) the reason on stderr and exit code 2.
    Any buffered status text is dropped so stdout stays valid JSON."""
    msg = (TAG + " BLOCKED: " + reason.rstrip()
           + " Do not run this skill. Tell the user it is blocked and why.")
    del _OUT[:]
    out = {"decision": "block", "reason": msg}
    if len(sys.argv) > 1 and sys.argv[1] == "pre-tool":
        out["hookSpecificOutput"] = {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                     "permissionDecisionReason": msg}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    sys.stderr.write(msg + "\n")
    log_call("  -> BLOCKED: " + reason)
    sys.exit(BLOCK)


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def load_config():
    if not os.path.isfile(CONFIG_PATH):
        raise HookError("Config file not found: " + CONFIG_PATH)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except ValueError as e:
        raise HookError("Config file is not valid JSON (" + CONFIG_PATH + "): " + str(e))

    try:
        skills = cfg["pipeline"]["skills"]
        skills = sorted(skills, key=lambda s: int(s["step"]))
        for s in skills:
            if s.get("scope") not in ("design", "batch"):
                raise HookError("Skill " + str(s.get("name")) + ": scope must be design or batch")
            if not re.match(r"^[a-z0-9][a-z0-9-]*$", s.get("name", "")):
                raise HookError("Bad skill name in config: " + repr(s.get("name")))
        design_batch = str(cfg["batch"]["design_batch_id"]).strip()
        current_batch = str(cfg["batch"]["current_batch_id"]).strip()
        if not design_batch or not current_batch:
            raise HookError("design_batch_id and current_batch_id must not be empty")
        cfg["_skills"] = skills
        cfg["_names"] = [s["name"] for s in skills]
        cfg["_keyword"] = str(cfg.get("approval", {}).get("keyword", "APPROVE")).strip() or "APPROVE"
        rep = cfg.get("reports", {})
        cfg["_report_dir"] = rep.get("dir", "pipeline-reports")
        cfg["_report_pattern"] = rep.get("file_pattern", "{skill}_{batch}_report*.md")
    except (KeyError, TypeError) as e:
        raise HookError("Config file is missing a required key: " + str(e))
    if not cfg["_skills"]:
        raise HookError("Config lists no skills under pipeline.skills")
    return cfg


def skill_info(cfg, name):
    for i, s in enumerate(cfg["_skills"]):
        if s["name"] == name:
            return i, s
    return -1, None


def scope_key(cfg, skill):
    """State bucket for a skill: design:<design batch> or batch:<current batch>."""
    if skill["scope"] == "design":
        return "design:" + cfg["batch"]["design_batch_id"]
    return "batch:" + cfg["batch"]["current_batch_id"]


def batch_for(cfg, skill):
    return scope_key(cfg, skill).split(":", 1)[1]


# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

def load_state():
    if not os.path.isfile(STATE_PATH):
        return {"version": 1, "approvals": {}, "history": []}
    try:
        with open(STATE_PATH, "r", encoding="utf-8-sig") as f:
            st = json.load(f)
        if not isinstance(st.get("approvals"), dict):
            raise ValueError("approvals is not an object")
        st.setdefault("history", [])
        return st
    except ValueError as e:
        raise HookError(
            "State file is damaged (" + STATE_PATH + "): " + str(e)
            + ". Fix it by hand or run: python hooks/foundry_hook.py reset --yes"
        )


def save_state(st):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=2)
    os.replace(tmp, STATE_PATH)


def is_approved(cfg, st, skill):
    return skill["name"] in st["approvals"].get(scope_key(cfg, skill), {})


def missing_before(cfg, st, index):
    """First earlier skill that is not approved, or None."""
    for s in cfg["_skills"][:index]:
        if not is_approved(cfg, st, s):
            return s
    return None


def next_skill(cfg, st):
    for s in cfg["_skills"]:
        if not is_approved(cfg, st, s):
            return s
    return None


# --------------------------------------------------------------------------
# Reports
# --------------------------------------------------------------------------

def reports_dir(cfg, workspace):
    # A relative path is read from the --workspace folder (terminal) or, in hooks,
    # from the plugin folder. CoCo in VS Code runs hooks from the VS Code install
    # folder, so the hook's cwd is NOT used. Best: put a full path in the config.
    d = os.path.expandvars(os.path.expanduser(cfg["_report_dir"]))
    if not os.path.isabs(d):
        d = os.path.join(workspace or PLUGIN_ROOT, d)
    return os.path.normpath(d)


def find_report(cfg, skill, workspace):
    """Newest non-empty report file for this skill and its batch, or None."""
    d = reports_dir(cfg, workspace)
    pattern = cfg["_report_pattern"].format(skill=skill["name"], batch=batch_for(cfg, skill))
    hits = [p for p in glob.glob(os.path.join(d, pattern)) if os.path.isfile(p) and os.path.getsize(p) > 0]
    if not hits:
        return None, os.path.join(d, pattern)
    hits.sort(key=os.path.getmtime, reverse=True)
    return hits[0], os.path.join(d, pattern)


# --------------------------------------------------------------------------
# Status text (Hook 1)
# --------------------------------------------------------------------------

def status_text(cfg, st):
    sf = cfg.get("snowflake", {})
    lines = [
        TAG + " Foundry DE pipeline status",
        TAG + " Database " + str(sf.get("database")) + " | Warehouse " + str(sf.get("warehouse"))
        + " | Role " + str(sf.get("role"))
        + " | Design batch " + cfg["batch"]["design_batch_id"]
        + " | Current batch " + cfg["batch"]["current_batch_id"],
    ]
    for s in cfg["_skills"]:
        rec = st["approvals"].get(scope_key(cfg, s), {}).get(s["name"])
        mark = "APPROVED " + rec["approved_at"] if rec else "not approved"
        lines.append(TAG + "   " + str(s["step"]) + ". " + s["name"] + " (" + batch_for(cfg, s) + "): " + mark)
    nxt = next_skill(cfg, st)
    if nxt:
        lines.append(TAG + " Next skill: " + nxt["name"] + " (step " + str(nxt["step"]) + ")")
    else:
        lines.append(TAG + " All skills approved for batch " + cfg["batch"]["current_batch_id"] + ".")
    lines.append(TAG + " Use role " + str(sf.get("role")) + ". After a skill finishes and you agree, type: "
                 + cfg["_keyword"] + " <skill-name>")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Approval (Hook 3, report-check)
# --------------------------------------------------------------------------

def approve(cfg, st, name, workspace, who):
    i, s = skill_info(cfg, name)
    if s is None:
        raise HookError("Unknown skill '" + name + "'. Known skills: " + ", ".join(cfg["_names"]))
    if is_approved(cfg, st, s):
        return TAG + " " + name + " is already approved for batch " + batch_for(cfg, s) + ". Nothing changed."
    miss = missing_before(cfg, st, i)
    if miss:
        raise HookError(
            "Cannot approve " + name + ": earlier skill " + miss["name"] + " (step "
            + str(miss["step"]) + ") is not approved yet."
        )
    report, looked = find_report(cfg, s, workspace)
    if not report:
        raise HookError(
            "Cannot approve " + name + ": report file not found or empty. Looked for: " + looked
            + ". Ask the skill to finish its Final Step and save the report, then approve again."
        )
    key = scope_key(cfg, s)
    st["approvals"].setdefault(key, {})[name] = {"approved_at": now_utc(), "report": report, "by": who}
    st["history"].append({"at": now_utc(), "action": "approve", "skill": name, "bucket": key, "by": who})
    save_state(st)
    nxt = next_skill(cfg, st)
    msg = TAG + " APPROVED: " + name + " for batch " + batch_for(cfg, s) + ". Report: " + report
    msg += "\n" + TAG + (" Next skill: " + nxt["name"] if nxt else " All skills approved.")
    return msg


# --------------------------------------------------------------------------
# Skill detection
# --------------------------------------------------------------------------

def _name_re(name):
    # whole name only: de-deep-transform must not match de-deep-transform-setup
    return r"(?<![\w-])" + re.escape(name) + r"(?![\w-])"


def skills_in_prompt(cfg, prompt):
    """Skills the human asks to RUN in this prompt."""
    found = []
    for n in cfg["_names"]:
        nr = _name_re(n)
        direct = re.search(r"[\$/]" + re.escape(n) + r"(?![\w-])", prompt)
        verb = re.search(r"\b(run|use|start|execute|invoke|launch|begin)\b[^\n.]{0,60}" + nr, prompt, re.I)
        if direct or verb:
            found.append(n)
    return found


def all_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            for s in all_strings(v):
                yield s
    elif isinstance(obj, list):
        for v in obj:
            for s in all_strings(v):
                yield s


def skills_in_tool(cfg, tool_name, tool_input):
    """Skills the agent is loading with this tool call."""
    found = set()
    strings = list(all_strings(tool_input))
    tn = (tool_name or "").lower()
    if "skill" in tn:
        for v in strings:
            v2 = v.strip().lstrip("$/")
            v2 = re.split(r"[:/\\]", v2)[-1]  # drop a plugin prefix like plugin:skill
            if v2 in cfg["_names"]:
                found.add(v2)
    for v in strings:
        for n in cfg["_names"]:
            if re.search(re.escape(n) + r"[\\/]+SKILL\.md", v, re.I):
                found.add(n)
    env_name = os.environ.get("COCO_SKILL_NAME", "").strip()
    if env_name:
        env_name = re.split(r"[:/\\]", env_name)[-1]
        if env_name in cfg["_names"]:
            found.add(env_name)
    return sorted(found, key=lambda n: skill_info(cfg, n)[0])


def touches_approval(tool_input):
    """True if the agent tries to approve, revoke, reset or edit the state file itself."""
    state_name = os.path.basename(STATE_PATH).lower()
    for v in all_strings(tool_input):
        low = v.lower()
        if state_name in low or "session_locks.json" in low:
            return True
        if re.search(r"foundry_hook\.py['\"]?\s+(approve|revoke|reset)\b", low):
            return True
    return False


def first_prompt_of_session(sid):
    """True the first time a session id is seen. Kept in state/sessions_seen.json."""
    path = os.path.join(os.path.dirname(STATE_PATH), "sessions_seen.json")
    try:
        seen = json.load(open(path, encoding="utf-8")) if os.path.isfile(path) else []
    except Exception:
        seen = []
    if sid in seen:
        return False
    seen = (seen + [sid])[-200:]
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(seen, f)
    except Exception:
        pass
    return True


def gate_reason(cfg, st, names):
    """Reason text if any requested skill has an earlier skill not approved, else None."""
    for n in names:
        i, s = skill_info(cfg, n)
        miss = missing_before(cfg, st, i)
        if miss:
            return (
                "Cannot run " + n + " (step " + str(s["step"]) + "). Earlier skill " + miss["name"]
                + " (step " + str(miss["step"]) + ", batch " + batch_for(cfg, miss)
                + ") is not approved. Run it, check its report, then type: "
                + cfg["_keyword"] + " " + miss["name"]
            )
    return None


def gate(cfg, st, names, sid=""):
    """Block if any requested skill is out of order. With a session id, also LOCK the
    session: CoCo may still pass the prompt to the agent (UserPromptSubmit blocks are
    only advisory in CoCo CLI 1.2.45), so every later TOOL call in that session is
    denied by the pre-tool hook until the missing skill is approved."""
    reason = gate_reason(cfg, st, names)
    if reason:
        if sid:
            set_lock(sid, names)
        block(reason)


# ---- session locks (state/session_locks.json) ----

LOCKS_PATH = os.path.join(os.path.dirname(STATE_PATH), "session_locks.json")


def load_locks():
    if not os.path.isfile(LOCKS_PATH):
        return {}
    try:
        with open(LOCKS_PATH, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("not an object")
        return d
    except ValueError as e:
        raise HookError("Lock file is damaged (" + LOCKS_PATH + "): " + str(e)
                        + ". Run: python hooks/foundry_hook.py reset --yes")


def save_locks(d):
    os.makedirs(os.path.dirname(LOCKS_PATH), exist_ok=True)
    tmp = LOCKS_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, LOCKS_PATH)


def set_lock(sid, names):
    try:
        d = load_locks()
    except HookError:
        d = {}
    d[sid] = {"skills": sorted(set(d.get(sid, {}).get("skills", []) + list(names))), "at": now_utc()}
    save_locks(d)


# --------------------------------------------------------------------------
# Hook entry points
# --------------------------------------------------------------------------

LOG_PATH = os.path.join(os.path.dirname(STATE_PATH), "hook_calls.log")


def log_call(text):
    """Append one line to state/hook_calls.log so we can see if CoCo calls the hooks.
    Never fails the hook."""
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(now_utc() + " " + text.replace("\n", " ")[:300] + "\n")
    except Exception:
        pass


def read_stdin_json():
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    try:
        peek = json.loads(raw) if raw.strip() else {}
        log_call("cmd=" + sys.argv[1] + " event=" + str(peek.get("hook_event_name"))
                 + " tool=" + str(peek.get("tool_name")) + " cwd=" + str(peek.get("cwd")))
    except Exception:
        log_call("cmd=" + sys.argv[1] + " input-not-json len=" + str(len(raw)))
    if not raw.strip():
        raise HookError("Hook received no input from CoCo (empty stdin).")
    try:
        data = json.loads(raw)
    except ValueError as e:
        raise HookError("Hook input is not valid JSON: " + str(e))
    if not isinstance(data, dict):
        raise HookError("Hook input is not a JSON object.")
    return data


def hook_session_start():
    # Never blocks; it only informs. Problems are shown loudly.
    try:
        data = read_stdin_json()
    except HookError:
        data = {}
    try:
        cfg = load_config()
        st = load_state()
        say(status_text(cfg, st))
    except HookError as e:
        say(TAG + " WARNING: hooks cannot read their files. Skill runs and approvals will be BLOCKED until this is fixed.")
        say(TAG + " Reason: " + str(e))
    return ALLOW


def hook_prompt_submit():
    try:
        data = read_stdin_json()
        cfg = load_config()
        st = load_state()
    except HookError as e:
        block(str(e) + " Fix this first (fail closed).")
    prompt = str(data.get("prompt", ""))
    workspace = None  # hook cwd is not reliable (VS Code install folder); see reports_dir

    # SessionStart does not fire in the VS Code CoCo chat. So on the first prompt
    # of each session, show the status here instead.
    sid = str(data.get("session_id") or "")
    if sid and first_prompt_of_session(sid):
        say(status_text(cfg, st))

    m = re.match(r"^\s*" + re.escape(cfg["_keyword"]) + r"D?\s+[\$/]?([A-Za-z0-9-]+)\s*$", prompt, re.I)
    if m:
        try:
            say(approve(cfg, st, m.group(1).lower(), workspace, who="human (chat)"))
        except HookError as e:
            block(str(e))
        return ALLOW

    gate(cfg, st, skills_in_prompt(cfg, prompt), sid)
    return ALLOW


def hook_pre_tool():
    try:
        data = read_stdin_json()
    except HookError as e:
        block(str(e) + " Tool call stopped (fail closed).")
    tool_name = str(data.get("tool_name", ""))
    tool_input = data.get("tool_input", {})

    if touches_approval(tool_input):
        block("Only the human can approve, revoke or reset skills, or edit the state file. "
              "The human types '<keyword> <skill>' in chat or runs the command in a terminal.")

    try:
        cfg = load_config()
        st = load_state()
    except HookError as e:
        if "skill" in tool_name.lower():
            block(str(e) + " Skill call stopped (fail closed).")
        sys.stderr.write(TAG + " WARNING: " + str(e) + "\n")
        return ALLOW

    sid = str(data.get("session_id") or "")
    if sid:
        try:
            locks = load_locks()
        except HookError as e:
            block(str(e) + " Tool call stopped (fail closed).")
        lock = locks.get(sid)
        if lock:
            reason = gate_reason(cfg, st, [n for n in lock.get("skills", []) if n in cfg["_names"]])
            if reason:
                block("This session asked for a skill out of order, so ALL tool calls in this "
                      "session are stopped. " + reason + " Then start a new session.")
            locks.pop(sid, None)  # the missing approval was given: unlock
            save_locks(locks)

    gate(cfg, st, skills_in_tool(cfg, tool_name, tool_input), sid)
    return ALLOW


# --------------------------------------------------------------------------
# Human commands
# --------------------------------------------------------------------------

def arg_value(args, flag):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def human(cmd, args):
    try:
        cfg = load_config()
        st = load_state() if cmd != "reset" else None
    except HookError as e:
        print(TAG + " ERROR: " + str(e))
        return 1

    if cmd == "status":
        print(status_text(cfg, st))
        return 0

    if cmd == "approve":
        if not args:
            print("Usage: python hooks/foundry_hook.py approve <skill> [--workspace <folder>]")
            return 1
        try:
            print(approve(cfg, st, args[0], arg_value(args, "--workspace"), who="human (terminal)"))
            return 0
        except HookError as e:
            print(TAG + " NOT APPROVED: " + str(e))
            return 1

    if cmd == "revoke":
        if not args:
            print("Usage: python hooks/foundry_hook.py revoke <skill>")
            return 1
        i, s = skill_info(cfg, args[0])
        if s is None:
            print(TAG + " Unknown skill: " + args[0])
            return 1
        bucket = st["approvals"].get(scope_key(cfg, s), {})
        if bucket.pop(s["name"], None) is None:
            print(TAG + " " + s["name"] + " was not approved. Nothing changed.")
            return 0
        st["history"].append({"at": now_utc(), "action": "revoke", "skill": s["name"],
                              "bucket": scope_key(cfg, s), "by": "human (terminal)"})
        save_state(st)
        print(TAG + " Revoked " + s["name"] + ". Later skills are blocked until it is approved again.")
        return 0

    if cmd == "reset":
        if "--yes" not in args:
            print("This deletes all recorded approvals. Run again with --yes to confirm.")
            return 1
        if os.path.isfile(STATE_PATH):
            os.replace(STATE_PATH, STATE_PATH + "." + datetime.datetime.now().strftime("%Y%m%d%H%M%S") + ".bak")
        if os.path.isfile(LOCKS_PATH):
            os.remove(LOCKS_PATH)
        print(TAG + " State and session locks cleared (old state kept as .bak). Start with step 1.")
        return 0

    print(__doc__)
    return 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    try:
        if cmd == "session-start":
            rc = hook_session_start()
            flush_out()
            return rc
        if cmd == "prompt-submit":
            rc = hook_prompt_submit()
            flush_out()
            return rc
        if cmd == "pre-tool":
            rc = hook_pre_tool()
            flush_out()
            return rc
        return human(cmd, sys.argv[2:])
    except SystemExit:
        raise
    except Exception as e:  # any surprise: block hook events, never fail open
        if cmd in ("prompt-submit", "pre-tool"):
            block("Unexpected hook error: " + repr(e) + " (fail closed).")
        print(TAG + " ERROR: " + repr(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
