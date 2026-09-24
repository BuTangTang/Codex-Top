"""全部样例为合成，不连接桌面或读取真实 Codex 文件。"""
import tempfile
import unittest
from pathlib import Path
from bridge.core import Bridge, DisabledCodex, Journal, RelayClient, Rejected, Unavailable


class FakeRelay:
    """可重复派发和模拟 HTTP 结果丢失的合成服务。"""

    def __init__(self):
        """保存内存请求，不持有生产凭据。"""
        self.requests = []
        self.command = {'id': 'message-1', 'threadId': 'thread-1', 'text': 'synthetic'}
        self.fail = False

    def sync(self, payload):
        """重复返回同一输入，验证本机日志独立防重。"""
        self.requests.append(payload)
        if self.fail:
            raise TimeoutError()
        return {'commands': [self.command]}


class FakeCodex:
    """模拟接受证据，明确不代表真实桌面协议。"""

    def __init__(self):
        """设置合成线程与发送计数。"""
        self.count = 0
        self.mode = 'accept'
        self.events = []
        self.tasks = [{'id': 'thread-1', 'title': 'Synthetic'}]

    def snapshot(self):
        """返回明确允许共享的合成线程。"""
        return self.tasks

    def replies(self):
        """返回完整回复事件。"""
        return self.events

    def send(self, command):
        """模拟提交后超时和明确提交前拒绝。"""
        self.count += 1
        if self.mode == 'timeout':
            raise TimeoutError()
        if self.mode == 'reject':
            raise Rejected()
        return {'accepted': True, 'messageId': command['id'], 'threadId': command['threadId'], 'turnId': 'turn-1' if self.mode == 'accept' else ''}


class BridgeTests(unittest.TestCase):
    """验证发送日志、授权路由和未知状态语义。"""

    def setUp(self):
        """每项使用独立临时数据库。"""
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / 'journal.sqlite'
        self.journal = Journal(self.path, 'device-1')
        self.relay, self.codex = FakeRelay(), FakeCodex()
        self.bridge = Bridge(self.relay, self.journal, self.codex)

    def tearDown(self):
        """清理本测试日志。"""
        self.journal.close()
        self.directory.cleanup()

    def reopen(self):
        """模拟电脑适配器进程重启。"""
        self.journal.close()
        self.journal = Journal(self.path, 'device-1')
        self.bridge = Bridge(self.relay, self.journal, self.codex)

    def test_restart_does_not_repeat_accepted_input(self):
        """真实接受与完成不混淆，重启也不会二次发送。"""
        self.bridge.step()
        self.reopen()
        self.bridge.step()
        self.assertEqual(self.codex.count, 1)
        self.assertEqual(self.relay.requests[-1]['receipts'][0]['state'], 'codex_received')

    def test_timeout_does_not_retry(self):
        """提交结果未知不能自动重试。"""
        self.codex.mode = 'timeout'
        self.bridge.step()
        self.reopen()
        self.bridge.step()
        self.assertEqual(self.codex.count, 1)
        self.assertEqual(self.relay.requests[-1]['receipts'][0]['state'], 'computer_received')

    def test_crash_before_send_is_not_replayed(self):
        """保守策略允许未送达，但绝不以重启猜测已发送意图。"""
        self.journal.begin(self.relay.command)
        self.reopen()
        self.bridge.step()
        self.assertEqual(self.codex.count, 0)

    def test_wrong_thread_never_executes(self):
        """服务返回未授权线程时明确失败。"""
        self.relay.command['threadId'] = 'other-thread'
        self.bridge.step()
        self.bridge.step()
        self.assertEqual(self.codex.count, 0)
        self.assertEqual(self.relay.requests[-1]['receipts'][0]['state'], 'failed')

    def test_changed_duplicate_is_rejected(self):
        """相同输入 ID 不能替换正文。"""
        self.bridge.step()
        self.relay.command['text'] = 'changed'
        with self.assertRaises(ValueError):
            self.bridge.step()
        self.assertEqual(self.codex.count, 1)

    def test_missing_acceptance_evidence_remains_uncertain(self):
        """空轮次证据不能报告 Codex 收到。"""
        self.codex.mode = 'missing'
        self.bridge.step()
        self.assertEqual(self.journal.pending({'thread-1'})[0][0]['state'], 'computer_received')

    def test_explicit_rejection_is_failed(self):
        """明确未提交可以展示失败。"""
        self.codex.mode = 'reject'
        self.bridge.step()
        self.assertEqual(self.journal.pending({'thread-1'})[0][0]['state'], 'failed')

    def test_reply_retry_keeps_id(self):
        """HTTP 超时后的回复保留稳定事件 ID。"""
        self.codex.events = [{'threadId': 'thread-1', 'turnId': 'turn-1', 'itemId': 'item-1', 'text': 'synthetic reply'}]
        self.relay.fail = True
        with self.assertRaises(TimeoutError):
            self.bridge.step()
        event = self.relay.requests[-1]['replies'][0]['id']
        self.reopen()
        self.relay.fail = False
        self.bridge.step()
        self.assertEqual(self.relay.requests[-1]['replies'][0]['id'], event)
        self.bridge.step()
        self.assertEqual(self.relay.requests[-1]['replies'], [])

    def test_revocation_removes_pending_reply(self):
        """撤销会话不继续上报已缓存正文。"""
        self.journal.add_reply('thread-1', 'turn', 'item', 'synthetic')
        self.assertEqual(self.journal.pending(set())[1], [])

    def test_disabled_codex_does_not_publish_empty_snapshot(self):
        """接入不可用不等于用户主动撤销全部授权。"""
        self.bridge.codex = DisabledCodex()
        with self.assertRaises(Unavailable):
            self.bridge.step()
        self.assertEqual(self.relay.requests, [])

    def test_identity_cannot_change(self):
        """日志不能跨电脑凭据复用。"""
        self.journal.close()
        with self.assertRaises(ValueError):
            Journal(self.path, 'other-device')
        self.journal = Journal(self.path, 'device-1')

    def test_url_policy(self):
        """线上强制 HTTPS，调试只能明确 loopback。"""
        for url in ['http://example.com', 'https://user:pass@example.com', 'https://example.com/private', 'https://example.com?token=x']:
            with self.assertRaises(ValueError):
                RelayClient(url, 'synthetic-token')
        RelayClient('http://127.0.0.1:1234', 'synthetic-token', allow_loopback=True)

    def test_single_process_lock(self):
        """阻止两个适配器同时消费同一本机发送日志。"""
        with self.assertRaises(Unavailable):
            Journal(self.path, 'device-1')
