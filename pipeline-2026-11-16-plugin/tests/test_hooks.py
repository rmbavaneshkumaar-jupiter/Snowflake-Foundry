#!/usr/bin/env python3
"""
Offline test of hooks/foundry_hook.py. No CoCo and no Snowflake needed.

It sends the same kind of JSON that CoCo sends to each hook and checks the exit code
(0 = allow, 2 = block). It uses a temporary state file and a temporary workspace,
so your real approvals are NOT touched.

Run from the plugin folder:
    python tests/test_hooks.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "hooks", "foundry_hook.py")
CFG = json.load(open(os.path.join(ROOT, "config", "foundry-config.json"), encoding="utf-8-sig"))
SKILLS = [s["name"] for s in sorted(CFG["pipeline"]["skills"], key=lambda s: s["step"])]
BATCH = CFG["batch"]["design_batch_id"]
KEY = CFG.get("approval", {}).get("keyword", "APPROVE")

tmp = tempfile.mkdtemp(prefix="foundry-test-")
workspace = os.path.join(tmp, "workspace")
reports = os.path.join(workspace, CFG["reports"]["dir"])
os.makedirs(reports)
# test copy of the config with a full path to the temporary reports folder
test_cfg = dict(CFG)
test_cfg["reports"] = dict(CFG["reports"], dir=reports)
cfg_path = os.path.join(tmp, "foundry-config.json")
with open(cfg_path, "w") as f:
    json.dump(test_cfg, f)
env = dict(os.environ, FOUNDRY_STATE=os.path.join(tmp, "state", "foundry_state.json"), FOUNDRY_CONFIG=cfg_path)
env.pop("COCO_SKILL_NAME", None)

results = []


def run(cmd, payload=None, raw=None):
    data = raw if raw is not None else json.dumps(payload or {})
    p = subprocess.run([sys.executable, HOOK, cmd], input=data, capture_output=True, text=True, env=env)
    return p.returncode, (p.stdout + p.stderr).strip()


def check(name, got, want, out):
    ok = got == want
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + "  (exit " + str(got) + ", expected " + str(want) + ")")
    if not ok or "-v" in sys.argv:
        print("     " + out.replace("\n", "\n     "))


def prompt(text):
    return {"hook_event_name": "UserPromptSubmit", "cwd": workspace, "session_id": "t", "prompt": text}


def tool(name, tinput, sid="other-session"):
    return {"hook_event_name": "PreToolUse", "cwd": workspace, "session_id": sid,
            "tool_name": name, "tool_input": tinput}


def write_report(skill):
    with open(os.path.join(reports, skill + "_" + BATCH + "_report.md"), "w") as f:
        f.write("# report\n")


s1, s2, s3 = SKILLS[0], SKILLS[1], SKILLS[2]

# Hook 1: session-resume
rc, out = run("session-start", {"hook_event_name": "SessionStart", "cwd": workspace})
check("H1 session start shows status and next skill " + s1, rc if ("Next skill: " + s1) in out else -1, 0, out)

rc, out = run("prompt-submit", dict(prompt("hello"), session_id="new-session-1"))
check("H1b first prompt of a new session shows status", rc if "Next skill: " + s1 in out else -1, 0, out)
rc, out = run("prompt-submit", dict(prompt("hello again"), session_id="new-session-1"))
check("H1b second prompt of same session shows no status", rc if "Next skill" not in out else -1, 0, out)

# Hook 2: phase-order-gate
rc, out = run("prompt-submit", prompt("$" + s1 + " batch " + BATCH))
check("H2 run step 1 allowed", rc, 0, out)
rc, out = run("prompt-submit", prompt("$" + s2 + " please"))
check("H2 run step 2 before step 1 approved is BLOCKED", rc, 2, out)
rc, out = run("pre-tool", tool("skill", {"skill": s2}))
check("H2 agent loads step 2 skill tool is BLOCKED", rc, 2, out)
rc, out = run("pre-tool", tool("read", {"file_path": "skills/" + s2 + "/SKILL.md"}))
check("H2 agent reads step 2 SKILL.md is BLOCKED", rc, 2, out)
rc, out = run("pre-tool", tool("bash", {"command": "ls"}, sid="clean-session"))
check("H2 normal tool call in a clean session allowed", rc, 0, out)
rc, out = run("pre-tool", tool("bash", {"command": "ls"}, sid="t"))
check("H2 LOCK: any tool in the session that asked for step 2 too early is BLOCKED", rc, 2, out)
rc, out = run("prompt-submit", prompt("what does " + s2 + " do?"))
check("H2 question that only names a skill is allowed", rc, 0, out)

# Hook 3: report-check
rc, out = run("prompt-submit", prompt(KEY + " " + s1))
check("H3 approve step 1 with NO report is BLOCKED", rc, 2, out)
write_report(s1)
rc, out = run("prompt-submit", prompt(KEY + " " + s1))
check("H3 approve step 1 WITH report is allowed", rc, 0, out)
rc, out = run("prompt-submit", prompt("$" + s2))
check("H2 run step 2 after step 1 approved is allowed", rc, 0, out)
rc, out = run("pre-tool", tool("bash", {"command": "ls"}, sid="t"))
check("H2 LOCK is released after the missing skill is approved", rc, 0, out)
write_report(s3)
rc, out = run("prompt-submit", prompt(KEY + " " + s3))
check("H3 approve step 3 while step 2 not approved is BLOCKED", rc, 2, out)

# Safety: agent cannot approve by itself
rc, out = run("pre-tool", tool("bash", {"command": "python hooks/foundry_hook.py approve " + s2}))
check("Agent running approve command is BLOCKED", rc, 2, out)
rc, out = run("pre-tool", tool("write", {"file_path": "state/foundry_state.json", "content": "{}"}))
check("Agent writing the state file is BLOCKED", rc, 2, out)

# Fail closed
rc, out = run("prompt-submit", raw="not json")
check("Fail closed: bad hook input is BLOCKED", rc, 2, out)
rc, out = run("pre-tool", raw="")
check("Fail closed: empty hook input is BLOCKED", rc, 2, out)
with open(env["FOUNDRY_STATE"], "w") as f:
    f.write("{broken")
rc, out = run("prompt-submit", prompt("$" + s2))
check("Fail closed: damaged state file is BLOCKED", rc, 2, out)

shutil.rmtree(tmp, ignore_errors=True)
print("")
print(str(sum(results)) + " of " + str(len(results)) + " tests passed.")
sys.exit(0 if all(results) else 1)
