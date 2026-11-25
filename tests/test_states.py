#!/usr/bin/python3
"""State transition tests: feeds hook events and fake transcripts to bin/agent-status
in a throwaway state folder and checks what it decides.

    /usr/bin/python3 tests/test_states.py
"""
import json, os, shutil, subprocess, sys, tempfile, time
BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "agent-status")
D = tempfile.mkdtemp(prefix="agent-status-test-")
# A home of our own, so the apps' real files (Claude Desktop, Codex) stay out of it.
HOME = os.path.join(D, "home")
os.makedirs(HOME)
base = dict(os.environ, AGENT_STATUS_DIR=D, CLAUDE_CODE_ENTRYPOINT="cli", HOME=HOME)
for _k in ("CLAUDE_CODE_HOST_SESSION_ID", "T3CODE_THREAD_ID", "T3_ACP_MCP_NODE",
           "T3_ACP_MCP_ENDPOINT", "T3_ACP_MCP_AUTHORIZATION", "__CFBundleIdentifier"):
    base.pop(_k, None)
os.makedirs(D, exist_ok=True)
def iso(): return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
class S:
    def __init__(s, sid, env, tool="claude", meta=None):
        s.sid, s.env, s.tool = sid, env, tool; s.tr = os.path.join(D, sid + ".jsonl")
        with open(s.tr, "w") as f:
            if meta is not None:  # a Codex rollout starts with its session_meta line
                f.write(json.dumps({"type": "session_meta", "payload": meta}) + "\n")
    def line(s, d): open(s.tr, "a").write(json.dumps(dict(d, timestamp=iso())) + "\n")
    def hook(s, ev, **kw):
        data = dict(hook_event_name=ev, session_id=s.sid, cwd="/tmp/p", transcript_path=s.tr)
        data.update(kw)
        subprocess.run([BIN, "hook", s.tool], input=json.dumps(data), text=True, env=s.env)
    def state(s):
        for r in json.loads(subprocess.run([BIN, "dump"], capture_output=True, text=True, env=base).stdout):
            if r["session_id"] == s.sid and not r.get("hidden"):
                return "%s/%s/%s" % (r["state"], r.get("reason") or "-", "seen" if r.get("seen") else "unseen")
        return "hidden"
    def check(s, label, want):
        got = s.state(); print("ok  " if got == want else "FAIL", label, got, "" if got == want else "(want %s)" % want)
        if got != want:
            FAILED.append(label)
FAILED = []
END = {"type": "assistant", "message": {"stop_reason": "end_turn", "content": []}}
a = S("cli-1", base)
a.hook("UserPromptSubmit", prompt="hi"); a.line({"type": "user", "message": {"content": "hi"}})
a.check("prompt sent", "running/-/seen")
a.line({"type": "assistant", "message": {"stop_reason": "tool_use", "content": []}}); time.sleep(.2)
a.hook("PermissionRequest", tool_name="Bash"); a.check("approval asked", "waiting/permission/seen")
time.sleep(3); a.line({"type": "user", "message": {"content": [{"type": "tool_result", "content": "[Request interrupted by user for tool use]"}]}})
a.check("denied, no hook", "idle/interrupted/seen")
a.hook("UserPromptSubmit", prompt="2"); time.sleep(3); a.line(END)
a.check("finished, Stop missed", "done/-/unseen")
subprocess.run([BIN, "open", "claude-cli-1"], env=dict(base, PATH="/nonexistent"), capture_output=True)
a.check("clicked in menu", "done/-/seen")
a.hook("UserPromptSubmit", prompt="3"); time.sleep(3); a.line({"type": "user", "message": {"content": "[Request interrupted by user]"}})
a.check("Esc, no hook", "idle/interrupted/seen")
a.hook("UserPromptSubmit", prompt="4"); a.hook("Stop"); a.check("Stop hook", "done/-/unseen")
a.hook("SessionEnd", reason="other"); a.check("CLI session closed", "hidden")
# A Desktop session: the app ends sessions when it quits and resumes them later.
d = S("desk-1", dict(base, CLAUDE_CODE_ENTRYPOINT="claude-desktop", CLAUDE_CODE_HOST_SESSION_ID="local_test-desk-1"))
d.hook("UserPromptSubmit", prompt="x"); d.line(END); d.hook("Stop")
d.check("desktop turn done", "done/-/unseen")
d.hook("SessionEnd", reason="other"); d.check("app quit keeps it", "done/-/unseen")
d.hook("SessionStart", source="resume"); d.check("app resumes it", "done/-/unseen")
# A session we never saw before, resumed after its turn already finished: an old
# chat reopened, not news.
n = S("new-1", base); n.line(END); time.sleep(1)
n.hook("SessionStart", source="resume"); n.check("old chat reopened", "done/-/seen")

# Claude Desktop's own unread marks decide for chats whose finish we didn't watch.
def desktop_session(cli_id, desk_id):
    p = os.path.join(HOME, "Library/Application Support/Claude/claude-code-sessions/a/b")
    os.makedirs(p, exist_ok=True)
    now_ms = int(time.time() * 1000)
    json.dump({"sessionId": desk_id, "cliSessionId": cli_id, "cwd": "/tmp/p", "title": cli_id,
               "lastActivityAt": now_ms, "lastFocusedAt": now_ms - 3600 * 1000, "isArchived": False},
              open(os.path.join(p, desk_id + ".json"), "w"))
def desktop_unread(ids):
    """Writes Desktop's Local Storage the way Chromium does: one LevelDB log record."""
    def varint(n):
        out = b""
        while n >= 0x80: out += bytes([n & 0x7F | 0x80]); n >>= 7
        return out + bytes([n])
    key = b"_https://claude.ai\x00\x01epitaxy-unread-v1"
    val = b"\x01" + json.dumps({"state": {"unreadIds": ids, "explicitUnreadIds": [], "stoppedRuns": []},
                                "version": 0}).encode()
    batch = (1).to_bytes(8, "little") + (1).to_bytes(4, "little") + b"\x01" + varint(len(key)) + key + varint(len(val)) + val
    p = os.path.join(HOME, "Library/Application Support/Claude/Local Storage/leveldb")
    os.makedirs(p, exist_ok=True)
    open(os.path.join(p, "000003.log"), "wb").write(b"\0\0\0\0" + len(batch).to_bytes(2, "little") + b"\x01" + batch)
desktop_unread(["local_dd-unread"])
desk = dict(base, CLAUDE_CODE_ENTRYPOINT="claude-desktop")
for sid, want in (("dd-unread", "done/-/unseen"), ("dd-read", "done/-/seen")):
    desktop_session(sid, "local_" + sid)
    s = S(sid, dict(desk, CLAUDE_CODE_HOST_SESSION_ID="local_" + sid)); s.line(END); time.sleep(1)
    s.hook("SessionStart", source="resume")
    s.check("old Desktop chat, Desktop says %s" % want.split("/")[-1], want)

# A terminal session whose process is gone has ended, even with no end hook.
REG = os.path.join(HOME, ".claude/sessions")
os.makedirs(REG)
proc = subprocess.Popen(["/bin/sleep", "60"])
json.dump({"pid": proc.pid, "sessionId": "cli-dead-1"}, open(os.path.join(REG, "%d.json" % proc.pid), "w"))
k = S("cli-dead-1", base)
k.hook("UserPromptSubmit", prompt="x"); k.hook("Stop"); k.check("terminal session alive", "done/-/unseen")
proc.kill(); proc.wait(); os.remove(os.path.join(REG, "%d.json" % proc.pid))
k.check("terminal closed, no end hook", "hidden")

# Running sessions keep their place in the panel while they work.
def order():
    out = json.loads(subprocess.run([BIN, "status"], capture_output=True, text=True, env=base).stdout)
    return [x["key"] for x in out["sessions"] if x["key"] in ("claude-ord-1", "claude-ord-2")]
o1 = S("ord-1", base); o1.hook("UserPromptSubmit", prompt="a"); time.sleep(1.1)
o2 = S("ord-2", base); o2.hook("UserPromptSubmit", prompt="b"); time.sleep(1.1)
before = order(); time.sleep(2.5)
o1.line({"type": "assistant", "message": {"stop_reason": "tool_use", "content": []}}); o1.hook("PostToolUse", tool_name="Bash")
after = order()
ok = before == after == ["claude-ord-2", "claude-ord-1"]
print("ok  " if ok else "FAIL", "running sessions keep their order", after)
if not ok: FAILED.append("order")
# No timers: a long-running turn stays running, and an unread finish stays unread.
def age(sess, hours):
    p = os.path.join(D, "claude-%s.json" % sess.sid)
    r = json.load(open(p)); r["updated_at"] -= hours * 3600; json.dump(r, open(p, "w"))
lr = S("long-run-1", base)
lr.hook("UserPromptSubmit", prompt="build"); age(lr, 2)
lr.check("running for 2 hours, no events", "running/-/seen")
lu = S("long-unread-1", base)
lu.hook("UserPromptSubmit", prompt="x"); lu.hook("Stop"); age(lu, 30)
lu.check("finished 30 hours ago, never looked at", "done/-/unseen")
# A Desktop app quitting mid-turn ends that turn, but keeps the session.
q = S("desk-quit-1", dict(base, CLAUDE_CODE_ENTRYPOINT="claude-desktop", CLAUDE_CODE_HOST_SESSION_ID="local_test-desk-quit"))
q.hook("UserPromptSubmit", prompt="x"); q.hook("SessionEnd", reason="other")
q.check("app quit while running", "idle/-/seen")

# Codex: the app's own internal sessions (no transcript) and subagent threads stay out.
TASK_DONE = {"type": "event_msg", "payload": {"type": "task_complete"}}
c = S("codex-user-1", base, tool="codex", meta={"thread_source": "user", "source": "vscode"})
c.hook("UserPromptSubmit", prompt="x"); c.line(TASK_DONE); c.hook("Stop")
c.check("codex thread you started", "done/-/unseen")
i = S("codex-internal-1", base, tool="codex")
i.hook("UserPromptSubmit", prompt="# Overview", transcript_path=None); i.hook("Stop", transcript_path=None)
i.check("codex app internal session", "hidden")
g = S("codex-sub-1", base, tool="codex", meta={"thread_source": "subagent", "source": {"subagent": {"thread_spawn": {}}}})
g.hook("UserPromptSubmit", prompt="explore"); g.line(TASK_DONE); g.hook("Stop")
g.check("codex subagent thread", "hidden")
# A Codex terminal session lives as long as the codex process that runs its hooks.
FAKE = os.path.join(D, "codex-fake")
os.symlink("/bin/sh", FAKE)
t = S("codex-term-1", base, tool="codex", meta={"thread_source": "user", "source": "cli"})
t.line(TASK_DONE)
for ev in ("UserPromptSubmit", "Stop"):
    open(os.path.join(D, ev), "w").write(json.dumps(dict(hook_event_name=ev, session_id=t.sid, cwd="/tmp/p",
                                                         transcript_path=t.tr, prompt="x")))
run = "'%s' hook codex < '%s'/UserPromptSubmit; '%s' hook codex < '%s'/Stop; sleep 60" % (BIN, D, BIN, D)
codex = subprocess.Popen([FAKE, "-c", run], env=base)
for _ in range(50):
    if t.state() == "done/-/unseen": break
    time.sleep(.2)
t.check("codex in a terminal", "done/-/unseen")
codex.kill(); codex.wait()
t.check("codex terminal closed, no end hook", "hidden")

# Antigravity: camelCase payloads, the event name on the command line, no prompt event.
class Agy(S):
    def __init__(s, sid):
        S.__init__(s, sid, base, tool="antigravity")
    def hook(s, ev, **kw):
        data = dict(conversationId=s.sid, workspacePaths=["/tmp/p"], transcriptPath=s.tr)
        data.update(kw)
        out = subprocess.run([BIN, "hook", "antigravity", ev], input=json.dumps(data), text=True,
                             env=s.env, capture_output=True).stdout
        return json.loads(out) if out.strip() else None
    def step(s, **d):
        s.line(dict(d, created_at=iso()))
a = Agy("agy-1")
out = a.hook("PreInvocation", invocationNum=0, lastUserInput="refactor the parser")
a.check("model invoked", "running/-/seen")
if out != {}: FAILED.append("PreInvocation output"); print("FAIL PreInvocation output", out)
out = a.hook("PreToolUse", toolCall={"name": "ask_question", "args": {}})
a.check("asks you a question", "waiting/question/seen")
if out != {"decision": "allow"}: FAILED.append("PreToolUse output"); print("FAIL PreToolUse output", out)
a.hook("PostToolUse", toolCall={"name": "ask_question", "args": {}})
a.check("question answered", "running/-/seen")
out = a.hook("Stop", terminationReason="model_stop", fullyIdle=True)
a.check("turn finished", "done/-/unseen")
if out != {"decision": "allow"}: FAILED.append("Stop output"); print("FAIL Stop output", out)
time.sleep(3)
a.step(type="USER_INPUT", status="DONE"); a.step(type="RUN_COMMAND", status="WAITING")
a.check("transcript: a step waits for approval", "waiting/permission/seen")
time.sleep(3)
a.step(type="PLANNER_RESPONSE", status="DONE", content="done")
a.check("transcript: reply with no tool calls", "done/-/unseen")

# 1. Hook waiting stays waiting even if transcript flushes assistant tool_use >2s later.
w = S("wait-keep-1", base)
w.hook("UserPromptSubmit", prompt="run"); w.hook("PermissionRequest", tool_name="Bash")
time.sleep(3); w.line({"type": "assistant", "message": {"stop_reason": "tool_use", "content": []}})
w.check("waiting stays waiting over assistant tool_use", "waiting/permission/seen")

# 2. Antigravity IDE gets its own bundle/jump, accepts WAITING within 2s, and skips T3 ACP.
ide_env = dict(base, __CFBundleIdentifier="com.google.antigravity-ide")
ide = S("agy-ide-1", ide_env, tool="antigravity")
subprocess.run([BIN, "hook", "antigravity", "PreInvocation"],
               input=json.dumps(dict(conversationId=ide.sid, workspacePaths=["/tmp/p"], transcriptPath=ide.tr,
                                     invocationNum=0, lastUserInput="fix")),
               text=True, env=ide_env, capture_output=True)
ide.line(dict(type="RUN_COMMAND", status="WAITING", created_at=iso()))
ide.check("antigravity WAITING within 2s", "waiting/permission/seen")
ide_st = json.loads(subprocess.run([BIN, "status"], capture_output=True, text=True, env=base).stdout)
ide_row = [x for x in ide_st["sessions"] if x["key"] == "antigravity-agy-ide-1"][0]
ide_rec = [r for r in json.loads(subprocess.run([BIN, "dump"], capture_output=True, text=True, env=base).stdout)
           if r["session_id"] == ide.sid][0]
ok = ide_row["bundle"] == "com.google.antigravity-ide" and ide_rec["jump"]["target"] == "com.google.antigravity-ide"
print("ok  " if ok else "FAIL", "antigravity IDE jump & bundle", ide_row["bundle"], ide_rec["jump"])
if not ok: FAILED.append("antigravity-ide-jump")

acp_tr = os.path.join(HOME, ".t3/userdata/providers/antigravity/x/antigravity-acp/brain/acp-1/transcript_full.jsonl")
os.makedirs(os.path.dirname(acp_tr), exist_ok=True)
subprocess.run([BIN, "hook", "antigravity", "PreInvocation"],
               input=json.dumps(dict(conversationId="acp-1", workspacePaths=["/tmp/p"], transcriptPath=acp_tr,
                                     invocationNum=0, lastUserInput="hi")),
               text=True, env=base, capture_output=True)
acp_found = any(r["session_id"] == "acp-1" for r in json.loads(subprocess.run([BIN, "dump"], capture_output=True, text=True, env=base).stdout))
print("ok  " if not acp_found else "FAIL", "antigravity ignores T3 ACP", acp_found)
if acp_found: FAILED.append("antigravity-acp-skip")

# 3. T3 Code threads from statev2.sqlite: running, waiting, unread, read, subagent, deep link.
import sqlite3
t3_dir = os.path.join(HOME, ".t3/userdata")
os.makedirs(t3_dir, exist_ok=True)
open(os.path.join(t3_dir, "environment-id"), "w").write("env-test-1\n")
t3_con = sqlite3.connect(os.path.join(t3_dir, "statev2.sqlite"))
t3_con.executescript("""
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT, workspace_root TEXT);
CREATE TABLE orchestration_v2_projection_threads (
  thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT, default_provider TEXT,
  runtime_mode TEXT, interaction_mode TEXT, active_provider_thread_id TEXT,
  created_at TEXT, updated_at TEXT, archived_at TEXT, deleted_at TEXT, payload_json TEXT, provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_runs (
  run_id TEXT PRIMARY KEY, thread_id TEXT, ordinal INTEGER, provider TEXT,
  provider_thread_id TEXT, status TEXT, requested_at TEXT, completed_at TEXT, payload_json TEXT, provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_runtime_requests (
  runtime_request_id TEXT PRIMARY KEY, thread_id TEXT, node_id TEXT, provider_turn_id TEXT,
  kind TEXT, status TEXT, created_at TEXT, resolved_at TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_messages (
  message_id TEXT PRIMARY KEY, thread_id TEXT, run_id TEXT, node_id TEXT,
  role TEXT, is_streaming INTEGER, created_at TEXT, updated_at TEXT, payload_json TEXT);
""")
t_now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
t_old = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - 60))
t3_con.execute("INSERT INTO projection_projects VALUES ('p1', 'proj', '/tmp/proj')")
t3_con.execute("INSERT INTO orchestration_v2_projection_threads VALUES ('t-run', 'p1', 'Running Task', 'antigravity', 'full-access', 'default', '', ?, ?, NULL, NULL, ?, 'antigravity')",
               (t_old, t_now, json.dumps({"lastVisitedAt": t_old})))
t3_con.execute("INSERT INTO orchestration_v2_projection_runs VALUES ('r1', 't-run', 1, 'antigravity', '', 'running', ?, NULL, '{}', 'antigravity')", (t_now,))
t3_con.execute("INSERT INTO orchestration_v2_projection_messages VALUES ('m1', 't-run', 'r1', 'n1', 'user', 0, ?, ?, ?)", (t_now, t_now, json.dumps({"text": "fix bug"})))

t3_con.execute("INSERT INTO orchestration_v2_projection_threads VALUES ('t-wait', 'p1', 'Question Task', 'codex', 'full-access', 'default', '', ?, ?, NULL, NULL, ?, 'codex')",
               (t_old, t_now, json.dumps({"lastVisitedAt": t_old})))
t3_con.execute("INSERT INTO orchestration_v2_projection_runs VALUES ('r2', 't-wait', 1, 'codex', '', 'running', ?, NULL, '{}', 'codex')", (t_now,))
t3_con.execute("INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('req1', 't-wait', 'n2', 'pt1', 'user_input', 'pending', ?, NULL, '{}')", (t_now,))

t3_con.execute("INSERT INTO orchestration_v2_projection_threads VALUES ('t-done', 'p1', 'Done Task', 'claudeAgent', 'full-access', 'default', '', ?, ?, NULL, NULL, ?, 'claudeAgent')",
               (t_old, t_now, json.dumps({"lastVisitedAt": t_old})))
t3_con.execute("INSERT INTO orchestration_v2_projection_runs VALUES ('r3', 't-done', 1, 'claudeAgent', '', 'completed', ?, ?, '{}', 'claudeAgent')", (t_old, t_now))

t3_con.execute("INSERT INTO orchestration_v2_projection_threads VALUES ('t-sub', 'p1', 'Subagent', 'antigravity', 'full-access', 'default', '', ?, ?, NULL, NULL, ?, 'antigravity')",
               (t_old, t_now, json.dumps({"lineage": {"relationshipToParent": "subagent"}})))
t3_con.execute("INSERT INTO orchestration_v2_projection_runs VALUES ('r4', 't-sub', 1, 'antigravity', '', 'running', ?, NULL, '{}', 'antigravity')", (t_now,))
t3_con.commit()

dump = {r["session_id"]: r for r in json.loads(subprocess.run([BIN, "dump"], capture_output=True, text=True, env=base).stdout)}
for sid, want in [("t-run", ("running", True)), ("t-wait", ("waiting", True)), ("t-done", ("done", False))]:
    r = dump.get(sid)
    ok = r is not None and r["state"] == want[0] and r["seen"] == want[1] and r["jump"]["target"] == "t3code://threads/env-test-1/" + sid
    print("ok  " if ok else "FAIL", "t3code " + sid, r and (r["state"], r["seen"], r["jump"]))
    if not ok: FAILED.append("t3-" + sid)
if "t-sub" in dump and not dump["t-sub"].get("hidden"):
    print("FAIL t3code subagent visible"); FAILED.append("t3-sub")
else:
    print("ok   t3code subagent hidden")

# Visiting t-done in T3 Code clears unread.
t_visit = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 5))
t3_con.execute("UPDATE orchestration_v2_projection_threads SET payload_json = ? WHERE thread_id = 't-done'", (json.dumps({"lastVisitedAt": t_visit}),))
t3_con.commit(); t3_con.close()
dump2 = {r["session_id"]: r for r in json.loads(subprocess.run([BIN, "dump"], capture_output=True, text=True, env=base).stdout)}
ok = dump2["t-done"]["seen"] is True
print("ok  " if ok else "FAIL", "t3code visited clears unread", dump2["t-done"]["seen"])
if not ok: FAILED.append("t3-visit")

shutil.rmtree(D, ignore_errors=True)
print("%d failed" % len(FAILED) if FAILED else "all passed")
sys.exit(1 if FAILED else 0)
