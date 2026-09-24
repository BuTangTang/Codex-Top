"""使用合成账号、可控时间和临时数据库验证真实存储事务，不连接任何现有服务。"""
import concurrent.futures
import tempfile
import unittest
from pathlib import Path
from relay.store import Store, RelayError, FRESH_MS, BODY_TTL_MS, SESSION_TTL_MS


class StoreTests(unittest.TestCase):
    """覆盖账号隔离、多电脑路由、持久去重、回执与失联恢复。"""

    def setUp(self):
        """每个用例使用独立目录和两个账号，避免真实正文或凭据进入测试。"""
        self.temp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.temp.name) / 'test.sqlite')
        self.now = 1_000_000
        self.store = Store(self.path, lambda: self.now)
        self.store.add_account('alpha', 'synthetic-password-alpha')
        self.store.add_account('beta', 'synthetic-password-beta')
        self.mobile = self.store.login('alpha', 'synthetic-password-alpha')['token']
        self.other = self.store.login('beta', 'synthetic-password-beta')['token']
        self.mac = self.store.add_device('alpha', 'mac', 'Mac example')
        self.pc = self.store.add_device('alpha', 'pc', 'PC example')
        self.other_mac = self.store.add_device('beta', 'mac', 'Other example')
        self.task = {'id': 'same-thread', 'title': 'Synthetic conversation', 'phase': 'running'}
        for token in [self.mac, self.pc, self.other_mac]:
            self.store.publish(token, [self.task])

    def tearDown(self):
        """关闭句柄并移除本用例自己的临时数据。"""
        self.store.close()
        self.temp.cleanup()

    def error(self, status, operation):
        """核对错误类别，不依赖内部数据库异常文案。"""
        with self.assertRaises(RelayError) as result:
            operation()
        self.assertEqual(status, result.exception.status)

    def send(self, message_id='message-1', body='Synthetic request', source='mac'):
        """提交固定合成消息，允许用例覆盖目标与幂等身份。"""
        return self.store.submit(self.mobile, source, 'same-thread', message_id, body)

    def test_account_and_device_isolation(self):
        """相同会话 ID 分属不同电脑与账号时，消息不会串线。"""
        self.send()
        self.assertEqual([], self.store.claim(self.pc))
        self.assertEqual([], self.store.claim(self.other_mac))
        self.assertEqual([], self.store.history(self.other, 'mac', 'same-thread')['messages'])
        self.assertEqual(1, len(self.store.claim(self.mac)))
        self.error(404, lambda: self.store.acknowledge(self.pc, 'message-1', 'codex_received'))

    def test_role_isolation(self):
        """手机不能上传快照或回复，电脑令牌不能以手机身份提交指令。"""
        self.error(403, lambda: self.store.publish(self.mobile, [self.task]))
        self.error(403, lambda: self.store.reply(self.mobile, 'same-thread', 'event', 'fake'))
        self.error(403, lambda: self.store.submit(self.mac, 'mac', 'same-thread', 'm', 'fake'))

    def test_duplicate_and_conflicting_retries(self):
        """同 ID 同内容返回原结果；改内容或目标不能借重试执行新指令。"""
        first = self.send()
        self.assertEqual(first, self.send())
        self.error(409, lambda: self.send(body='Different'))
        self.error(409, lambda: self.send(source='pc'))
        self.assertEqual(1, len(self.store.claim(self.mac)))
        self.assertEqual([], self.store.claim(self.mac))

    def test_concurrent_claim_once(self):
        """两个并发轮询者合计只能取得一份待执行输入。"""
        self.send()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.store.claim(self.mac), range(2)))
        self.assertEqual(1, sum(map(len, results)))

    def test_durable_deduplication_after_restart(self):
        """服务重启后仍记住已领取消息，不依赖进程内集合。"""
        self.send()
        self.store.claim(self.mac)
        self.store.close()
        self.store = Store(self.path, lambda: self.now)
        self.assertEqual('dispatching', self.send()['state'])
        self.assertEqual([], self.store.claim(self.mac))

    def test_offline_source_does_not_block_online_source(self):
        """某台心跳过期时只拒绝向该台发送。"""
        self.now += FRESH_MS + 1
        self.store.publish(self.pc, [self.task])
        self.error(409, self.send)
        self.assertEqual('server_received', self.send(source='pc')['state'])
        states = {d['id']: d['connected'] for d in self.store.snapshot(self.mobile)['devices']}
        self.assertEqual({'mac': False, 'pc': True}, states)

    def test_lost_claim_response_is_not_redelivered(self):
        """派发响应丢失后显示不确定，后台不得自动重复启动任务。"""
        self.send()
        self.store.claim(self.mac)
        self.now += FRESH_MS + 1
        self.assertEqual([], self.store.claim(self.mac))
        message = self.store.history(self.mobile, 'mac', 'same-thread')['messages'][0]
        self.assertEqual('uncertain', message['state'])
        self.store.acknowledge(self.mac, 'message-1', 'codex_received')
        self.assertEqual('codex_received', self.send()['state'])

    def test_receipts_never_confuse_server_and_codex(self):
        """未领取不能回执，已接受不能被滞后的电脑收到回执覆盖。"""
        self.send()
        self.error(409, lambda: self.store.acknowledge(self.mac, 'message-1', 'codex_received'))
        self.store.claim(self.mac)
        self.store.acknowledge(self.mac, 'message-1', 'computer_received')
        self.store.acknowledge(self.mac, 'message-1', 'codex_received')
        self.store.acknowledge(self.mac, 'message-1', 'codex_received')
        self.error(409, lambda: self.store.acknowledge(self.mac, 'message-1', 'computer_received'))
        self.error(409, lambda: self.store.acknowledge(self.mac, 'message-1', 'failed'))

    def test_revoked_conversation_cancels_pending_input(self):
        """电脑取消共享后不能继续读取正文或领取其待发送指令。"""
        self.send()
        self.store.publish(self.mac, [])
        self.error(404, lambda: self.store.history(self.mobile, 'mac', 'same-thread'))
        self.assertEqual([], self.store.claim(self.mac))
        self.store.publish(self.mac, [self.task])
        self.assertEqual('cancelled', self.send()['state'])

    def test_stale_unclaimed_input_never_runs_later(self):
        """发送后电脑失联，过时未领取输入不能在下次上线时突然执行。"""
        self.send()
        self.now += FRESH_MS + 1
        self.store.publish(self.mac, [self.task])
        self.assertEqual([], self.store.claim(self.mac))
        self.assertEqual('cancelled', self.send()['state'])

    def test_body_expiry_keeps_idempotency(self):
        """清除正文后仍保留去重凭据，同一消息不能再次启动。"""
        self.send()
        self.now += BODY_TTL_MS + 1
        self.store.publish(self.mac, [self.task])
        self.assertEqual('', self.send()['text'])
        self.assertEqual('expired', self.send()['state'])
        self.assertEqual([], self.store.claim(self.mac))

    def test_reply_deduplication_is_scoped_to_source(self):
        """两台电脑使用相同回复事件 ID 时仍各自保存，单台重试不重复。"""
        self.store.reply(self.mac, 'same-thread', 'same-event', 'Mac reply')
        self.store.reply(self.pc, 'same-thread', 'same-event', 'PC reply')
        self.store.reply(self.mac, 'same-thread', 'same-event', 'Mac reply')
        self.error(409, lambda: self.store.reply(self.mac, 'same-thread', 'same-event', 'Changed'))
        self.assertEqual(1, len(self.store.history(self.mobile, 'mac', 'same-thread')['messages']))
        self.assertEqual('PC reply', self.store.history(self.mobile, 'pc', 'same-thread')['messages'][0]['text'])

    def test_invalid_snapshot_rolls_back(self):
        """非法快照不能撤销上一次有效会话或发布半份来源。"""
        self.error(400, lambda: self.store.publish(self.mac, [self.task, self.task]))
        self.error(400, lambda: self.store.publish(self.mac, [dict(self.task, startedAt=True)]))
        self.assertEqual(2, len(self.store.snapshot(self.mobile)['tasks']))

    def test_session_revocation_and_expiry(self):
        """注销与到期令牌不能继续查询消息，其他账号不受影响。"""
        self.store.logout(self.mobile)
        self.error(401, lambda: self.store.snapshot(self.mobile))
        self.assertEqual(1, len(self.store.snapshot(self.other)['devices']))
        self.now += SESSION_TTL_MS + 1
        self.error(401, lambda: self.store.snapshot(self.other))

    def test_history_pagination(self):
        """按稳定序号翻页，后续新消息不会造成旧页重复或丢失。"""
        for i in range(102):
            self.store.reply(self.mac, 'same-thread', f'e-{i}', str(i))
        page = self.store.history(self.mobile, 'mac', 'same-thread')
        self.assertEqual(100, len(page['messages']))
        self.store.reply(self.mac, 'same-thread', 'new', 'new')
        older = self.store.history(self.mobile, 'mac', 'same-thread', page['olderCursor'])
        self.assertEqual(['0', '1'], [m['text'] for m in older['messages']])
        self.assertIsNone(older['olderCursor'])

    def test_invalid_route_and_empty_message(self):
        """拒绝可混淆路由的字符与空消息，不把无效输入交给电脑。"""
        self.error(400, lambda: self.send(source='../mac'))
        self.error(400, lambda: self.send(body='  '))
        self.error(400, lambda: self.send(body='a' * 8001))
        self.error(400, lambda: self.send(message_id='bad\0id'))

    def test_idle_maintenance_removes_expired_body(self):
        """无手机访问时维护任务仍清除正文，避免保留期依赖用户打开页面。"""
        self.send()
        self.now += BODY_TTL_MS + 1
        self.store.maintenance()
        row = self.store.db.execute("SELECT body,state FROM messages WHERE id='message-1'").fetchone()
        self.assertEqual(('', 'expired'), tuple(row))

    def test_malformed_receipt_and_cursor(self):
        """错误回执类型与超范围游标必须成为业务拒绝而不是内部异常。"""
        self.error(400, lambda: self.store.acknowledge(self.mac, 'message-1', []))
        self.error(400, lambda: self.store.history(self.mobile, 'mac', 'same-thread', 10**30))

    def test_sync_failure_rolls_back_whole_batch(self):
        """后半批回复冲突时回滚前面的回执与共享变化，允许相同批次安全修复重试。"""
        self.send()
        self.store.claim(self.mac)
        self.store.reply(self.mac, 'same-thread', 'reply-1', 'first')
        self.error(409, lambda: self.store.sync(self.mac, [dict(self.task, title='Changed')],
            [{'id': 'message-1', 'state': 'codex_received'}],
            [{'id': 'reply-1', 'threadId': 'same-thread', 'text': 'conflict'}]))
        page = self.store.history(self.mobile, 'mac', 'same-thread')
        self.assertEqual(self.task['title'], page['task']['title'])
        self.assertEqual('dispatching', page['messages'][0]['state'])
        result = self.store.sync(self.mac, [self.task], [{'id': 'message-1', 'state': 'codex_received'}], [])
        self.assertEqual([], result['commands'])
        self.assertEqual('codex_received', self.send()['state'])

    def test_admin_rotation_revokes_old_token_and_pending_work(self):
        """电脑轮换保留去重身份但撤销旧令牌与待派发，且不影响另一来源。"""
        self.send()
        replacement = self.store.manage_device('alpha', 'mac', rotate=True)
        self.error(401, lambda: self.store.publish(self.mac, [self.task]))
        self.error(404, lambda: self.store.history(self.mobile, 'mac', 'same-thread'))
        self.store.publish(replacement, [self.task])
        self.assertEqual([], self.store.claim(replacement))
        self.assertEqual('cancelled', self.send()['state'])
        self.store.publish(self.pc, [self.task])
        self.store.manage_device('alpha', 'mac')
        self.error(401, lambda: self.store.claim(replacement))
        self.assertEqual([], self.store.claim(self.pc))

    def test_expired_desktop_can_be_rotated_without_recreating_identity(self):
        """七天到期可通过本机管理员恢复原电脑身份，不要求删除数据库或换来源 ID。"""
        self.now += SESSION_TTL_MS + 1
        self.error(401, lambda: self.store.publish(self.mac, [self.task]))
        replacement = self.store.manage_device('alpha', 'mac', rotate=True)
        self.store.publish(replacement, [self.task])
        self.assertEqual([], self.store.claim(replacement))

    def test_admin_mobile_revocation_is_account_scoped(self):
        """丢失手机后管理员撤销全部手机会话，其他账号与电脑继续工作。"""
        second = self.store.login('alpha', 'synthetic-password-alpha')['token']
        self.store.revoke_mobile_sessions('alpha')
        for token in [self.mobile, second]:
            self.error(401, lambda: self.store.snapshot(token))
        self.assertEqual(1, len(self.store.snapshot(self.other)['devices']))
        self.store.publish(self.mac, [self.task])

    def test_history_large_messages_have_bounded_pages(self):
        """长正文页面不超过手机响应上限，分页拼接仍完整且无重复。"""
        import json
        for number in range(30):
            self.store.reply(self.mac, 'same-thread', f'large-{number}', '\x01' * 16000)
        page = self.store.history(self.mobile, 'mac', 'same-thread')
        ids = []
        while True:
            self.assertLess(len(json.dumps(page, ensure_ascii=False).encode()), 600 * 1024)
            ids.extend(message['id'] for message in page['messages'])
            if page['olderCursor'] is None:
                break
            page = self.store.history(self.mobile, 'mac', 'same-thread', page['olderCursor'])
        self.assertEqual(30, len(ids))
        self.assertEqual(30, len(set(ids)))

    def test_surrogate_text_is_rejected_before_encoding(self):
        """JSON 转义产生的孤立代理字符要返回业务错误，不触发编码崩溃。"""
        self.error(400, lambda: self.send(body='\ud800'))
        self.error(400, lambda: self.store.publish(self.mac, [dict(self.task, title='\udfff')]))


if __name__ == '__main__':
    unittest.main()
