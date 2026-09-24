"""仅供本机安卓联调的合成服务，不是可部署的账号服务器，不读取任何 Codex 数据。"""

import json
import secrets
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PREFIX = "/api/mobile/v1"
TOKENS = set()
STARTED_AT = int(time.time() * 1000)
STATE_FILE = Path(__file__).resolve().parents[2] / ".local/android-qa/fixture-state.json"


def snapshot():
    """返回小规模合成状态；测试脚本可在忽略目录中切换等待/完成/离线。"""
    now = int(time.time() * 1000)
    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    phase = state.get("phase", "running")
    event = state.get("event", "fixture-event-1")
    return {
        "version": 1, "serverTime": now,
        "devices": [
            {"id": "mac-demo", "name": "联调 Mac（合成）", "connected": not state.get("offline", False), "readState": "ready", "observedAt": now},
            {"id": "pc-demo", "name": "离线电脑（合成）", "connected": False, "readState": "ready", "observedAt": now - 480000},
        ],
        "tasks": [
            {"id": "review", "sourceId": "mac-demo", "title": "验证手机任务提醒（合成）", "project": "本地联调", "phase": phase, "turnId": "fixture-turn-1", "eventId": event, "eventAt": state.get("eventAt", STARTED_AT), "startedAt": STARTED_AT - 120000},
            {"id": "build", "sourceId": "mac-demo", "title": "缺少开始时间的任务（合成）", "project": "本地联调", "phase": "running", "turnId": "fixture-turn-2", "eventId": "event-2", "eventAt": STARTED_AT, "startedAt": None},
            {"id": "test", "sourceId": "mac-demo", "title": "已完成任务（合成）", "project": "本地联调", "phase": "completed", "turnId": "fixture-turn-3", "eventId": "event-3", "eventAt": now - 180000, "startedAt": now - 240000},
            {"id": "sync", "sourceId": "pc-demo", "title": "离线来源任务（合成）", "project": "本地联调", "phase": "running", "turnId": "fixture-turn-4", "eventId": "event-4", "eventAt": now - 480000, "startedAt": None},
        ],
    }


class Handler(BaseHTTPRequestHandler):
    """只提供客户端契约需要的三个接口，禁止当作生产认证实现。"""

    def log_message(self, *_args):
        """禁止默认 HTTP 日志输出路径、请求数据和账号信息。"""

    def log_request(self, code="-", size="-"):
        """联调只记录方法与状态码，定位连接问题时也不输出凭据和请求正文。"""
        print(self.command, code, flush=True)

    def reply(self, status, body=None):
        """以 JSON 返回合成结果，不缓存任何会话响应。"""
        payload = json.dumps(body or {}, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def authenticated(self):
        """检查联调时随机产生的会话；此内存存储不能用于生产。"""
        return self.headers.get("Authorization", "").removeprefix("Bearer ") in TOKENS

    def do_POST(self):
        """仅接受文档中的虚构测试账号，任何真实账号都不能在此服务注册。"""
        if self.path != PREFIX + "/sessions":
            self.reply(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 4096:
                self.reply(400)
                return
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self.reply(400)
            return
        if body.get("username") != "mobile-test" or body.get("password") != "fixture-only-password":
            self.reply(401)
            return
        token = secrets.token_urlsafe(32)
        TOKENS.add(token)
        self.reply(200, {"token": token, "account": "本机联调账号（合成）"})

    def do_GET(self):
        """每次读取重新检查会话，未登录时不返回合成任务。"""
        if not self.authenticated():
            self.reply(401)
        elif self.path == PREFIX + "/snapshot":
            self.reply(200, snapshot())
        else:
            self.reply(404)

    def do_DELETE(self):
        """撤销当前测试会话，其他会话保持有效。"""
        if not self.authenticated():
            self.reply(401)
        elif self.path == PREFIX + "/sessions/current":
            TOKENS.discard(self.headers.get("Authorization", "").removeprefix("Bearer "))
            self.reply(200)
        else:
            self.reply(404)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 18765), Handler).serve_forever()
