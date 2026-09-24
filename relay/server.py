"""最小中转 HTTP 服务；公网入口必须由独立 HTTPS 反向代理提供。"""
import argparse
import getpass
import json
import logging
import os
import socket
import threading
import time
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

from .store import Store, RelayError, bounded

MOBILE = '/api/mobile/v1'
MAX_BODY = 262144


class Server(ThreadingHTTPServer):
    """限制并发连接与登录尝试，单独持有本服务数据库，不读取宿主其他服务。"""
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, store):
        """绑定显式地址；本地开发默认 loopback，容器仅通过受控端口映射访问。"""
        self.store = store
        self.slots = threading.BoundedSemaphore(16)
        self.password_slots = threading.BoundedSemaphore(2)
        self.attempts = OrderedDict()
        self.attempt_lock = threading.Lock()
        self.next_maintenance = 0.0
        super().__init__(address, Handler)

    def service_actions(self):
        """即使没有手机访问，也每分钟执行一次本服务的过期清理。"""
        if time.monotonic() >= self.next_maintenance:
            self.store.maintenance()
            self.next_maintenance = time.monotonic() + 60

    def process_request(self, request, client_address):
        """不为过量连接无限创建线程，饱和时关闭新连接供客户端稍后重试。"""
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        """每个连接无论成功或失败均归还并发名额。"""
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        """只记录固定错误，禁止默认 traceback 泄露请求或宿主路径。"""
        logging.error('relay_request_failed')

    def allow_login(self, ip):
        """对直连来源做有界登录限流，不信任客户端伪造的转发地址。"""
        now = time.monotonic()
        with self.attempt_lock:
            attempts = [t for t in self.attempts.pop(ip, []) if now - t < 60]
            allowed = len(attempts) < 10
            attempts.append(now)
            self.attempts[ip] = attempts[-10:]
            while len(self.attempts) > 4096:
                self.attempts.popitem(last=False)
            return allowed


class Handler(BaseHTTPRequestHandler):
    """固定 JSON 路由，不代理任意 URL、命令或 Codex 方法。"""
    server_version = 'CodexTopRelay'
    sys_version = ''

    def setup(self):
        """限制慢连接占用时间；正文与并发还有独立大小上限。"""
        self.request.settimeout(10)
        super().setup()

    def log_message(self, *_args):
        """不记录 URL、账号、令牌、正文和客户端地址。"""

    def send_error(self, code, message=None, explain=None):
        """HTTP 解析错误也使用固定 JSON，避免反射用户提供的 URL。"""
        self.respond(code, {'error': 'invalid_http_request'})

    def respond(self, status, body):
        """返回不可缓存的 JSON；明确结束连接，不在缓冲区遗留未消费正文。"""
        payload = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        self.wfile.write(payload)

    def body(self):
        """拒绝超大、重复键、非对象和歧义长度，不接受分块上传。"""
        lengths = self.headers.get_all('Content-Length', [])
        if len(lengths) != 1 or len(lengths[0]) > 10 or not lengths[0].isdigit() or self.headers.get('Transfer-Encoding'):
            raise RelayError(400, 'invalid_body_length')
        length = int(lengths[0])
        if not 0 < length <= MAX_BODY:
            raise RelayError(413, 'body_too_large')
        if self.headers.get_content_type() != 'application/json':
            raise RelayError(415, 'json_required')
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise RelayError(400, 'incomplete_body')
        try:
            result = json.loads(raw, object_pairs_hook=self.unique_object, parse_constant=self.reject_constant)
        except (ValueError, UnicodeError, RecursionError):
            raise RelayError(400, 'invalid_json') from None
        if not isinstance(result, dict):
            raise RelayError(400, 'object_required')
        return result

    @staticmethod
    def unique_object(pairs):
        """禁止重复 JSON 键，消除鉴权与业务解析不一致的输入。"""
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('duplicate_key')
            value[key] = item
        return value

    @staticmethod
    def reject_constant(_value):
        """JSON 数字不接受非标准 NaN 和 Infinity。"""
        raise ValueError('invalid_number')

    def token(self):
        """只接受一份明确 Bearer 凭据，不从 URL 或正文读取认证信息。"""
        values = self.headers.get_all('Authorization', [])
        if len(values) != 1 or not values[0].startswith('Bearer '):
            raise RelayError(401, 'unauthorized')
        return bounded(values[0][7:], 2048)

    def dispatch(self):
        """只暴露已有会话/快照与必要消息、电脑同步能力。"""
        url = urlsplit(self.path)
        if url.scheme or url.netloc or url.fragment:
            raise RelayError(400, 'invalid_path')
        path, store = url.path, self.server.store
        if self.command == 'POST' and path == MOBILE + '/sessions' and not url.query:
            if not self.server.allow_login(self.client_address[0]):
                raise RelayError(429, 'login_rate_limit')
            body = self.body()
            if not self.server.password_slots.acquire(blocking=False):
                raise RelayError(429, 'login_busy')
            try:
                return store.login(body.get('username'), body.get('password'))
            finally:
                self.server.password_slots.release()
        token = self.token()
        if self.command == 'DELETE' and path == MOBILE + '/sessions/current' and not url.query:
            store.logout(token)
            return {}
        if self.command == 'GET' and path == MOBILE + '/snapshot' and not url.query:
            return store.snapshot(token)
        segments = path.split('/')
        if len(segments) == 8 and segments[:5] == ['', 'api', 'mobile', 'v1', 'conversations'] and segments[7] == 'messages':
            device, thread = segments[5:7]
            if self.command == 'GET':
                query = parse_qs(url.query, keep_blank_values=True)
                if set(query) - {'before'} or ('before' in query and (len(query['before']) != 1 or len(query['before'][0]) > 19 or not query['before'][0].isdigit())):
                    raise RelayError(400, 'invalid_cursor')
                return store.history(token, device, thread, int(query['before'][0]) if 'before' in query else None)
            if self.command == 'POST' and not url.query:
                body = self.body()
                return store.submit(token, device, thread, body.get('id'), body.get('text'))
        if self.command == 'POST' and path == '/api/desktop/v1/sync' and not url.query:
            body = self.body()
            return store.sync(token, body.get('tasks'), body.get('receipts', []), body.get('replies', []))
        raise RelayError(404, 'not_found')

    def handle_api(self):
        """业务错误返回固定代码，未知异常不包含正文和数据库信息。"""
        try:
            self.respond(200, self.dispatch())
        except RelayError as error:
            self.respond(error.status, {'error': error.code})
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True
        except Exception:
            logging.error('relay_internal_error')
            try:
                self.respond(500, {'error': 'internal_error'})
            except OSError:
                pass

    def do_GET(self):
        """读取快照或指定对话，不返回任意数据库内容。"""
        self.handle_api()

    def do_POST(self):
        """处理登录、手机消息或已授权电脑同步。"""
        self.handle_api()

    def do_DELETE(self):
        """仅撤销当前手机会话。"""
        self.handle_api()


def main():
    """本机管理员通过终端初始化；密码隐藏输入，不写入命令行或日志。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', required=True)
    sub = parser.add_subparsers(dest='action', required=True)
    account = sub.add_parser('add-account')
    account.add_argument('account')
    device = sub.add_parser('add-device')
    device.add_argument('account')
    device.add_argument('device')
    device.add_argument('name')
    for action in ['rotate-device', 'revoke-device']:
        command = sub.add_parser(action)
        command.add_argument('account')
        command.add_argument('device')
    revoke = sub.add_parser('revoke-mobile-sessions')
    revoke.add_argument('account')
    serve = sub.add_parser('serve')
    serve.add_argument('--host', default='127.0.0.1')
    serve.add_argument('--port', type=int, default=18766)
    args = parser.parse_args()
    os.umask(0o077)
    Path(args.database).parent.mkdir(parents=True, exist_ok=True)
    store = Store(args.database)
    try:
        if args.action == 'add-account':
            password = getpass.getpass('密码（至少 12 位）：')
            if password != getpass.getpass('再次输入：'):
                raise RelayError(400, 'password_mismatch')
            store.add_account(args.account, password)
            print('账号已创建')
        elif args.action == 'add-device':
            print(store.add_device(args.account, args.device, args.name))
        elif args.action in {'rotate-device', 'revoke-device'}:
            token = store.manage_device(args.account, args.device, rotate=args.action == 'rotate-device')
            print(token if token else '电脑授权已撤销')
        elif args.action == 'revoke-mobile-sessions':
            store.revoke_mobile_sessions(args.account)
            print('手机登录已撤销')
        else:
            server = Server((args.host, args.port), store)
            try:
                server.serve_forever()
            finally:
                server.server_close()
    except RelayError as error:
        parser.exit(2, error.code + "\n")
    finally:
        store.close()


if __name__ == '__main__':
    main()
