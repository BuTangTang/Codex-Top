"""容器内部健康检查：核对 HTTP 鉴权拒绝与数据库可读，不输出正文或凭据。"""
import sqlite3
import urllib.error
import urllib.request


def main():
    """无凭据请求必须收到 401，SQLite 完整性检查失败则让容器标记 unhealthy。"""
    try:
        urllib.request.urlopen('http://127.0.0.1:18766/api/mobile/v1/snapshot', timeout=2)
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise SystemExit(1)
    else:
        raise SystemExit(1)
    with sqlite3.connect('file:/data/relay.sqlite?mode=ro', uri=True, timeout=2) as database:
        if database.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise SystemExit(1)


if __name__ == '__main__':
    main()
