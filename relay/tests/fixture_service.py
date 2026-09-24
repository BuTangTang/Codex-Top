"""仅供安卓仪器测试的合成电脑；无 Codex 访问，不可作为真实执行器部署。"""
import json
import threading
import urllib.request
from relay.server import Server
from relay.store import Store


def run():
    """内存账号服务与合成电脑经真实 HTTP 往返，退出即丢弃全部数据。"""
    store = Store(':memory:')
    store.add_account('mobile-test', 'fixture-only-password')
    token = store.add_device('mobile-test', 'relay-mac', '合成联调电脑')
    task = {'id': 'chat-example', 'title': '手机对话联调（合成）', 'phase': 'running'}
    store.publish(token, [task])
    server = Server(('127.0.0.1', 18766), store)
    stop = threading.Event()

    def computer():
        """合成电脑只回固定样例，不调用模型或执行手机消息内容。"""
        receipts, replies = [], []
        while not stop.is_set():
            payload = json.dumps({'tasks': [task], 'receipts': receipts, 'replies': replies}).encode()
            request = urllib.request.Request('http://127.0.0.1:18766/api/desktop/v1/sync', data=payload,
                headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
            try:
                with urllib.request.urlopen(request, timeout=3) as response:
                    commands = json.load(response)['commands']
                receipts = [{'id': item['id'], 'state': 'codex_received'} for item in commands]
                replies = [{'id': item['id'], 'threadId': item['threadId'], 'text': '合成回复：已收到手机消息'} for item in commands]
            except (OSError, ValueError):
                pass
            stop.wait(0.2)
    feeder = threading.Thread(target=computer, daemon=True)
    feeder.start()
    try:
        server.serve_forever()
    finally:
        stop.set()
        server.server_close()
        feeder.join(timeout=4)
        store.close()


if __name__ == '__main__':
    run()
