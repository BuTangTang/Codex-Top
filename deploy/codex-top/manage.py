#!/usr/bin/env python3
"""Codex Top 专用部署入口；仅 check 可在非 Linux 主机运行。"""

import argparse
import contextlib
import datetime
from decimal import Decimal
import fcntl
import io
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit

ROOT = Path('/opt/codex-top')
HERE = Path(__file__).resolve().parent
PROJECT = 'codex-top'
NETWORK = 'codex-top-private'
PREFIX = 'CODEX_TOP_'
FIELDS = ('ROOT IMAGE PORT PUBLIC_URL CPUS MEMORY PIDS LOG_SIZE LOG_FILES '
          'MIN_FREE_MEMORY_BYTES MIN_FREE_DISK_BYTES BACKUP_MAX_BYTES BACKUP_MAX_COUNT '
          'BACKUP_RECIPIENT WAIT_SECONDS STOP_SECONDS HTTPS_IMAGE HTTPS_CPUS HTTPS_MEMORY '
          'HTTPS_PIDS HTTPS_LOG_SIZE HTTPS_LOG_FILES').split()
ROLES = ('server', 'https')
HTTPS_FIELDS = tuple(key for key in FIELDS if key.startswith('HTTPS_'))
# 白名单固定本批已审 Caddyfile；模板变更必须与维护校验共同审查，不能自证任意上游合法。
CADDYFILE_SHA256 = 'd8d49d4a6ba8df8429973f5485be94a88e179d1b8e536f1c22a65883447e2cbc'


def require(condition, message):
    """前置条件不成立即停止，不通过猜测或默认值继续发布。"""
    if not condition:
        raise RuntimeError(message)


def run(args, input_text=None):
    """执行明确参数的命令；清除 Compose 插值覆盖，不回显潜在敏感输出。"""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('COMPOSE_', PREFIX))}
    result = subprocess.run([str(x) for x in args], input=input_text, env=env,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, '命令失败：' + ' '.join(str(x) for x in args[:3]))
    return result.stdout


def compose_cli():
    """优先使用 Docker Compose 插件，兼容本机独立 docker-compose 命令。"""
    try:
        run(['docker', 'compose', 'version'])
        return ['docker', 'compose']
    except (RuntimeError, FileNotFoundError):
        run(['docker-compose', 'version'])
        return ['docker-compose']


def parse_env(text):
    """只接收无秘密的显式配置；代理 IP 从唯一 HTTPS IPv4 origin 派生。"""
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        require(sep and key in [PREFIX + k for k in FIELDS] and key not in values,
                '配置存在未知项或重复项')
        require(value and not any(c.isspace() or c in "\"'$\\#" or ord(c) == 96 for c in value),
                '配置需填写无引号、无插值的单个值：' + key)
        values[key] = value
    require(set(values) == {PREFIX + k for k in FIELDS}, '配置必填项不完整')
    cfg = {k: values[PREFIX + k] for k in FIELDS}
    require(cfg['ROOT'] == str(ROOT), '数据根目录必须为 /opt/codex-top')
    for key in ('IMAGE', 'HTTPS_IMAGE'):
        require(re.fullmatch(r'(?:sha256:|[a-zA-Z0-9._:/-]+@sha256:)[0-9a-f]{64}', cfg[key]),
                key + ' 必须为已预装 sha256 ID 或仓库摘要')
    for key in ('PORT', 'PIDS', 'LOG_FILES', 'HTTPS_PIDS', 'HTTPS_LOG_FILES',
                'MIN_FREE_MEMORY_BYTES', 'MIN_FREE_DISK_BYTES', 'BACKUP_MAX_BYTES',
                'BACKUP_MAX_COUNT', 'WAIT_SECONDS', 'STOP_SECONDS'):
        require(re.fullmatch(r'[1-9][0-9]*', cfg[key]), key + ' 必须为正整数')
    require(1024 <= int(cfg['PORT']) <= 65535, '业务回环端口需在 1024..65535 内')
    for key in ('CPUS', 'HTTPS_CPUS'):
        require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', cfg[key]) and Decimal(cfg[key]) > 0,
                key + ' 必须大于 0')
    for key in ('MEMORY', 'LOG_SIZE', 'HTTPS_MEMORY', 'HTTPS_LOG_SIZE'):
        require(re.fullmatch(r'[1-9][0-9]*[kKmMgG]', cfg[key]), key + ' 需为整数加 k/m/g')
    public_ip(cfg)
    require(re.fullmatch(r'age1[0-9a-z]+', cfg['BACKUP_RECIPIENT']), '需填写 age 公钥 recipient')
    return cfg


def public_ip(cfg):
    """要求唯一 origin 为规范的 https://IPv4；443 固定，不接受另一份 IP 配置。"""
    origin = urlsplit(cfg['PUBLIC_URL'])
    address = ipaddress.IPv4Address(origin.hostname or '')
    require(cfg['PUBLIC_URL'] == 'https://' + str(address), 'PUBLIC_URL 必须为 https://IPv4，无端口或路径')
    return str(address)


def caddy_digest(release):
    """为固定 Caddyfile 生成 Compose 配置标签，内容变化时让代理重建并重新绑定文件。"""
    return hashlib.sha256(release['caddyfile'].encode()).hexdigest()


def expected_mounts(role):
    """只定义业务与代理这两个角色的固定挂载；代理不接触业务库或宿主 socket。"""
    require(role in ROLES, '未知服务角色')
    if role == 'server':
        return {'/data': (str(ROOT / 'data'), False)}
    return {'/etc/caddy/Caddyfile': (str(ROOT / 'Caddyfile'), True),
            '/data': (str(ROOT / 'https/data'), False),
            '/config': (str(ROOT / 'https/config'), False)}

def env_text(cfg):
    """把已验证配置写成确定顺序，不存放账号、密码或服务主密钥。"""
    return ''.join(PREFIX + k + '=' + cfg[k] + '\n' for k in FIELDS)


@contextlib.contextmanager
def compose_command(release):
    """命令使用私有 Compose 快照；IP/配置指纹只能由已审 release 派生，不接收环境覆盖。"""
    with tempfile.TemporaryDirectory(prefix='codex-top-config-') as directory:
        directory = Path(directory)
        derived = ('CODEX_TOP_PUBLIC_IP=' + public_ip(release['config']) + '\n'
                   'CODEX_TOP_CADDYFILE_SHA256=' + caddy_digest(release) + '\n')
        (directory / '.env').write_text(env_text(release['config']) + derived)
        (directory / 'compose.yaml').write_text(release['compose'])
        yield compose_cli() + ['--project-name', PROJECT, '--env-file', directory / '.env',
                               '-f', directory / 'compose.yaml']

def validate_release(release):
    """精确校验两个固定角色、端口/挂载/配额及模板，拒绝第三服务和不受控代理配置。"""
    require(isinstance(release, dict) and release.get('schema') == 2,
            '仅接受两服务 schema=2 快照；旧快照需单独审核迁移')
    require(set(release['config']) == set(FIELDS), '归档配置字段不完整或含额外项')
    cfg = parse_env(env_text(release['config']))
    require(isinstance(release['caddyfile'], str) and caddy_digest(release) == CADDYFILE_SHA256
            and release['caddyfile'] == (HERE / 'Caddyfile').read_text(), 'Caddyfile 不符合当前已审固定模板')
    with compose_command(release) as command:
        model = json.loads(run(command + ['config', '--format', 'json']), parse_float=Decimal)
    require(set(model) <= {'services', 'networks', 'name'}
            and set(model['services']) == set(ROLES) and model['name'] == PROJECT,
            'Compose 只能含 codex-top 的 server/https')
    require(set(model['networks']) == {'private'}, '只能使用独立网络')
    network = model['networks']['private']
    require(network['name'] == NETWORK and network.get('driver') == 'bridge'
            and not network.get('ipam') and not network.get('external') and not network.get('internal'),
            '必须使用本项目普通 bridge，允许代理 ACME 出站')
    server_env = {'NODE_ENV': 'production', 'PORT': '3005', 'PUBLIC_URL': cfg['PUBLIC_URL'],
                  'HAPPIER_SERVER_FLAVOR': 'light', 'HAPPIER_DB_PROVIDER': 'sqlite',
                  'HAPPIER_SERVER_LIGHT_DATA_DIR': '/data', 'HAPPIER_SQLITE_AUTO_MIGRATE': '1',
                  'RUN_MIGRATIONS': '1', 'HAPPIER_FEATURE_AUTH_LOGIN__PASSWORD_ENABLED': 'true',
                  'HAPPIER_FEATURE_AUTH_LOGIN__KEY_CHALLENGE_ENABLED': 'true',
                  'AUTH_ANONYMOUS_SIGNUP_ENABLED': 'false', 'AUTH_SIGNUP_PROVIDERS': '',
                  'AUTH_REQUIRED_LOGIN_PROVIDERS': ''}
    for role in ROLES:
        service = model['services'][role]
        prefix = '' if role == 'server' else 'HTTPS_'
        allowed = {'image', 'user', 'init', 'restart', 'ports', 'environment', 'volumes', 'networks',
                   'cpus', 'mem_limit', 'memswap_limit', 'pids_limit', 'security_opt', 'cap_drop',
                   'cap_add', 'logging', 'healthcheck', 'command', 'entrypoint', 'labels'}
        require(not (set(service) - allowed), role + ' 含不允许的属性')
        require(service['image'] == cfg[prefix + 'IMAGE'] and service['user'] == '1000:1000'
                and service.get('init') is True and service.get('restart') == 'unless-stopped'
                and not service.get('command') and not service.get('entrypoint'), role + ' 镜像或入口不符')
        ports = service['ports']
        host_ip, published, target = ('127.0.0.1', cfg['PORT'], 3005) if role == 'server' else ('0.0.0.0', '443', 443)
        require(len(ports) == 1 and ports[0]['host_ip'] == host_ip
                and str(ports[0]['published']) == published and ports[0]['target'] == target
                and ports[0].get('protocol', 'tcp') == 'tcp', role + ' 端口边界不符')
        expected = expected_mounts(role)
        mounts = service['volumes']
        require(len(mounts) == len(expected) and {mount['target'] for mount in mounts} == set(expected),
                role + ' 挂载数量或目标不符')
        for mount in mounts:
            source, readonly = expected[mount['target']]
            require(mount['type'] == 'bind' and mount['source'] == source
                    and bool(mount.get('read_only')) == readonly, role + ' 挂载越界')
        require(set(service['networks']) == {'private'}, role + ' 连接了其他网络')
        require(service['cap_drop'] == ['ALL'] and service['security_opt'] == ['no-new-privileges:true']
                and service.get('cap_add', []) == ([] if role == 'server' else ['NET_BIND_SERVICE']),
                role + ' 权限约束缺失')
        memory = cfg[prefix + 'MEMORY']
        size = int(memory[:-1]) * {'k': 1024, 'm': 1024 ** 2, 'g': 1024 ** 3}[memory[-1].lower()]
        require(Decimal(str(service['cpus'])) == Decimal(cfg[prefix + 'CPUS'])
                and service['pids_limit'] == int(cfg[prefix + 'PIDS'])
                and Decimal(str(service['mem_limit'])) == size
                and Decimal(str(service['memswap_limit'])) == size, role + ' 精确配额不符')
        require(service['logging']['driver'] == 'json-file'
                and service['logging']['options'] == {'max-file': cfg[prefix + 'LOG_FILES'],
                                                       'max-size': cfg[prefix + 'LOG_SIZE']},
                role + ' 日志上限不符')
        expected_env = server_env if role == 'server' else {
            'PUBLIC_IP': public_ip(cfg), 'XDG_DATA_HOME': '/data', 'XDG_CONFIG_HOME': '/config'}
        require(service['environment'] == expected_env, role + ' 环境变量越界')
        labels = {} if role == 'server' else {'io.codex-top.caddyfile-sha256': caddy_digest(release)}
        require(service.get('labels', {}) == labels, role + ' 配置标签不符')
        health = (['CMD', 'curl', '--fail', '--silent', 'http://127.0.0.1:3005/ready'] if role == 'server'
                  else ['CMD', 'wget', '-q', '-O', '/dev/null', 'http://127.0.0.1:2019/config/'])
        require(service['healthcheck']['test'] == health and not service['healthcheck'].get('disable'),
                role + ' 健康检查不符')
    return model

def private_path(path):
    """拒绝根目录或现有子路径的符号链接，避免写出项目边界。"""
    require(path == ROOT or ROOT in path.parents, '路径不属于本项目')
    for item in [path] + list(path.parents):
        require(not item.is_symlink(), '部署路径不允许符号链接')


def inspect_containers():
    """只读容器元数据；原始 inspect（含环境）只保留在进程内。"""
    ids = run(['docker', 'ps', '-aq']).split()
    return json.loads(run(['docker', 'inspect'] + ids)) if ids else []


def own_containers(containers):
    """逐个验证同项目角色的用户、端口、挂载和网络，拒绝标签相同但实际越界的容器。"""
    result = {}
    for item in containers:
        labels = item['Config'].get('Labels') or {}
        if labels.get('com.docker.compose.project') != PROJECT:
            continue
        role = labels.get('com.docker.compose.service')
        require(role in ROLES and role not in result, '项目角色冲突或重复实例')
        require(item['Config'].get('User') == '1000:1000', '既有容器不是已审非 root 用户')
        bindings = item['HostConfig'].get('PortBindings') or {}
        port_key = '3005/tcp' if role == 'server' else '443/tcp'
        require(set(bindings) == {port_key} and len(bindings[port_key] or []) == 1, '既有容器端口数量不符')
        binding = bindings[port_key][0]
        host_ip = '127.0.0.1' if role == 'server' else '0.0.0.0'
        require(binding.get('HostIp') == host_ip and str(binding.get('HostPort', '')).isdigit(),
                '既有容器端口地址不符')
        port = int(binding['HostPort'])
        require((role == 'server' and 1024 <= port <= 65535) or (role == 'https' and port == 443),
                '既有容器端口范围不符')
        expected = expected_mounts(role)
        mounts = item['Mounts']
        require(len(mounts) == len(expected) and {mount['Destination'] for mount in mounts} == set(expected),
                '既有容器挂载目标不属于本部署')
        for mount in mounts:
            source, readonly = expected[mount['Destination']]
            require(mount.get('Type') == 'bind' and mount['Source'] == source
                    and mount.get('RW') is (not readonly), '既有容器数据挂载不属于本部署')
        require(set(item['NetworkSettings']['Networks']) <= {NETWORK}, '既有容器连接了其他网络')
        result[role] = item
    return result


def own_container(containers):
    """保留业务角色读取入口，仍先核验同项目所有角色。"""
    return own_containers(containers).get('server')

def neighbors(containers):
    """只排除已通过归属验证的两个角色；其余容器保留匿名前后对照。"""
    owned_ids = {item['Id'] for item in own_containers(containers).values()}
    return {c['Id']: {'image': c['Image'], 'running': c['State']['Running'],
                     'started': c['State']['StartedAt'], 'restarts': c['RestartCount'],
                     'health': c['State'].get('Health', {}).get('Status'),
                     'ports': c['HostConfig'].get('PortBindings')}
            for c in containers if c['Id'] not in owned_ids}

def host_guard():
    """检查固定 Linux 安装位置、本地 Docker 及业务/TLS 私有目录，不自动修复权限。"""
    require(platform.system() == 'Linux' and os.geteuid() == 0, '实际操作需在目标 Linux 上通过 sudo 执行')
    require(not os.environ.get('DOCKER_HOST') and not os.environ.get('DOCKER_CONTEXT'),
            '拒绝环境指定的 Docker 远端；在目标主机运行')
    context = json.loads(run(['docker', 'context', 'inspect']))[0]
    require(context['Endpoints']['docker']['Host'] == 'unix:///var/run/docker.sock', '只允许本机系统 Docker')
    for path in (ROOT, ROOT / '.env', ROOT / 'data', ROOT / 'backups', ROOT / 'state',
                 ROOT / 'Caddyfile', ROOT / 'https/data', ROOT / 'https/config'):
        private_path(path)
    require(ROOT.is_dir() and ROOT.stat().st_uid == 0 and stat.S_IMODE(ROOT.stat().st_mode) == 0o700,
            '根目录需 root 持有且权限 700')
    require((ROOT / '.env').stat().st_uid == 0 and stat.S_IMODE((ROOT / '.env').stat().st_mode) == 0o600,
            '.env 需 root 持有且权限 600')
    require((ROOT / 'data').is_dir() and (ROOT / 'data').stat().st_uid == 1000
            and stat.S_IMODE((ROOT / 'data').stat().st_mode) == 0o700, 'data 需 UID 1000 持有且权限 700')
    for directory in (ROOT / 'https/data', ROOT / 'https/config'):
        require(directory.is_dir() and directory.stat().st_uid == 1000
                and stat.S_IMODE(directory.stat().st_mode) == 0o700, 'TLS 目录需 UID 1000 持有且权限 700')
    require(shutil.which('age'), '目标主机需预装 age；本工具不自动安装软件')


def preflight(release):
    """只读核对双镜像、合计预算、回环/443 端口和网络端点；不拉取、不签发。"""
    cfg = release['config']
    run(['age', '-a', '-r', cfg['BACKUP_RECIPIENT']], input_text='')
    for role in ROLES:
        key = 'IMAGE' if role == 'server' else 'HTTPS_IMAGE'
        image = json.loads(run(['docker', 'image', 'inspect', cfg[key]]))[0]
        release['image_id' if role == 'server' else 'https_image_id'] = image['Id']
        if role == 'server':
            require(image['Config']['User'] in ('node', '1000', '1000:1000')
                    and image['Config']['Cmd'] == ['run-server'], '镜像不是预期非 root server target')
        else:
            require(image['Config']['Cmd'] == ['caddy', 'run', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'],
                    '代理镜像入口不符；UID/capability 仍需真实镜像验收')
    require(ipaddress.IPv4Address(public_ip(cfg)).is_global, '正式入口需可公开路由的受控 IPv4')
    memory = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
    available = int(memory['MemAvailable'].split()[0]) * 1024
    model = validate_release(release)
    limits = sum(int(model['services'][role]['mem_limit']) for role in ROLES)
    require(available >= limits + int(cfg['MIN_FREE_MEMORY_BYTES']), '两服务合计内存不足以保留余量')
    require(Decimal(cfg['CPUS']) + Decimal(cfg['HTTPS_CPUS']) <= (os.cpu_count() or 1),
            '两服务合计 CPU 配额超过本机总数')
    require(shutil.disk_usage(ROOT).free >= int(cfg['MIN_FREE_DISK_BYTES']), '磁盘余量不足')
    containers = inspect_containers()
    owned = own_containers(containers)
    for role, address, port in (('server', '127.0.0.1', cfg['PORT']), ('https', '0.0.0.0', '443')):
        own = owned.get(role)
        for item in containers:
            for bindings in (item['HostConfig'].get('PortBindings') or {}).values():
                for binding in bindings or []:
                    require(binding['HostPort'] != port or item is own, '宿主端口被其他容器占用：' + port)
        bindings = (own or {}).get('HostConfig', {}).get('PortBindings') or {}
        using = any(binding.get('HostPort') == port for rows in bindings.values() for binding in (rows or []))
        if not (own and own['State']['Running'] and using):
            with socket.socket() as probe:
                probe.bind((address, int(port)))
    for network_id in run(['docker', 'network', 'ls', '--filter', 'name=^' + NETWORK + '$', '-q']).split():
        network = json.loads(run(['docker', 'network', 'inspect', network_id]))[0]
        require((network.get('Labels') or {}).get('com.docker.compose.project') == PROJECT
                and set(network.get('Containers') or {}) <= {item['Id'] for item in owned.values()},
                '专用网络已被其他容器或项目占用')
    return containers

def save_release(release):
    """原子保存分角色发布进度；业务安装尝试和代理版本记录均不表示功能验收通过。"""
    state = ROOT / 'state'
    state.mkdir(mode=0o700, exist_ok=True)
    temporary = state / 'release.json.tmp'
    private_path(temporary)
    private_path(state / 'release.json')
    temporary.write_text(json.dumps(release, ensure_ascii=False))
    os.chmod(temporary, 0o600)
    temporary.replace(state / 'release.json')


def load_release():
    """读取已管理版本，拒绝无部署记录的既有数据被直接接管。"""
    path = ROOT / 'state/release.json'
    private_path(path)
    require(path.is_file(), '既有数据缺少部署记录，需先安排独立迁移/接管，不能自动覆盖')
    release = json.loads(path.read_text())
    validate_release(release)
    return release


def with_current_proxy(release, current):
    """合成目标业务与已记录代理的两角色快照；不改输入，也不允许混用不同 origin。"""
    require(release['config']['PUBLIC_URL'] == current['config']['PUBLIC_URL'],
            'PUBLIC_URL 与当前 HTTPS 入口不一致；入口迁移需单独处理')
    model = validate_release(release)
    current_model = validate_release(current)
    combined = dict(release, config=dict(release['config']))
    combined['config'].update({key: current['config'][key] for key in HTTPS_FIELDS})
    combined['https_image_id'] = current['https_image_id']
    combined['caddyfile'] = current['caddyfile']
    model['services']['https'] = current_model['services']['https']
    combined['compose'] = json.dumps(model, default=str)
    validate_release(combined)
    return combined


def stop(release, role='server'):
    """只停止已验证的单角色；退出并确认原实例后才允许读取对应持久数据。"""
    require(role in ROLES, '未知服务角色')
    original = own_containers(inspect_containers()).get(role)
    if not original:
        return
    with compose_command(release) as command:
        run(command + ['stop', '--timeout', release['config']['STOP_SECONDS'], role])
    current = own_containers(inspect_containers()).get(role)
    require(current and current['Id'] == original['Id'] and not current['State']['Running'],
            role + ' 未确认原实例停止，拒绝继续')

def materialize_https_config(release):
    """把已验证的非秘密模板原子写到长期固定路径，不绑定会删除的临时目录。"""
    target = ROOT / 'Caddyfile'
    private_path(target)
    if target.is_file() and target.read_text() == release['caddyfile']:
        require(stat.S_IMODE(target.stat().st_mode) == 0o644, 'Caddyfile 需 644 以供容器 UID1000 只读')
        return
    temporary = ROOT / 'Caddyfile.tmp'
    private_path(temporary)
    with temporary.open('w') as output:
        output.write(release['caddyfile'])
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o644)
    temporary.replace(target)


def start(release, role='server', restore_https=False):
    """按角色推进记录并启动；业务尝试保留当前代理，显式空 TLS 灾备使用完整归档版本。"""
    require(role in ROLES, '未知服务角色')
    owned = own_containers(inspect_containers())
    if role == 'server':
        recorded = release
        proxy = owned.get('https')
        if proxy and not restore_https:
            current = load_release()
            require(proxy['Image'] == current['https_image_id'], '当前代理与发布记录不一致，拒绝启动业务')
            require((ROOT / 'Caddyfile').read_text() == current['caddyfile'], '当前代理配置文件与记录不一致')
            recorded = with_current_proxy(release, current)
        if restore_https:
            require(not proxy or not proxy['State']['Running'], 'TLS 灾备要求代理尚未运行或已停止')
        # 新业务可能已经迁移数据，因此启动前记录本次业务尝试；尚未操作的代理保持原版本。
        save_release(recorded)
    if role == 'https':
        server = owned.get('server')
        require(server and server['Image'] == release['image_id']
                and server['State']['Running'] and server['State'].get('Health', {}).get('Status') == 'healthy',
                'server 尚未 ready，拒绝启动 HTTPS')
        materialize_https_config(release)
    try:
        with compose_command(release) as command:
            run(command + ['up', '--no-build', '--pull', 'never', '--no-deps', '--wait',
                           '--wait-timeout', release['config']['WAIT_SECONDS'], role])
        own = own_containers(inspect_containers()).get(role)
        image_id = release['image_id' if role == 'server' else 'https_image_id']
        require(own and own['Image'] == image_id and own['State']['Running']
                and own['State'].get('Health', {}).get('Status') == 'healthy', role + ' 启动后镜像或健康不符')
        if role == 'https':
            save_release(release)
    except Exception:
        stop(release, role)
        if role == 'https':
            proxy = own_containers(inspect_containers()).get('https')
            original = owned.get('https')
            # 命令报错可能发生在替换之后；只在确认新实例及目标镜像时记录它，不把未替换的旧代理写成新版本。
            if (proxy and proxy['Image'] == release['https_image_id']
                    and (not original or proxy['Id'] != original['Id'])):
                save_release(release)
        raise

def data_budget(cfg):
    """业务与 TLS 一起计入完整快照预算；拒绝链接/特殊文件，满额不自动删除。"""
    total, count = 0, 0
    for directory in (ROOT / 'data', ROOT / 'https/data', ROOT / 'https/config'):
        private_path(directory)
        require(directory.is_dir(), '备份目录不完整')
        for path in [directory] + list(directory.rglob('*')):
            require(not path.is_symlink() and (path.is_file() or path.is_dir()), '快照含链接或特殊文件')
            total += path.stat().st_size
            count += 1
    estimate = total * 2 + count * 8192 + 1024 * 1024
    backups = ROOT / 'backups'
    backups.mkdir(mode=0o700, exist_ok=True)
    files = list(backups.iterdir())
    require(all(p.is_file() and not p.is_symlink() for p in files), '备份目录含非预期项目')
    require(len(files) < int(cfg['BACKUP_MAX_COUNT']), '备份数量到达上限，需先人工转存')
    require(sum(p.stat().st_size for p in files) + estimate <= int(cfg['BACKUP_MAX_BYTES']), '备份容量不足')
    require(shutil.disk_usage(ROOT).free >= estimate + int(cfg['MIN_FREE_DISK_BYTES']), '备份后磁盘余量不足')

def verify_data(directory):
    """仅在停止服务或恢复暂存目录内校验完整 SQLite 和非空主密钥。"""
    database = directory / 'happier-server-light.sqlite'
    master = directory / 'handy-master-secret.txt'
    require(database.is_file() and master.is_file() and master.stat().st_size > 0,
            '数据缺少 SQLite 或非空服务主密钥')
    with contextlib.closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as connection:
        connection.execute('PRAGMA query_only=ON')
        require(connection.execute('PRAGMA integrity_check').fetchall() == [('ok',)], 'SQLite 完整性检查失败')


def resume_backup_service(release, original, role='server'):
    """只恢复停止前同一 ID/镜像实例，直接 docker start，绝不以 up 重建替代实例。"""
    current = own_containers(inspect_containers()).get(role)
    image_id = release['image_id' if role == 'server' else 'https_image_id']
    require(current and current['Id'] == original['Id'] and current['Image'] == image_id,
            role + ' 原实例或镜像改变，拒绝自动恢复')
    if current['State']['Running']:
        return
    run(['docker', 'start', original['Id']])
    deadline = time.monotonic() + int(release['config']['WAIT_SECONDS'])
    while True:
        current = own_containers(inspect_containers()).get(role)
        require(current and current['Id'] == original['Id'] and current['Image'] == image_id
                and current['State']['Running'], role + ' 恢复时实例或运行状态改变')
        health = current['State'].get('Health', {}).get('Status')
        if health == 'healthy':
            return
        require(health != 'unhealthy' and time.monotonic() < deadline, role + ' 恢复后健康检查失败')
        time.sleep(1)


def resume_backup_roles(release, original, resume_server):
    """先恢复原代理续期，再按请求恢复业务；一方失败仍尝试恢复另一原实例。"""
    failures = []
    for role in ('https', 'server'):
        item = original.get(role)
        if not item or not item['State']['Running'] or (role == 'server' and not resume_server):
            continue
        try:
            resume_backup_service(release, item, role)
        except Exception as error:
            failures.append((role, error))
    if failures:
        raise RuntimeError('无法安全恢复原服务：' + ','.join(role for role, _ in failures)) from failures[0][1]

def backup(release, policy, resume):
    """短停两服务归档业务/TLS；升级快照也恢复原代理，异常只恢复原来运行的实例。"""
    validate_release(release)
    original = own_containers(inspect_containers())
    require('server' in original, '缺少业务容器，拒绝生成误标备份')
    for role, item in original.items():
        require(item['Image'] == release['image_id' if role == 'server' else 'https_image_id'],
                role + ' 容器与记录镜像不匹配')
    require((ROOT / 'Caddyfile').read_text() == release['caddyfile'], '持久 Caddyfile 与发布记录不一致')
    data_budget(policy)
    output = ROOT / 'backups' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.tar.age')
    partial = output.with_suffix('.partial')
    try:
        # 停入口后停业务；任一步实际已停止但命令/inspect报错，也必须进入原实例恢复分支。
        stop(release, 'https')
        stop(release)
        data_budget(policy)
        verify_data(ROOT / 'data')
        with partial.open('xb') as encrypted:
            process = subprocess.Popen(['age', '-r', policy['BACKUP_RECIPIENT']], stdin=subprocess.PIPE,
                                       stdout=encrypted, stderr=subprocess.DEVNULL)
            try:
                with tarfile.open(fileobj=process.stdin, mode='w|') as archive:
                    for name in ('data', 'https/data', 'https/config'):
                        archive.add(ROOT / name, arcname=name)
                    content = json.dumps(release).encode()
                    metadata = tarfile.TarInfo('release.json')
                    metadata.size, metadata.mode = len(content), 0o600
                    archive.addfile(metadata, io.BytesIO(content))
                process.stdin.close()
                require(process.wait() == 0, 'age 加密失败')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        partial.replace(output)
    except Exception as backup_error:
        partial.unlink(missing_ok=True)
        try:
            resume_backup_roles(release, original, resume_server=True)
        except Exception as recovery_error:
            raise RuntimeError('备份失败且无法安全恢复原服务') from recovery_error
        raise backup_error
    # 升级时只让 server 保持停止；代理继续续期和响应维护期的上游不可达。
    resume_backup_roles(release, original, resume_server=resume)
    print('加密备份：' + str(output))
    return output

def unpack(archive, directory, max_bytes):
    """只解出业务、两个 TLS 子目录及版本记录；完整校验发生在停止现有服务之前。"""
    seen, total = set(), 0
    for member in archive:
        path = PurePosixPath(member.name)
        allowed = (path.parts and (path.parts[0] == 'data'
                   or path.parts[:2] in (('https', 'data'), ('https', 'config'))
                   or (member.name == 'https' and member.isdir()) or member.name == 'release.json'))
        require(not path.is_absolute() and '..' not in path.parts and allowed, '备份含越界路径')
        require(path not in seen and (member.isfile() or member.isdir()), '备份含重复项、链接或特殊文件')
        seen.add(path)
        require(member.size >= 0, '归档成员大小无效')
        total += member.size + 8192
        require(total <= max_bytes, '备份展开超过容量预算')
        target = directory / str(path)
        if member.isdir():
            target.mkdir(mode=0o700, parents=True, exist_ok=True)
        else:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with target.open('xb') as out, archive.extractfile(member) as source:
                shutil.copyfileobj(source, out)
            os.chmod(target, 0o600)
    require(all((directory / name).is_dir() for name in ('data', 'https/data', 'https/config'))
            and (directory / 'release.json').is_file(), '备份缺少完整业务/TLS数据或版本记录')
    verify_data(directory / 'data')

def rollback(args, policy):
    """先完整认证备份；业务回滚保留当前 TLS/代理，显式灾备只接受空且静止的 TLS 目录。"""
    require(args.accept_data_loss, '回滚需显式 --accept-data-loss')
    identity = Path(args.identity)
    require(identity.is_file() and not identity.is_symlink()
            and stat.S_IMODE(identity.stat().st_mode) & 0o077 == 0, 'age 私钥需为受限普通文件')
    require(Path(args.archive).is_file(), '备份文件不存在')
    max_bytes = int(policy['BACKUP_MAX_BYTES'])
    require(shutil.disk_usage(ROOT).free >= max_bytes + int(policy['MIN_FREE_DISK_BYTES']),
            '恢复需为最大展开容量和保留数据预留磁盘余量')
    with tempfile.TemporaryDirectory(prefix='restore-', dir=ROOT) as temp:
        temp = Path(temp)
        process = subprocess.Popen(['age', '-d', '-i', str(identity), args.archive], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        try:
            with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
                unpack(archive, temp, max_bytes)
            # 消费密文尾部，不能以 tar 结束标记代替 age 认证成功。
            while process.stdout.read(65536):
                pass
            require(process.wait() == 0, 'age 解密/认证失败；未停止现有服务')
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait()
        release = json.loads((temp / 'release.json').read_text())
        validate_release(release)
        restore_https = getattr(args, 'restore_https_state', False)
        if restore_https:
            require(release['config']['PUBLIC_URL'] == policy['PUBLIC_URL'], '灾备 PUBLIC_URL 与当前入口不一致')
            for directory in (ROOT / 'https/data', ROOT / 'https/config'):
                private_path(directory)
                require(directory.is_dir() and not any(directory.iterdir()), '显式 TLS 灾备要求两个目录为空')
            proxy = own_containers(inspect_containers()).get('https')
            require(not proxy or not proxy['State']['Running'], 'TLS 灾备要求代理尚未运行或已停止')
        else:
            current = load_release()
            current_proxy = own_containers(inspect_containers()).get('https')
            require(not current_proxy or current_proxy['Image'] == current['https_image_id'],
                    '当前代理与发布记录不一致，拒绝业务回滚')
            require((ROOT / 'Caddyfile').read_text() == current['caddyfile'], '当前代理配置文件与记录不一致')
            require(release['config']['PUBLIC_URL'] == current['config']['PUBLIC_URL'],
                    '归档 PUBLIC_URL 与当前 HTTPS 入口不一致')
            release = with_current_proxy(release, current)
        validate_release(release)
        recorded = (release['image_id'], release['https_image_id'])
        preflight(release)
        require((release['image_id'], release['https_image_id']) == recorded, '归档/当前代理镜像与预装镜像不一致')
        stop(release)
        if restore_https:
            # 停止边界后先重查两个目录，再替换任何业务数据；不覆盖检查后出现的内容。
            require(all(not any((ROOT / name).iterdir()) for name in ('https/data', 'https/config')),
                    'TLS 目录不再为空，停止恢复')
        quarantine = ROOT / ('data-before-rollback-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        (ROOT / 'data').rename(quarantine)
        (temp / 'data').rename(ROOT / 'data')
        directories = [ROOT / 'data']
        if restore_https:
            # 不覆盖已有 TLS；停服边界后再次确认，任何意外内容都保留而不删除。
            for name in ('https/data', 'https/config'):
                target = ROOT / name
                require(not any(target.iterdir()), 'TLS 目录不再为空，停止恢复')
                target.rmdir()
                (temp / name).rename(target)
                directories.append(target)
        for directory in directories:
            for path in [directory] + list(directory.rglob('*')):
                os.chown(path, 1000, 1000)
        try:
            start(release, restore_https=restore_https)
            if restore_https:
                start(release, 'https')
        except Exception:
            stop(release)
            raise
        print('原业务数据保留于：' + str(quarantine))
        print('业务恢复完成；TLS签发/信任需另验。下次发布前同步 .env 中镜像及资源。')

def main():
    """唯一维护入口；使用同一独占锁管理两角色，外部容器变化时停止两角色并报告。"""
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'preflight', 'deploy', 'backup', 'rollback'])
    parser.add_argument('--env', default=str(ROOT / '.env'))
    parser.add_argument('--archive')
    parser.add_argument('--identity')
    parser.add_argument('--accept-data-loss', action='store_true')
    parser.add_argument('--restore-https-state', action='store_true',
                        help='仅灾备：TLS目录必须为空且代理未运行；恢复归档代理和TLS状态')
    args = parser.parse_args()
    require(not args.restore_https_state or args.action == 'rollback', 'TLS 灾备选项仅适用于 rollback')
    cfg = parse_env(Path(args.env).read_text())
    release = {'schema': 2, 'config': cfg, 'compose': (HERE / 'compose.yaml').read_text(),
               'caddyfile': (HERE / 'Caddyfile').read_text()}
    validate_release(release)
    if args.action == 'check':
        print('静态配置通过；未连接 Docker daemon，也未验证 Caddy 运行或证书。')
        return
    require(Path(args.env) == ROOT / '.env' and HERE == ROOT, '实际操作只允许已安装的 /opt/codex-top 包')
    host_guard()
    before = preflight(release) if args.action in ('preflight', 'deploy') else inspect_containers()
    own_containers(before)
    if args.action == 'preflight':
        print('主机预检通过；受信任IP证书、续期、WebSocket和手机仍需实际验收。')
        return
    lock_path = ROOT / '.operation.lock'
    private_path(lock_path)
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = inspect_containers()
        state = ROOT / 'state'
        state.mkdir(mode=0o700, exist_ok=True)
        before_path, after_path = state / 'neighbors-before.json', state / 'neighbors-after.json'
        private_path(before_path)
        private_path(after_path)
        before_path.write_text(json.dumps(neighbors(before)))
        try:
            if args.action == 'backup':
                backup(load_release(), cfg, resume=True)
            elif args.action == 'rollback':
                require(args.archive and args.identity, '回滚必须指定 --archive 和 --identity')
                rollback(args, cfg)
            else:
                owned = own_containers(before)
                if owned or any((ROOT / 'data').iterdir()):
                    backup(load_release(), cfg, resume=False)
                try:
                    start(release)
                    start(release, 'https')
                except Exception:
                    stop(release)
                    raise
                print('两服务进程健康；不代表公网IP证书、续期、WebSocket或手机业务通过。')
        finally:
            after = neighbors(inspect_containers())
            after_path.write_text(json.dumps(after))
            if neighbors(before) != after:
                for role in ('https', 'server'):
                    stop(release, role)
                raise RuntimeError('其他容器状态与操作前不同，已停止 Codex Top；请人工核对 PVTC 基线')

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, TypeError, tarfile.TarError, sqlite3.DatabaseError) as error:
        print('停止：' + str(error), file=sys.stderr)
        sys.exit(1)
