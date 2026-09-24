"""真实 loopback HTTP 测试：合成电脑与手机各自鉴权，不调用 Codex。"""
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from relay.server import Server
from relay.store import Store


class HttpTests(unittest.TestCase):
    """验证真实 HTTP 层的协议、账号边界及最小收发闭环。"""

    def setUp(self):
        """每次随机端口绑定独立临时数据库，绝不占用生产或现有联调端口。"""
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(str(Path(self.temp.name) / 'relay.sqlite'))
        self.store.add_account('synthetic', 'only-synthetic-password')
        self.desktop = self.store.add_device('synthetic', 'test-mac', 'Test Mac')
        self.server = Server(('127.0.0.1', 0), self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.route = '/api/mobile/v1/conversations/test-mac/thread-1/messages'
        self.task = {'id': 'thread-1', 'title': 'Synthetic conversation', 'phase': 'running'}

    def tearDown(self):
        """停止本用例服务，连接全部关闭后销毁数据库。"""
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.store.close()
        self.temp.cleanup()

    def request(self, method, path, token=None, body=None, raw=None):
        """发送实际网络请求；错误返回同样解析为 JSON，输出不包含令牌。"""
        data = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(self.base + path, method=method, data=data, headers=headers)
        try:
            response = urllib.request.urlopen(req, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def test_end_to_end_transport_and_receipts(self):
        """手机提交、电脑领取、接受回执和回复回传经过真实 HTTP；不伪称 Codex 实测。"""
        status, login = self.request('POST', '/api/mobile/v1/sessions', body={'username': 'synthetic', 'password': 'only-synthetic-password'})
        self.assertEqual(200, status)
        mobile = login['token']
        status, _ = self.request('POST', '/api/desktop/v1/sync', self.desktop, {'tasks': [self.task]})
        self.assertEqual(200, status)
        self.assertEqual(1, len(self.request('GET', '/api/mobile/v1/snapshot', mobile)[1]['tasks']))
        status, message = self.request('POST', self.route, mobile, {'id': 'request-1', 'text': 'Synthetic prompt'})
        self.assertEqual(200, status)
        self.assertEqual('server_received', message['state'])
        _, poll = self.request('POST', '/api/desktop/v1/sync', self.desktop, {'tasks': [self.task]})
        self.assertEqual(1, len(poll['commands']))
        status, result = self.request('POST', '/api/desktop/v1/sync', self.desktop, {
            'tasks': [self.task], 'receipts': [{'id': 'request-1', 'state': 'codex_received'}],
            'replies': [{'id': 'reply-1', 'threadId': 'thread-1', 'text': 'Synthetic reply'}]})
        self.assertEqual(200, status)
        self.assertEqual([], result['commands'])
        status, history = self.request('GET', self.route, mobile)
        self.assertEqual(200, status)
        self.assertEqual(['Synthetic prompt', 'Synthetic reply'], [m['text'] for m in history['messages']])
        self.assertEqual('codex_received', history['messages'][0]['state'])
        self.assertEqual(200, self.request('DELETE', '/api/mobile/v1/sessions/current', mobile)[0])
        self.assertEqual(401, self.request('GET', self.route, mobile)[0])

    def test_bad_json_and_wrong_role(self):
        """非对象、重复键与错误角色在 HTTP 层拒绝。"""
        for raw in [b'[]', b'{"username":"a","username":"b"}', b'{"username":NaN}']:
            self.assertEqual(400, self.request('POST', '/api/mobile/v1/sessions', raw=raw)[0])
        self.assertEqual(401, self.request('GET', self.route)[0])
        self.assertEqual(403, self.request('GET', '/api/mobile/v1/snapshot', self.desktop)[0])

    def test_login_rate_limit(self):
        """重复错误登录受到限流，而不是无限执行密码计算。"""
        for _ in range(10):
            self.assertEqual(401, self.request('POST', '/api/mobile/v1/sessions', body={'username': 'synthetic', 'password': 'incorrect'})[0])
        self.assertEqual(429, self.request('POST', '/api/mobile/v1/sessions', body={'username': 'synthetic', 'password': 'incorrect'})[0])

    def test_invalid_batch_does_not_partially_publish(self):
        """真实 HTTP 同步后半批无效时，先前快照也必须回滚。"""
        self.assertEqual(200, self.request('POST', '/api/desktop/v1/sync', self.desktop, {'tasks': [self.task]})[0])
        status, login = self.request('POST', '/api/mobile/v1/sessions', body={'username': 'synthetic', 'password': 'only-synthetic-password'})
        self.assertEqual(200, status)
        status, _ = self.request('POST', '/api/desktop/v1/sync', self.desktop,
            {'tasks': [], 'replies': [{'threadId': 'thread-1', 'id': 'reply', 'text': 'hidden'}]})
        self.assertEqual(404, status)
        self.assertEqual(1, len(self.request('GET', '/api/mobile/v1/snapshot', login['token'])[1]['tasks']))
        self.assertEqual(400, self.request('POST', '/api/desktop/v1/sync', self.desktop,
            {'tasks': [self.task], 'receipts': None})[0])

    def test_invalid_unicode_is_client_error(self):
        """编码异常应返回固定 400，不能令请求崩溃或写入不可读取快照。"""
        status, result = self.request('POST', '/api/desktop/v1/sync', self.desktop,
            {'tasks': [dict(self.task, title='\ud800')]})
        self.assertEqual(400, status)
        self.assertEqual('invalid_text', result['error'])
        self.assertEqual(400, self.request('GET', self.route + '?before=' + '9' * 5000, self.desktop)[0])

    def test_password_work_has_separate_concurrency_limit(self):
        """连接未满时昂贵密码运算仍限流，以遵守独立容器的内存上限。"""
        self.server.password_slots.acquire()
        self.server.password_slots.acquire()
        try:
            self.assertEqual(429, self.request('POST', '/api/mobile/v1/sessions',
                body={'username': 'synthetic', 'password': 'only-synthetic-password'})[0])
        finally:
            self.server.password_slots.release()
            self.server.password_slots.release()


if __name__ == '__main__':
    unittest.main()
