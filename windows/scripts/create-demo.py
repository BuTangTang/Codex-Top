"""Generate isolated synthetic SQLite/log fixtures for Windows UI validation."""
from pathlib import Path
import datetime as dt
import json
import sqlite3
import uuid

base = Path(__file__).resolve().parents[1] / ".tools" / "qa"
root = base / "codex"
root.mkdir(parents=True, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
db = root / "state_5.sqlite"
connection = sqlite3.connect(db)
connection.execute("CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER,source TEXT)")
connection.execute("CREATE TABLE IF NOT EXISTS thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)")
connection.execute("DELETE FROM threads")
ids = []
for index, (title, project, phase) in enumerate([
    ("Windows 圆环与浮窗交互", "Codex Top", "running"),
    ("确认第一版的界面细节", "桌面监控", "waiting"),
    ("整理任务状态与计时逻辑", "业务核心", "running"),
    ("检查打包与发布配置", "交付准备", "failed"),
    ("补充任务选择器的测试", "质量验证", "completed"),
    ("一条很长的任务名称用于验证紧凑布局的省略显示和悬停提示", "可读性", "completed"),
]):
    identity = str(uuid.uuid5(uuid.NAMESPACE_DNS, "codextop.demo." + str(index)))
    ids.append(identity)
    path = root / (identity + ".jsonl")
    start = now - dt.timedelta(minutes=3, seconds=index * 13)
    events = [{"timestamp": start.isoformat(), "type": "event_msg", "payload": {"type": "task_started", "turn_id": "demo", "started_at": start.isoformat()}}]
    stamp = now - dt.timedelta(seconds=15)
    if phase == "waiting":
        events.append({"timestamp": stamp.isoformat(), "type": "response_item", "payload": {"type": "function_call", "name": "request_user_input_async", "call_id": "demo-question"}})
    else:
        event = {"running": "agent_message", "failed": "task_failed", "completed": "task_complete"}[phase]
        events.append({"timestamp": stamp.isoformat(), "type": "event_msg", "payload": {"type": event, "turn_id": "demo"}})
    path.write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in events), encoding="utf-8")
    connection.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,0,'cli')", (identity, title, project, str(path), int(start.timestamp()), int(stamp.timestamp())))
connection.commit()
connection.close()
settings = base / "settings"
settings.mkdir(exist_ok=True)
(settings / "settings.json").write_text(json.dumps({"SelectedIds": ids, "Initialized": True, "AutoMonitor": False, "Dark": True, "Placement": 2, "Scale": 1, "VisibleTasks": 4, "CodexHome": str(root), "CliPath": str(base / "disabled-cli.exe")}, ensure_ascii=False), encoding="utf-8")
print("Synthetic UI fixtures ready.")
