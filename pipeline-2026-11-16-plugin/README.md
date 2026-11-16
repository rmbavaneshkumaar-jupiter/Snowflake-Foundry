# Foundry DE plugin (skills + hooks)

Version 0.1.0, written 2026-11-16. **Status: offline test passes (18 of 18). In VS Code CoCo (extension 1.44.0) the UserPromptSubmit hook is confirmed to run. SessionStart does NOT fire there. The order gate and report check are not yet tested inside CoCo.**

This plugin packs the 7 Foundry skills with 3 hooks. The hooks make sure:

1. Every new CoCo session shows where the pipeline stands.
2. A skill cannot run before the earlier skills are approved.
3. A skill can only be approved when its report file exists.

The 7 skills in `skills/` are exact copies of `D:\Claude\pipeline-2026-11-14\skills\`. They were not changed.

## Files

| File | What it does |
|---|---|
| `.cortex-plugin/plugin.json` | Plugin manifest. Tells CoCo the plugin name, where the skills are, and where the hooks file is. |
| `hooks/hooks.json` | Connects the 3 hooks to CoCo events: SessionStart, UserPromptSubmit and PreToolUse. |
| `hooks/foundry_hook.py` | The hook logic, one Python file, standard library only (no jq). Also has commands for you: status, approve, revoke, reset. |
| `config/foundry-config.json` | One shared settings file: database, warehouse, role, schemas, WARN 1% / STOP 20%, credit limit 5.0, batch IDs, report folder, skill order. |
| `skills/<7 folders>/SKILL.md` | The 7 skills, unchanged. |
| `tests/test_hooks.py` | Offline test. Sends fake CoCo input to the hook script and checks allow or block. No CoCo or Snowflake needed. |
| `state/foundry_state.json` | Created on the first approval. Records which skill was approved, when, for which batch, and which report. Do not edit by hand. |

## The 3 hooks

| Hook | CoCo event | What happens |
|---|---|---|
| 1. session-resume | SessionStart, and the first prompt of each session | Prints database, warehouse, role, batch, each skill approved or not, and the next skill. In the VS Code chat SessionStart does not fire, so the status comes with your first message instead. |
| 2. phase-order-gate | UserPromptSubmit and PreToolUse | If you type `$skill` (or "run skill") or the agent loads a skill, and an earlier skill is not approved, it is blocked with the reason. |
| 3. report-check | UserPromptSubmit | You type `APPROVE <skill>`. The approval is saved only if `pipeline-reports/<skill>_<batch>_report.md` exists (v2, v3 also count) and all earlier skills are approved. Otherwise it is blocked. |

Example of hook 2:

- Before: you type `$de-deep-schema-design` while de-deep-profile is not approved, and the skill starts anyway.
- After: CoCo shows `[foundry] BLOCKED: Cannot run de-deep-schema-design (step 2). Earlier skill de-deep-profile (step 1, batch B001) is not approved.`

## Design choices

- **Python, not bash + jq.** Your machine is Windows. jq is often missing there. Python with the standard library works the same on Windows, Mac and Linux.
- **Approval moves the state, not "skill finished".** The state changes only when the human types `APPROVE <skill>` or runs the approve command in a terminal.
- **The agent cannot approve by itself.** If the agent tries to run the approve, revoke or reset command, or to write the state file, the hook blocks it.
- **Fail closed.** If the config or state file is broken, or CoCo sends input the hook cannot read, skill runs and approvals are blocked with a clear message. The hook does not need `COCO_SKILL_NAME`.
- **Design skills vs batch skills.** Skills 1 to 4 are approved once (design batch). Skills 5 to 7 are approved again for each new batch. For B002, change `current_batch_id` to `B002`; skills 1 to 4 stay approved.
- **No domain names in the hook.** Every name comes from `config/foundry-config.json`.

## Known risks (not tested in CoCo)

1. If `python` is not installed, the hook command fails and CoCo does not block (CoCo only blocks on exit code 2). Test step 1 checks this.
2. `hooks/hooks.json` uses the full path `D:/Claude/pipeline-2026-11-16-plugin/hooks/foundry_hook.py`, because CoCo may run hooks from the workspace folder. If you move the plugin, change this path in the 3 lines.
3. In the VS Code chat, CoCo runs hooks from the VS Code install folder, not from your workspace. So the script never uses that folder. Set `reports.dir` in the config to a full path, for example `D:/Claude/coco-workspace/pipeline-reports`. A relative path is read from the plugin folder.
4. Every hook call writes one line to `state/hook_calls.log` (and the reason when it blocks). Use it to check that CoCo calls the hooks.
5. Snowflake does not document the tool name CoCo uses to load a skill. The hook watches for any tool whose name contains "skill" and for reads of `<skill>/SKILL.md`. The `$skill` check on your typed prompt does not depend on this.

## How to test in VS Code CoCo

**Step 1. Check Python.** Open a terminal in `D:\Claude\pipeline-2026-11-16-plugin` and run:

```
python --version
```

Expected: Python 3.8 or newer. If it says "not found", try `py --version`. If `py` works, change `python` to `py` in the 3 lines of `hooks/hooks.json`.

**Step 2. Offline test.** In the same terminal:

```
python tests/test_hooks.py
```

Expected: `18 of 18 tests passed.` Your real state file is not touched.

**Step 3. Load the plugin.** Open your CoCo workspace folder in VS Code (the one that has `pipeline-reports`). Copy the whole plugin folder into `<workspace>\.cortex\plugins\foundry-de-pipeline\`. In the CoCo chat type:

```
/plugin reload
/plugin list
```

Expected: `foundry-de-pipeline` is listed as active. Then start a new CoCo session.

**Test hook 1 (session-resume).** Expected at session start: lines starting with `[foundry]`, ending with `Next skill: de-deep-profile (step 1)`. If you see nothing, the hooks did not start: put the full path in the 3 lines of `hooks/hooks.json`, for example `python "D:/Claude/coco-workspace/.cortex/plugins/foundry-de-pipeline/hooks/foundry_hook.py" session-start`, then `/plugin reload`.

**Test hook 2 (phase-order-gate).** Type `$de-deep-schema-design`. Expected: a BLOCKED message that says de-deep-profile is not approved. Nothing runs in Snowflake.

**Test hook 3 (report-check).**

1. Rename `pipeline-reports\de-deep-profile_B001_report.md` to `de-deep-profile_B001_report.md.bak`.
2. Type `APPROVE de-deep-profile`. Expected: BLOCKED, "report file not found".
3. Rename the file back.
4. Type `APPROVE de-deep-profile` again. Expected: `[foundry] APPROVED: de-deep-profile for batch B001` and `Next skill: de-deep-schema-design`.

**Test the safety rule.** Ask CoCo to run `python hooks/foundry_hook.py approve de-deep-schema-design` in the terminal. Expected: BLOCKED, "Only the human can approve".

**After testing.** Check the state in a terminal: `python hooks/foundry_hook.py status`. To clear the test approvals: `python hooks/foundry_hook.py reset --yes`.

## Commands for the human

```
python hooks/foundry_hook.py status
python hooks/foundry_hook.py approve <skill> --workspace <CoCo workspace folder>
python hooks/foundry_hook.py revoke <skill>
python hooks/foundry_hook.py reset --yes
```
