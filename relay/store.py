"""独立中转存储：账号、电脑和会话严格绑定，不接触 Codex 或 PVTC 数据。"""

import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager

FRESH_MS = 60_000
BODY_TTL_MS = 86_400_000
SESSION_TTL_MS = 7 * BODY_TTL_MS
IDENTIFIER = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
STATES = {"server_received": 0, "dispatching": 1, "computer_received": 2, "codex_received": 3}


class RelayError(Exception):
    """携带固定错误代码，不将凭据、消息正文或数据库异常暴露给客户端。"""

    def __init__(self, status, code):
        """构造可映射为 HTTP 的业务错误。"""
        super().__init__(code)
        self.status, self.code = status, code


def identifier(value):
    """校验复合路由中的各个标识，拒绝路径字符、空值和控制字符。"""
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise RelayError(400, "invalid_identifier")
    return value


def bounded(value, limit, empty=False):
    """限制文本长度与类型，消息中的换行保留但拒绝空字节。"""
    if not isinstance(value, str) or len(value) > limit or "\0" in value or (not empty and not value.strip()):
        raise RelayError(400, "invalid_text")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise RelayError(400, "invalid_text") from None
    return value


def digest(value):
    """令牌和幂等正文只存摘要，数据库不保存可直接复用的明文令牌。"""
    return hashlib.sha256(value.encode()).hexdigest()


class Store:
    """单进程 SQLite 事务存储；每次请求先鉴权再按账号和来源限定查询。"""

    def __init__(self, path, clock=None):
        """创建独立数据库及唯一约束；测试可以传入可控时钟。"""
        self.clock = clock or (lambda: int(time.time() * 1000))
        self.lock = threading.RLock()
        self.transaction_depth = 0
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA secure_delete=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY, salt BLOB NOT NULL, password BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS devices (
                account TEXT NOT NULL REFERENCES accounts(id), id TEXT NOT NULL,
                name TEXT NOT NULL, seen INTEGER NOT NULL DEFAULT 0, snapshot TEXT NOT NULL DEFAULT '[]',
                PRIMARY KEY(account,id));
            CREATE TABLE IF NOT EXISTS sessions (
                hash TEXT PRIMARY KEY, account TEXT NOT NULL REFERENCES accounts(id),
                role TEXT NOT NULL, device TEXT, expires INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations (
                account TEXT NOT NULL, device TEXT NOT NULL, id TEXT NOT NULL,
                task TEXT NOT NULL, enabled INTEGER NOT NULL,
                PRIMARY KEY(account,device,id), FOREIGN KEY(account,device) REFERENCES devices(account,id));
            CREATE TABLE IF NOT EXISTS messages (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL,
                device TEXT NOT NULL, thread TEXT NOT NULL, id TEXT NOT NULL,
                role TEXT NOT NULL, body TEXT NOT NULL, hash TEXT NOT NULL,
                state TEXT NOT NULL, created INTEGER NOT NULL, updated INTEGER NOT NULL,
                UNIQUE(account,id), FOREIGN KEY(account,device,thread) REFERENCES conversations(account,device,id));
            CREATE INDEX IF NOT EXISTS messages_route ON messages(account,device,thread,seq);
        """)

    def close(self):
        """释放数据库句柄，供服务关闭及隔离测试清理。"""
        with self.lock:
            self.db.close()

    @contextmanager
    def transaction(self):
        """写请求串行原子提交，异常回滚，避免两个轮询者重复领取同一消息。"""
        with self.lock:
            # sync 外层与各独立操作共用连接；保存点使整批失败时可完整撤回。
            depth = self.transaction_depth
            point = f"relay_{depth}"
            self.db.execute("BEGIN IMMEDIATE" if depth == 0 else f"SAVEPOINT {point}")
            self.transaction_depth += 1
            try:
                yield
                self.db.execute("COMMIT" if depth == 0 else f"RELEASE {point}")
            except BaseException:
                self.db.execute("ROLLBACK" if depth == 0 else f"ROLLBACK TO {point}")
                if depth:
                    self.db.execute(f"RELEASE {point}")
                raise
            finally:
                self.transaction_depth -= 1

    def add_account(self, account, password):
        """仅供本机管理员创建账号，不提供公开注册接口。"""
        identifier(account)
        bounded(password, 256)
        if len(password) < 12:
            raise RelayError(400, "password_too_short")
        salt = secrets.token_bytes(16)
        key = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
        with self.transaction():
            if self.db.execute("SELECT 1 FROM accounts WHERE id=?", (account,)).fetchone():
                raise RelayError(409, "account_exists")
            self.db.execute("INSERT INTO accounts VALUES(?,?,?)", (account, salt, key))

    def login(self, account, password):
        """校验密码后签发手机令牌；不存在账号也执行等成本密码运算。"""
        bounded(account, 128)
        bounded(password, 256)
        with self.lock:
            row = self.db.execute("SELECT * FROM accounts WHERE id=?", (account,)).fetchone()
        salt = row["salt"] if row else b"missing-account!"
        actual = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
        if not hmac.compare_digest(actual, row["password"] if row else bytes(64)) or row is None:
            raise RelayError(401, "invalid_credentials")
        with self.transaction():
            return {"token": self._token(account, "mobile", None), "account": account}

    def _token(self, account, role, device):
        """在调用者事务内生成有期限的服务令牌，返回值仅在签发时提供。"""
        self.db.execute("DELETE FROM sessions WHERE expires<=?", (self.clock(),))
        if self.db.execute("SELECT count(*) FROM sessions WHERE account=? AND role=?", (account, role)).fetchone()[0] >= 128:
            raise RelayError(429, "session_quota")
        token = secrets.token_urlsafe(32)
        self.db.execute("INSERT INTO sessions VALUES(?,?,?,?,?)",
                        (digest(token), account, role, device, self.clock() + SESSION_TTL_MS))
        return token

    def add_device(self, account, device, name):
        """本机管理员单独授权电脑，令牌绑定一个来源，手机不能冒充电脑上传回复。"""
        identifier(account), identifier(device), bounded(name, 80)
        with self.transaction():
            if not self.db.execute("SELECT 1 FROM accounts WHERE id=?", (account,)).fetchone():
                raise RelayError(404, "account_missing")
            if self.db.execute("SELECT 1 FROM devices WHERE account=? AND id=?", (account, device)).fetchone():
                raise RelayError(409, "device_exists")
            if self.db.execute("SELECT count(*) FROM devices WHERE account=?", (account,)).fetchone()[0] >= 100:
                raise RelayError(429, "device_quota")
            self.db.execute("INSERT INTO devices(account,id,name) VALUES(?,?,?)", (account, device, name))
            return self._token(account, "desktop", device)

    def manage_device(self, account, device, rotate=False):
        """管理员撤销电脑令牌并停止共享；轮换时返回新令牌，须重新上传授权会话。"""
        identifier(account), identifier(device)
        with self.transaction():
            if not self.db.execute("SELECT 1 FROM devices WHERE account=? AND id=?", (account, device)).fetchone():
                raise RelayError(404, "device_missing")
            self.db.execute("DELETE FROM sessions WHERE account=? AND device=? AND role='desktop'", (account, device))
            self.db.execute("UPDATE devices SET seen=0,snapshot='[]' WHERE account=? AND id=?", (account, device))
            self.db.execute("UPDATE conversations SET enabled=0 WHERE account=? AND device=?", (account, device))
            self.db.execute("UPDATE messages SET state='cancelled',updated=? WHERE account=? AND device=? AND state='server_received'",
                            (self.clock(), account, device))
            # 已派发输入无法从远端收回；保留其不确定性，不宣称撤销了已执行操作。
            return self._token(account, "desktop", device) if rotate else None

    def revoke_mobile_sessions(self, account):
        """管理员撤销该账号全部手机登录，不影响其他账号或电脑令牌。"""
        identifier(account)
        with self.transaction():
            if not self.db.execute("SELECT 1 FROM accounts WHERE id=?", (account,)).fetchone():
                raise RelayError(404, "account_missing")
            self.db.execute("DELETE FROM sessions WHERE account=? AND role='mobile'", (account,))

    def sync(self, token, tasks, receipts, replies):
        """原子处理完整电脑同步，任意事件失败时不留下半批快照、回执或领取。"""
        if not isinstance(receipts, list) or len(receipts) > 100 or not isinstance(replies, list) or len(replies) > 100:
            raise RelayError(400, "invalid_events")
        if any(not isinstance(item, dict) for item in receipts + replies):
            raise RelayError(400, "invalid_event")
        with self.transaction():
            self.publish(token, tasks)
            for receipt in receipts:
                self.acknowledge(token, receipt.get("id"), receipt.get("state"))
            for reply in replies:
                self.reply(token, reply.get("threadId"), reply.get("id"), reply.get("text"))
            return {"commands": self.claim(token), "serverTime": self.clock()}

    def _auth(self, token, role):
        """在当前锁或事务中验证令牌与角色，所有路由身份都从令牌取得。"""
        if not isinstance(token, str) or len(token) > 2048:
            raise RelayError(401, "unauthorized")
        row = self.db.execute("SELECT * FROM sessions WHERE hash=? AND expires>?", (digest(token), self.clock())).fetchone()
        if row is None:
            raise RelayError(401, "unauthorized")
        if row["role"] != role:
            raise RelayError(403, "wrong_role")
        return row

    def logout(self, token):
        """撤销当前手机令牌，不影响其他手机或电脑。"""
        with self.transaction():
            self._auth(token, "mobile")
            self.db.execute("DELETE FROM sessions WHERE hash=?", (digest(token),))

    def publish(self, token, tasks):
        """电脑提交完整授权会话快照；缺席会话撤销手机发送权限，重现时保留同一身份。"""
        if not isinstance(tasks, list) or len(tasks) > 100:
            raise RelayError(400, "invalid_tasks")
        clean, ids = [], set()
        for task in tasks:
            if not isinstance(task, dict):
                raise RelayError(400, "invalid_task")
            tid = identifier(task.get("id"))
            if tid in ids:
                raise RelayError(400, "duplicate_thread")
            ids.add(tid)
            entry = {"id": tid, "title": bounded(task.get("title"), 160),
                     "project": bounded(task.get("project", ""), 80, True),
                     "phase": bounded(task.get("phase", "unknown"), 40),
                     "turnId": bounded(task.get("turnId", ""), 128, True),
                     "eventId": bounded(task.get("eventId", ""), 128, True)}
            for field in ["eventAt", "startedAt"]:
                value = task.get(field, 0 if field == "eventAt" else None)
                if value is not None and (type(value) is not int or value < 0 or value > self.clock() + 60_000):
                    raise RelayError(400, "invalid_time")
                entry[field] = value
            clean.append(entry)
        with self.transaction():
            auth = self._auth(token, "desktop")
            account, device = auth["account"], auth["device"]
            others = self.db.execute("SELECT count(*) FROM conversations WHERE account=? AND device!=? AND enabled=1", (account, device)).fetchone()[0]
            if others + len(clean) > 500:
                raise RelayError(429, "task_quota")
            self.db.execute("UPDATE conversations SET enabled=0 WHERE account=? AND device=?", (account, device))
            for entry in clean:
                entry["sourceId"] = device
                self.db.execute("INSERT INTO conversations VALUES(?,?,?,?,1) ON CONFLICT(account,device,id) DO UPDATE SET task=excluded.task,enabled=1",
                                (account, device, entry["id"], json.dumps(entry)))
            self.db.execute("UPDATE devices SET seen=?,snapshot=? WHERE account=? AND id=?",
                            (self.clock(), json.dumps(clean), account, device))
            # 已撤销的会话不能继续领取尚未发送的输入。
            self.db.execute("""UPDATE messages SET state='cancelled',updated=? WHERE account=? AND device=? AND state='server_received'
                AND NOT EXISTS(SELECT 1 FROM conversations c WHERE c.account=messages.account AND c.device=messages.device AND c.id=messages.thread AND enabled=1)""",
                            (self.clock(), account, device))

    def snapshot(self, token):
        """保持现有安卓状态快照契约，来源在线仅由该来源的心跳决定。"""
        with self.lock:
            auth = self._auth(token, "mobile")
            devices, tasks = [], []
            for row in self.db.execute("SELECT * FROM devices WHERE account=? ORDER BY id", (auth["account"],)):
                age = self.clock() - row["seen"]
                devices.append({"id": row["id"], "name": row["name"], "connected": row["seen"] > 0 and 0 <= age <= FRESH_MS,
                                "readState": "ready" if row["seen"] else "unknown", "observedAt": row["seen"]})
                tasks.extend(json.loads(row["snapshot"]))
            return {"version": 1, "serverTime": self.clock(), "devices": devices, "tasks": tasks}

    def _route(self, account, device, thread):
        """所有消息操作核对复合身份和当前共享权限，不跨电脑回退同名会话。"""
        identifier(device), identifier(thread)
        row = self.db.execute("SELECT c.*,d.seen,d.name FROM conversations c JOIN devices d ON d.account=c.account AND d.id=c.device WHERE c.account=? AND c.device=? AND c.id=? AND c.enabled=1",
                              (account, device, thread)).fetchone()
        if row is None:
            raise RelayError(404, "conversation_unavailable")
        return row

    def submit(self, token, device, thread, message_id, body):
        """持久化手机消息并去重；旧 ID 改正文或改目标拒绝，离线不积压新指令。"""
        identifier(message_id), bounded(body, 8000)
        with self.transaction():
            auth = self._auth(token, "mobile")
            self._expire()
            route = self._route(auth["account"], device, thread)
            previous = self.db.execute("SELECT * FROM messages WHERE account=? AND id=?", (auth["account"], message_id)).fetchone()
            if previous:
                if previous["device"] != device or previous["thread"] != thread or previous["hash"] != digest(body) or previous["role"] != "user":
                    raise RelayError(409, "message_id_conflict")
                return self._view(previous)
            if route["seen"] <= 0 or not 0 <= self.clock() - route["seen"] <= FRESH_MS:
                raise RelayError(409, "computer_offline")
            if self.db.execute("SELECT count(*) FROM messages WHERE account=?", (auth["account"],)).fetchone()[0] >= 10000:
                raise RelayError(429, "message_quota")
            self.db.execute("INSERT INTO messages(account,device,thread,id,role,body,hash,state,created,updated) VALUES(?,?,?,?,?,?,?,?,?,?)",
                            (auth["account"], device, thread, message_id, "user", body, digest(body), "server_received", self.clock(), self.clock()))
            return self._view(self.db.execute("SELECT * FROM messages WHERE account=? AND id=?", (auth["account"], message_id)).fetchone())

    def claim(self, token):
        """原子标记待转发输入；响应丢失不自动再派发，避免跨重连重复执行。"""
        with self.transaction():
            auth = self._auth(token, "desktop")
            self._expire()
            rows = self.db.execute("SELECT * FROM messages WHERE account=? AND device=? AND state='server_received' ORDER BY seq LIMIT 20",
                                   (auth["account"], auth["device"])).fetchall()
            result = []
            for row in rows:
                self.db.execute("UPDATE messages SET state='dispatching',updated=? WHERE seq=?", (self.clock(), row["seq"]))
                item = self._view(row)
                item["state"] = "dispatching"
                result.append(item)
            return result

    def acknowledge(self, token, message_id, state):
        """只接受该电脑已派发输入的单向回执；服务接收不能冒充 Codex 接收。"""
        identifier(message_id)
        if not isinstance(state, str) or state not in {"computer_received", "codex_received", "failed"}:
            raise RelayError(400, "invalid_receipt")
        with self.transaction():
            auth = self._auth(token, "desktop")
            row = self.db.execute("SELECT * FROM messages WHERE account=? AND device=? AND id=? AND role='user'",
                                  (auth["account"], auth["device"], message_id)).fetchone()
            if row is None:
                raise RelayError(404, "message_missing")
            if row["state"] == state:
                return
            if row["state"] in {"server_received", "failed", "cancelled", "expired", "codex_received"}:
                raise RelayError(409, "invalid_transition")
            if state != "failed" and STATES.get(row["state"], -1) >= STATES[state]:
                raise RelayError(409, "receipt_regression")
            self.db.execute("UPDATE messages SET state=?,updated=? WHERE seq=?", (state, self.clock(), row["seq"]))

    def reply(self, token, thread, event_id, body):
        """电脑只上报自身授权会话的回复，稳定事件 ID 保证网络重试不重复展示。"""
        identifier(event_id), bounded(body, 16000)
        with self.transaction():
            auth = self._auth(token, "desktop")
            self._route(auth["account"], auth["device"], thread)
            event_id = "reply-" + digest(auth["device"] + "\0" + thread + "\0" + event_id)
            previous = self.db.execute("SELECT * FROM messages WHERE account=? AND id=?", (auth["account"], event_id)).fetchone()
            if previous:
                if previous["device"] != auth["device"] or previous["thread"] != thread or previous["role"] != "assistant" or previous["hash"] != digest(body):
                    raise RelayError(409, "message_id_conflict")
                return
            if self.db.execute("SELECT count(*) FROM messages WHERE account=?", (auth["account"],)).fetchone()[0] >= 10000:
                raise RelayError(429, "message_quota")
            self.db.execute("INSERT INTO messages(account,device,thread,id,role,body,hash,state,created,updated) VALUES(?,?,?,?,?,?,?,?,?,?)",
                            (auth["account"], auth["device"], thread, event_id, "assistant", body, digest(body), "received", self.clock(), self.clock()))

    def history(self, token, device, thread, before=None):
        """按稳定序号分页读取授权对话，正文过期后保留去重身份而不重放执行。"""
        if before is not None and (type(before) is not int or not 0 < before <= 9223372036854775807):
            raise RelayError(400, "invalid_cursor")
        with self.transaction():
            auth = self._auth(token, "mobile")
            route = self._route(auth["account"], device, thread)
            self._expire()
            rows = self.db.execute("SELECT * FROM messages WHERE account=? AND device=? AND thread=? AND seq<? ORDER BY seq DESC LIMIT 101",
                                   (auth["account"], device, thread, before or 9223372036854775807)).fetchall()
            candidates, rows, size = rows, [], 0
            for row in candidates[:100]:
                item_size = len(json.dumps(self._view(row), ensure_ascii=False).encode("utf-8")) + 2
                if rows and size + item_size > 512 * 1024:
                    break
                rows.append(row)
                size += item_size
            more = len(candidates) > len(rows)
            return {"sourceId": device, "threadId": thread, "task": json.loads(route["task"]),
                    "device": {"id": device, "name": route["name"], "connected": route["seen"] > 0 and 0 <= self.clock() - route["seen"] <= FRESH_MS},
                    "messages": [self._view(row) for row in reversed(rows)],
                    "olderCursor": rows[-1]["seq"] if more else None}

    def maintenance(self):
        """周期清理过期正文与会话，再截断本数据库 WAL，不触碰宿主其他文件。"""
        with self.lock:
            with self.transaction():
                self._expire()
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    def _expire(self):
        """清理一天前的正文但保留幂等摘要；未确认派发显示不确定且绝不自动重投。"""
        now = self.clock()
        self.db.execute("UPDATE messages SET body='',state='expired',updated=? WHERE created<? AND state!='expired'", (now, now - BODY_TTL_MS))
        self.db.execute("UPDATE messages SET state='uncertain',updated=? WHERE state IN ('dispatching','computer_received') AND updated<?", (now, now - FRESH_MS))
        self.db.execute("UPDATE messages SET state='cancelled',updated=? WHERE state='server_received' AND created<?", (now, now - FRESH_MS))
        self.db.execute("DELETE FROM sessions WHERE expires<=?", (now,))

    def _view(self, row):
        """只投影客户端需要的字段，隐藏账号、数据库摘要和内部凭据。"""
        return {"id": row["id"], "sourceId": row["device"], "threadId": row["thread"], "role": row["role"],
                "text": row["body"], "state": row["state"], "createdAt": row["created"], "updatedAt": row["updated"]}
