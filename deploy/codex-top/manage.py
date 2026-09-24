#!/usr/bin/env python3
"""Codex Top 专用部署入口；仅 check 可在非 Linux 主机运行。"""

import argparse
import contextlib
import datetime
from decimal import Decimal
import fcntl
import io
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
from urllib.parse import urlsplit

ROOT = Path('/opt/codex-top')
HERE = Path(__file__).resolve().parent
PROJECT = 'codex-top'
NETWORK = 'codex-top-private'
PREFIX = 'CODEX_TOP_'
FIELDS = ('ROOT IMAGE PORT PUBLIC_URL CPUS MEMORY PIDS LOG_SIZE LOG_FILES '
          'MIN_FREE_MEMORY_BYTES MIN_FREE_DISK_BYTES BACKUP_MAX_BYTES BACKUP_MAX_COUNT '
          'BACKUP_RECIPIENT WAIT_SECONDS STOP_SECONDS').split()


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
    """解析无秘密的显式配置；拒绝 shell 展开、重复项、未知项和空值。"""
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        require(sep and key in [PREFIX + k for k in FIELDS] and key not in values,
                '配置存在未知项或重复项')
        require(value and not any(c.isspace() or c in '\"\'`$\\#' for c in value),
                '配置需填写无引号、无插值的单个值：' + key)
        values[key] = value
    require(set(values) == {PREFIX + k for k in FIELDS}, '配置必填项不完整')
    cfg = {k: values[PREFIX + k] for k in FIELDS}
    require(cfg['ROOT'] == str(ROOT), '数据根目录必须为 /opt/codex-top')
    require(re.fullmatch(r'(?:sha256:|[a-zA-Z0-9._:/-]+@sha256:)[0-9a-f]{64}', cfg['IMAGE']),
            '镜像必须使用已预装的 sha256 ID 或仓库摘要，不能使用浮动标签')
    for key in ('PORT', 'PIDS', 'LOG_FILES', 'MIN_FREE_MEMORY_BYTES', 'MIN_FREE_DISK_BYTES',
                'BACKUP_MAX_BYTES', 'BACKUP_MAX_COUNT', 'WAIT_SECONDS', 'STOP_SECONDS'):
        require(re.fullmatch(r'[1-9][0-9]*', cfg[key]), key + ' 必须为正整数')
    require(1024 <= int(cfg['PORT']) <= 65535, '宿主端口需在 1024..65535 内')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', cfg['CPUS']) and float(cfg['CPUS']) > 0,
            'CPU 上限必须大于 0')
    for key in ('MEMORY', 'LOG_SIZE'):
        require(re.fullmatch(r'[1-9][0-9]*[kKmMgG]', cfg[key]), key + ' 需为整数加 k/m/g')
    origin = urlsplit(cfg['PUBLIC_URL'])
    require(origin.scheme == 'https' and origin.hostname and not origin.username
            and not origin.password and not origin.path and not origin.query and not origin.fragment,
            'PUBLIC_URL 必须是 HTTPS origin，无账号、路径和末尾斜杠')
    require(re.fullmatch(r'age1[0-9a-z]+', cfg['BACKUP_RECIPIENT']), '需填写 age 公钥 recipient')
    return cfg


def env_text(cfg):
    """把已验证配置写成确定顺序，不存放账号、密码或服务主密钥。"""
    return ''.join(PREFIX + k + '=' + cfg[k] + '\n' for k in FIELDS)


@contextlib.contextmanager
def compose_command(release):
    """为当前命令生成私有配置快照，防止调用期间 .env 改写影响后续步骤。"""
    with tempfile.TemporaryDirectory(prefix='codex-top-config-') as directory:
        directory = Path(directory)
        (directory / '.env').write_text(env_text(release['config']))
        (directory / 'compose.yaml').write_text(release['compose'])
        yield compose_cli() + ['--project-name', PROJECT, '--env-file', directory / '.env',
                               '-f', directory / 'compose.yaml']


def validate_release(release):
    """核对渲染产物及配置中的精确配额，拒绝服务、权限或资源预算偏离。"""
    cfg = parse_env(env_text(release['config']))
    with compose_command(release) as command:
        model = json.loads(run(command + ['config', '--format', 'json']), parse_float=Decimal)
    require(set(model) <= {'services', 'networks', 'name'}
            and set(model['services']) == {'server'} and model['name'] == PROJECT,
            'Compose 只能含 codex-top 的单个 server')
    server = model['services']['server']
    allowed = {'image', 'user', 'init', 'restart', 'ports', 'environment', 'volumes', 'networks',
               'cpus', 'mem_limit', 'memswap_limit', 'pids_limit', 'security_opt', 'cap_drop',
               'logging', 'healthcheck', 'command', 'entrypoint'}
    require(not (set(server) - allowed), 'Compose 含不允许的服务属性')
    require(server['image'] == cfg['IMAGE'] and server['user'] == '1000:1000'
            and not server.get('command') and not server.get('entrypoint'), '镜像或非 root 入口不符')
    ports, mounts = server['ports'], server['volumes']
    require(len(ports) == 1 and ports[0]['host_ip'] == '127.0.0.1'
            and str(ports[0]['published']) == cfg['PORT'] and ports[0]['target'] == 3005
            and ports[0].get('protocol', 'tcp') == 'tcp', '只允许指定回环端口')
    require(len(mounts) == 1 and mounts[0]['type'] == 'bind'
            and mounts[0]['source'] == str(ROOT / 'data') and mounts[0]['target'] == '/data',
            '只允许独立 data 挂载')
    require(set(server['networks']) == {'private'} and set(model['networks']) == {'private'}
            and model['networks']['private']['name'] == NETWORK
            and model['networks']['private'].get('driver') == 'bridge'
            and not model['networks']['private'].get('ipam')
            and not model['networks']['private'].get('external'), '必须使用独立网络')
    require(server['cap_drop'] == ['ALL'] and server['security_opt'] == ['no-new-privileges:true'],
            '权限约束缺失')
    # Compose 将 k/m/g 规范化为二进制字节数；CPU 用十进制比较，避免浮点容差放宽预算。
    memory_bytes = int(cfg['MEMORY'][:-1]) * {'k': 1024, 'm': 1024 ** 2, 'g': 1024 ** 3}[cfg['MEMORY'][-1].lower()]
    require(Decimal(str(server['cpus'])) == Decimal(cfg['CPUS'])
            and server['pids_limit'] == int(cfg['PIDS'])
            and Decimal(str(server['mem_limit'])) == memory_bytes
            and Decimal(str(server['memswap_limit'])) == memory_bytes,
            '渲染后的 CPU、内存/交换或 PIDs 配额与已审配置不一致')
    require(server['logging']['driver'] == 'json-file'
            and server['logging']['options'] == {'max-file': cfg['LOG_FILES'], 'max-size': cfg['LOG_SIZE']},
            '日志上限必须明确')
    env = server['environment']
    require(env == {'NODE_ENV': 'production', 'PORT': '3005', 'PUBLIC_URL': cfg['PUBLIC_URL'],
                    'HAPPIER_SERVER_FLAVOR': 'light', 'HAPPIER_DB_PROVIDER': 'sqlite',
                    'HAPPIER_SERVER_LIGHT_DATA_DIR': '/data', 'HAPPIER_SQLITE_AUTO_MIGRATE': '1',
                    'RUN_MIGRATIONS': '1', 'HAPPIER_FEATURE_AUTH_LOGIN__PASSWORD_ENABLED': 'true',
                    'HAPPIER_FEATURE_AUTH_LOGIN__KEY_CHALLENGE_ENABLED': 'true',
                    'AUTH_ANONYMOUS_SIGNUP_ENABLED': 'false', 'AUTH_SIGNUP_PROVIDERS': '',
                    'AUTH_REQUIRED_LOGIN_PROVIDERS': ''},
            '服务模式、注册策略或主密钥持久化不符')
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


def own_container(containers):
    """核对项目名没有被其他服务占用，且既有实例仅挂载本项目数据。"""
    own = [c for c in containers if c['Config'].get('Labels', {}).get('com.docker.compose.project') == PROJECT]
    require(len(own) <= 1, '项目名已被多个容器使用，需人工核对')
    for item in own:
        require(item['Config']['Labels'].get('com.docker.compose.service') == 'server', '项目名冲突')
        mounts = item['Mounts']
        require(len(mounts) == 1 and mounts[0]['Source'] == str(ROOT / 'data')
                and mounts[0]['Destination'] == '/data', '既有容器数据挂载不属于本部署')
        require(set(item['NetworkSettings']['Networks']) <= {NETWORK}, '既有容器连接了其他网络')
    return own[0] if own else None


def neighbors(containers):
    """仅提取其他容器的状态用于前后比较，不记录环境、名称或业务内容。"""
    return {c['Id']: {'image': c['Image'], 'running': c['State']['Running'],
                     'started': c['State']['StartedAt'], 'restarts': c['RestartCount'],
                     'health': c['State'].get('Health', {}).get('Status'),
                     'ports': c['HostConfig'].get('PortBindings')}
            for c in containers if c['Config'].get('Labels', {}).get('com.docker.compose.project') != PROJECT}


def host_guard():
    """检查固定 Linux 安装位置和本地 Docker；恢复不依赖失败版本镜像仍然存在。"""
    require(platform.system() == 'Linux' and os.geteuid() == 0, '实际操作需在目标 Linux 上通过 sudo 执行')
    require(not os.environ.get('DOCKER_HOST') and not os.environ.get('DOCKER_CONTEXT'),
            '拒绝环境指定的 Docker 远端；在目标主机运行')
    context = json.loads(run(['docker', 'context', 'inspect']))[0]
    require(context['Endpoints']['docker']['Host'] == 'unix:///var/run/docker.sock', '只允许本机系统 Docker')
    for path in (ROOT, ROOT / '.env', ROOT / 'data', ROOT / 'backups', ROOT / 'state'):
        private_path(path)
    require(ROOT.is_dir() and ROOT.stat().st_uid == 0 and stat.S_IMODE(ROOT.stat().st_mode) == 0o700,
            '根目录需 root 持有且权限 700')
    require((ROOT / '.env').stat().st_uid == 0 and stat.S_IMODE((ROOT / '.env').stat().st_mode) == 0o600,
            '.env 需 root 持有且权限 600')
    require((ROOT / 'data').is_dir() and (ROOT / 'data').stat().st_uid == 1000
            and stat.S_IMODE((ROOT / 'data').stat().st_mode) == 0o700, 'data 需 UID 1000 持有且权限 700')
    require(shutil.which('age'), '目标主机需预装 age；本工具不自动安装软件')


def preflight(release):
    """只读检查预装镜像、余量和独立端口；不拉取、构建或变更主机。"""
    cfg = release['config']
    # 加密空输入只验证公钥可用，不创建备份，也不输出密文或私钥。
    run(['age', '-a', '-r', cfg['BACKUP_RECIPIENT']], input_text='')
    image = json.loads(run(['docker', 'image', 'inspect', cfg['IMAGE']]))[0]
    release['image_id'] = image['Id']
    require(image['Config']['User'] in ('node', '1000', '1000:1000'), '镜像不是预期非 root server target')
    require(image['Config']['Cmd'] == ['run-server'], '镜像入口不是根 Dockerfile 的 server target')
    origin = urlsplit(cfg['PUBLIC_URL']).hostname
    require(not origin.endswith(('.invalid', '.example')) and origin != 'localhost', '正式环境需确认独立 HTTPS 域名')
    memory = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
    available = int(memory['MemAvailable'].split()[0]) * 1024
    model = validate_release(release)
    limit = int(model['services']['server']['mem_limit'])
    require(available >= limit + int(cfg['MIN_FREE_MEMORY_BYTES']), '可用内存不足以保留指定余量')
    require(float(cfg['CPUS']) <= (os.cpu_count() or 1), 'CPU 配额超过本机总 CPU 数')
    require(shutil.disk_usage(ROOT).free >= int(cfg['MIN_FREE_DISK_BYTES']), '磁盘余量不足')
    print('主机余量：可用内存 %d 字节；可用磁盘 %d 字节；CPU %d；1 分钟负载 %.2f。'
          % (available, shutil.disk_usage(ROOT).free, os.cpu_count() or 1, os.getloadavg()[0]))
    containers = inspect_containers()
    own = own_container(containers)
    for item in containers:
        for bindings in (item['HostConfig'].get('PortBindings') or {}).values():
            for binding in bindings or []:
                require(binding['HostPort'] != cfg['PORT'] or item is own, '宿主端口已被其他容器占用')
    own_binding = (own or {}).get('HostConfig', {}).get('PortBindings') or {}
    using_port = any(b.get('HostPort') == cfg['PORT'] for rows in own_binding.values() for b in (rows or []))
    if not (own and own['State']['Running'] and using_port):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', int(cfg['PORT'])))
    network_ids = run(['docker', 'network', 'ls', '--filter', 'name=^' + NETWORK + '$', '-q']).split()
    for network_id in network_ids:
        network = json.loads(run(['docker', 'network', 'inspect', network_id]))[0]
        require((network.get('Labels') or {}).get('com.docker.compose.project') == PROJECT
                and set(network.get('Containers') or {}) <= ({own['Id']} if own else set()),
                '专用网络已被其他容器或项目占用')
    return containers


def save_release(release):
    """原子记录当前安装尝试的镜像与配置；此记录不表示功能验收通过。"""
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


def stop(release):
    """仅停止本项目 server，并确认容器已经退出再读写 SQLite 数据。"""
    own_container(inspect_containers())
    with compose_command(release) as command:
        run(command + ['stop', '--timeout', release['config']['STOP_SECONDS'], 'server'])
    own = own_container(inspect_containers())
    require(not own or not own['State']['Running'], 'server 尚未停止，拒绝继续')


def start(release):
    """仅使用预装镜像启动单服务并等待健康；失败保持停止，禁止自动退旧镜像。"""
    own_container(inspect_containers())
    save_release(release)
    try:
        with compose_command(release) as command:
            run(command + ['up', '--no-build', '--pull', 'never', '--no-deps', '--wait',
                           '--wait-timeout', release['config']['WAIT_SECONDS'], 'server'])
        own = own_container(inspect_containers())
        require(own and own['Image'] == release['image_id']
                and own['State'].get('Health', {}).get('Status') == 'healthy', '启动后镜像或健康不符')
    except Exception:
        stop(release)
        raise


def data_budget(cfg):
    """保守估算完整快照空间，拒绝链接和特殊文件；绝不自动删除旧备份。"""
    total, count = 0, 0
    for path in [ROOT / 'data'] + list((ROOT / 'data').rglob('*')):
        require(not path.is_symlink() and (path.is_file() or path.is_dir()), 'data 含链接或特殊文件')
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


def resume_backup_service(release, original):
    """重查归属、原容器 ID/镜像及运行状态；只恢复同一已停止实例，未知状态拒绝操作。"""
    current = own_container(inspect_containers())
    require(current and current['Id'] == original['Id'] and current['Image'] == release['image_id'],
            '原备份容器已缺失或身份/镜像改变，拒绝自动恢复')
    if not current['State']['Running']:
        start(release)


def backup(release, policy, resume):
    """停止和归档均纳入失败恢复；重新核实原实例后才恢复，禁止误启替代容器。"""
    own = own_container(inspect_containers())
    require(own and own['Image'] == release['image_id'], '容器与已记录镜像不匹配，拒绝生成误标备份')
    was_running = own['State']['Running']
    data_budget(policy)
    output = ROOT / 'backups' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.tar.age')
    partial = output.with_suffix('.partial')
    try:
        # stop 内部可能已成功停止，但在后续 inspect 失败；也必须进入恢复分支。
        stop(release)
        data_budget(policy)
        verify_data(ROOT / 'data')
        with partial.open('xb') as encrypted:
            process = subprocess.Popen(['age', '-r', policy['BACKUP_RECIPIENT']], stdin=subprocess.PIPE,
                                       stdout=encrypted, stderr=subprocess.DEVNULL)
            try:
                with tarfile.open(fileobj=process.stdin, mode='w|') as archive:
                    archive.add(ROOT / 'data', arcname='data')
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
        if was_running:
            try:
                resume_backup_service(release, own)
            except Exception as recovery_error:
                raise RuntimeError('备份失败且无法安全恢复原服务，请人工核对：' + str(recovery_error)) from backup_error
        raise
    if resume and was_running:
        resume_backup_service(release, own)
    print('加密备份：' + str(output))
    return output


def unpack(archive, directory, max_bytes):
    """逐项恢复到新目录；拒绝逃逸路径、链接、特殊文件、重复项及超额展开。"""
    seen, total = set(), 0
    for member in archive:
        path = PurePosixPath(member.name)
        require(not path.is_absolute() and '..' not in path.parts and path.parts
                and (path.parts[0] == 'data' or member.name == 'release.json'), '备份含越界路径')
        require(path not in seen and (member.isfile() or member.isdir()), '备份含重复项、链接或特殊文件')
        seen.add(path)
        # 元数据也占用磁盘与内存，避免大量空文件绕过展开预算。
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
    require((directory / 'data').is_dir() and (directory / 'release.json').is_file(), '备份缺少完整数据或版本记录')
    verify_data(directory / 'data')


def rollback(args, policy):
    """先解密并验证完整备份，再隔离当前数据并恢复；新增数据不自动合并或删除。"""
    require(args.accept_data_loss, '回滚会退回备份时间点，需显式 --accept-data-loss')
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
            # 完整消费密文，确保 age 尾部认证错误不能被 tar 的结束标记掩盖。
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
        recorded_image = release['image_id']
        preflight(release)
        require(release['image_id'] == recorded_image, '备份镜像与预装镜像不一致')
        stop(release)
        quarantine = ROOT / ('data-before-rollback-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        (ROOT / 'data').rename(quarantine)
        (temp / 'data').rename(ROOT / 'data')
        for path in [ROOT / 'data'] + list((ROOT / 'data').rglob('*')):
            os.chown(path, 1000, 1000)
        start(release)
        print('原数据保留于：' + str(quarantine))
        print('回滚使用备份配置；下次发布前需人工同步 .env 中的目标镜像和资源。')


def main():
    """统一命令入口；实际操作加独占锁，始终对照其他容器并只停止本服务。"""
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'preflight', 'deploy', 'backup', 'rollback'])
    parser.add_argument('--env', default=str(ROOT / '.env'))
    parser.add_argument('--archive')
    parser.add_argument('--identity')
    parser.add_argument('--accept-data-loss', action='store_true')
    args = parser.parse_args()
    cfg = parse_env(Path(args.env).read_text())
    release = {'config': cfg, 'compose': (HERE / 'compose.yaml').read_text()}
    validate_release(release)
    if args.action == 'check':
        print('静态配置通过；未连接 Docker daemon。')
        return
    require(Path(args.env) == ROOT / '.env' and HERE == ROOT, '实际操作只允许已安装的 /opt/codex-top 包')
    host_guard()
    # 备份和回滚读取已安装/归档版本；不要求待发布的新镜像仍然可用。
    before = preflight(release) if args.action in ('preflight', 'deploy') else inspect_containers()
    own_container(before)
    if args.action == 'preflight':
        print('主机预检通过；HTTPS、账号、推送和业务闭环仍需实际验收。')
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
                own = own_container(before)
                if own or any((ROOT / 'data').iterdir()):
                    backup(load_release(), cfg, resume=False)
                start(release)
                print('server 健康检查通过；不代表手机业务或公网验收完成。')
        finally:
            after = neighbors(inspect_containers())
            after_path.write_text(json.dumps(after))
            if neighbors(before) != after:
                stop(release)
                raise RuntimeError('其他容器状态与操作前不同，已停止 Codex Top；请人工核对 PVTC 基线')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print('停止：' + str(error), file=sys.stderr)
        sys.exit(1)
