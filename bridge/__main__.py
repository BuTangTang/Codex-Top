"""当前真实执行器尚未验证，入口明确失败，禁止误报可用。"""
from .core import DisabledCodex, Unavailable


def main():
    """不获取令牌、不连接真实会话；兼容验证完成前返回非零退出码。"""
    try:
        DisabledCodex().snapshot()
    except Unavailable:
        print('Codex 接入尚未验证；电脑转发未启动。详见 bridge/README.md。')
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
