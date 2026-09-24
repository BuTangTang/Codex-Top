"""独立出站同步与持久投递账本，不读取或修改 Codex 私有文件。"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time
import urllib.parse
import urllib.request


class Unavailable(RuntimeError):
    """执行器未验证或通信结果无法确认。"""


class Rejected(RuntimeError):
    """执行器能证明输入未提交，可以明确报告失败。"""


def fingerprint(value):
    """对路由和正文生成稳定摘要，日志不保留用户输入正文。"""
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


class Journal:
    """独立 SQLite 日志负责跨重启去重，不能与其他电脑身份共用。"""

    def __init__(self, path, identity):
        """建立私有日志并绑定服务器与设备凭据摘要，拒绝误用其他身份。"""
        path = Path(path).absolute()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.is_symlink():
            raise ValueError('journal_symlink')
        descriptor = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(descriptor)
            raise Unavailable('journal_already_in_use')
        self.descriptor = descriptor
        data_fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(data_fd)
        os.chmod(path, 0o600)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS identity(value TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS inputs(id TEXT PRIMARY KEY, hash TEXT NOT NULL,
              state TEXT NOT NULL, reported INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS replies(id TEXT PRIMARY KEY, thread TEXT NOT NULL,
              hash TEXT NOT NULL, text TEXT, created REAL NOT NULL, reported INTEGER NOT NULL DEFAULT 0);
        ''')
        row = self.db.execute('SELECT value FROM identity').fetchone()
        if row and row[0] != identity:
            self.close()
            raise ValueError('journal_identity_mismatch')
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO identity VALUES(?)', (identity,))
            # 发送前先落盘；进程死于此后的任一点均禁止自动重投。
            self.db.execute("UPDATE inputs SET state='uncertain' WHERE state='sending'")

    def close(self):
        """关闭本适配器拥有的数据库。"""
        self.db.close()
        os.close(self.descriptor)

    def begin(self, command):
        """原子记录一次发送意图；重复 ID 即使来自重连也绝不再次发送。"""
        digest = fingerprint([command['threadId'], command['text']])
        with self.db:
            row = self.db.execute('SELECT hash FROM inputs WHERE id=?', (command['id'],)).fetchone()
            if row:
                if row['hash'] != digest:
                    raise ValueError('message_id_conflict')
                return False
            self.db.execute("INSERT INTO inputs(id,hash,state) VALUES(?,?,'sending')", (command['id'], digest))
        return True

    def finish(self, message_id, state):
        """仅接受明确提交结果；不确定时只上报电脑收到，不虚构 Codex 接收。"""
        if state not in {'uncertain', 'codex_received', 'failed'}:
            raise ValueError('invalid_state')
        with self.db:
            self.db.execute('UPDATE inputs SET state=?,reported=0 WHERE id=?', (state, message_id))

    def add_reply(self, thread, turn, item, text):
        """仅接收完整回复；稳定线程、轮次、条目键用于断线重传去重。"""
        if not all(isinstance(v, str) and v for v in (thread, turn, item, text)) or len(text) > 16000:
            raise ValueError('invalid_reply')
        event_id = fingerprint([thread, turn, item])
        digest = fingerprint(text)
        with self.db:
            row = self.db.execute('SELECT hash FROM replies WHERE id=?', (event_id,)).fetchone()
            if row and row['hash'] != digest:
                raise ValueError('reply_changed_after_completion')
            self.db.execute('INSERT OR IGNORE INTO replies VALUES(?,?,?,?,?,0)',
                            (event_id, thread, digest, text, time.time()))
        return event_id

    def pending(self, authorized):
        """生成有界上报批次；撤销共享或过期的正文立即清空，摘要保留去重。"""
        with self.db:
            for row in self.db.execute('SELECT id,thread,created FROM replies WHERE text IS NOT NULL').fetchall():
                if row['thread'] not in authorized or row['created'] < time.time() - 86400:
                    self.db.execute('UPDATE replies SET text=NULL,reported=1 WHERE id=?', (row['id'],))
        receipts = [{'id': row['id'], 'state': row['state'] if row['state'] in {'codex_received', 'failed'} else 'computer_received'}
                    for row in self.db.execute('SELECT * FROM inputs WHERE reported=0 LIMIT 100')]
        replies = [{'id': row['id'], 'threadId': row['thread'], 'text': row['text']}
                   for row in self.db.execute('SELECT * FROM replies WHERE reported=0 AND text IS NOT NULL LIMIT 100')]
        return receipts, replies

    def reported(self, receipts, replies):
        """仅成功同步后清理待发正文，超时保留原 ID 与内容。"""
        with self.db:
            for receipt in receipts:
                self.db.execute('UPDATE inputs SET reported=1 WHERE id=?', (receipt['id'],))
            for reply in replies:
                self.db.execute('UPDATE replies SET reported=1,text=NULL WHERE id=?', (reply['id'],))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """禁止跨站重定向泄漏电脑 Bearer 凭据。"""

    def redirect_request(self, request, fp, code, message, headers, newurl):
        """任何重定向都失败，由用户检查服务器配置。"""
        raise Unavailable('redirect_refused')


class RelayClient:
    """仅调用一个必要的电脑同步接口，不接受任意远端 URL。"""

    def __init__(self, base_url, token, allow_loopback=False):
        """只允许 HTTPS，显式调试时允许数字 loopback HTTP。"""
        url = urllib.parse.urlsplit(base_url)
        local = allow_loopback and url.scheme == 'http' and url.hostname in {'127.0.0.1', '::1'}
        if not (url.scheme == 'https' or local) or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in {'', '/'}:
            raise ValueError('invalid_relay_url')
        if not isinstance(token, str) or not token or any(c.isspace() for c in token):
            raise ValueError('invalid_token')
        self.url = base_url.rstrip('/') + '/api/desktop/v1/sync'
        self.token = token
        self.identity = fingerprint([base_url.rstrip('/'), token])
        self.opener = urllib.request.build_opener(NoRedirect())

    def sync(self, payload):
        """限时有界传输；未知响应保持日志待确认，不能触发输入重发。"""
        data = json.dumps(payload).encode()
        if len(data) > 256 * 1024:
            raise ValueError('sync_too_large')
        request = urllib.request.Request(self.url, data=data, headers={
            'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'})
        with self.opener.open(request, timeout=10) as response:
            raw = response.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise Unavailable('response_too_large')
        value = json.loads(raw)
        if not isinstance(value, dict) or not isinstance(value.get('commands'), list) or len(value['commands']) > 20:
            raise Unavailable('invalid_sync_response')
        return value


class DisabledCodex:
    """未证明兼容的桌面内部协议不能接收手机输入。"""

    def snapshot(self):
        """读取失败与空授权列表不同；失败时不得向服务发布虚假空快照。"""
        raise Unavailable('codex_transport_not_verified')

    def send(self, command):
        """始终在写入前拒绝，不自动启动新执行器接管会话。"""
        raise Rejected('codex_transport_not_verified')

    def replies(self):
        """未接入时没有可证明的回复事件。"""
        return []


class Bridge:
    """将经本机明确授权的快照与已验证执行器连接到中转服务。"""

    def __init__(self, relay, journal, codex):
        """依赖注入便于隔离测试；调用方必须单进程独占日志。"""
        self.relay, self.journal, self.codex = relay, journal, codex

    def step(self):
        """一次同步仅发送一次命令，异常后保持不确定而不重试 Codex 写入。"""
        tasks = self.codex.snapshot()
        if not isinstance(tasks, list) or len(tasks) > 100:
            raise Unavailable('invalid_snapshot')
        authorized = {task['id'] for task in tasks}
        if len(authorized) != len(tasks):
            raise Unavailable('duplicate_thread')
        for reply in self.codex.replies():
            if reply['threadId'] in authorized:
                self.journal.add_reply(reply['threadId'], reply['turnId'], reply['itemId'], reply['text'])
        receipts, replies = self.journal.pending(authorized)
        result = self.relay.sync({'tasks': tasks, 'receipts': receipts, 'replies': replies})
        self.journal.reported(receipts, replies)
        for command in result['commands']:
            if not isinstance(command, dict) or not all(isinstance(command.get(k), str) and command[k] for k in ('id', 'threadId', 'text')) or len(command['text']) > 16000:
                raise Unavailable('invalid_command')
            if not self.journal.begin(command):
                continue
            if command['threadId'] not in authorized:
                self.journal.finish(command['id'], 'failed')
                continue
            try:
                # 执行器负责提交前再次检查所有权、版本和目标活动轮次。
                evidence = self.codex.send(command)
                accepted = isinstance(evidence, dict) and evidence.get('accepted') is True and evidence.get('messageId') == command['id'] and evidence.get('threadId') == command['threadId'] and bool(evidence.get('turnId'))
                self.journal.finish(command['id'], 'codex_received' if accepted else 'uncertain')
            except Rejected:
                self.journal.finish(command['id'], 'failed')
            except Exception:
                self.journal.finish(command['id'], 'uncertain')
        return len(result['commands'])
