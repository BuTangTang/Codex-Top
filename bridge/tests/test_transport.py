"""真实 loopback 传输测试，不使用生产令牌或 Codex 数据。"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import unittest
from bridge.core import RelayClient, Unavailable


class Handler(BaseHTTPRequestHandler):
    """测试服务只返回合成同步响应。"""

    def do_POST(self):
        """记录合成请求并按用例模拟重定向或过大响应。"""
        self.server.seen = (self.path, self.headers.get('Authorization'), json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        if self.server.mode == 'redirect':
            self.send_response(302)
            self.send_header('Location', '/should-not-follow')
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'x' * (256 * 1024 + 1) if self.server.mode == 'oversize' else b'{"commands":[]}')

    def log_message(self, *args):
        """测试输出不打印请求或凭据。"""
        pass


class TransportTests(unittest.TestCase):
    """验证网络请求边界，而不是仅模拟客户端方法。"""

    def setUp(self):
        """随机本机端口，不占用其他任务服务。"""
        self.server = HTTPServer(('127.0.0.1', 0), Handler)
        self.server.mode = 'success'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.client = RelayClient('http://127.0.0.1:' + str(self.server.server_port), 'synthetic-token', allow_loopback=True)

    def tearDown(self):
        """关闭测试服务并等待线程退出。"""
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_sync_wire_contract(self):
        """验证路径、认证头、已有 sync JSON 字段。"""
        payload = {'tasks': [], 'receipts': [], 'replies': []}
        self.assertEqual(self.client.sync(payload), {'commands': []})
        self.assertEqual(self.server.seen, ('/api/desktop/v1/sync', 'Bearer synthetic-token', payload))

    def test_redirect_rejected(self):
        """不得将电脑凭据带往其他路径或域名。"""
        self.server.mode = 'redirect'
        with self.assertRaises(Unavailable):
            self.client.sync({'tasks': []})
        self.assertEqual(self.server.seen[0], '/api/desktop/v1/sync')

    def test_response_size_is_bounded(self):
        """异常服务器不能让电脑无限读取响应。"""
        self.server.mode = 'oversize'
        with self.assertRaises(Unavailable):
            self.client.sync({'tasks': []})
