"""只在合成目录运行；替代 Docker/age/宿主系统边界，不替代维护内部逻辑。"""

import copy
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import yaml
import manage as m

SOURCE = Path(__file__).resolve().parent


def sample_release():
    """从仓库实际模板创建合成快照；地址不代表真实部署或可达性。"""
    cfg = {'ROOT': str(m.ROOT), 'IMAGE': 'sha256:' + '1' * 64, 'PORT': '43117',
           'PUBLIC_URL': 'https://93.184.216.34', 'CPUS': '0.5', 'MEMORY': '512m',
           'PIDS': '128', 'LOG_SIZE': '1m', 'LOG_FILES': '2', 'MIN_FREE_MEMORY_BYTES': '1',
           'MIN_FREE_DISK_BYTES': '1', 'BACKUP_MAX_BYTES': '20000000', 'BACKUP_MAX_COUNT': '3',
           'BACKUP_RECIPIENT': 'age1syntheticrecipient', 'WAIT_SECONDS': '1', 'STOP_SECONDS': '5',
           'HTTPS_IMAGE': 'sha256:' + '2' * 64, 'HTTPS_CPUS': '0.25', 'HTTPS_MEMORY': '128m',
           'HTTPS_PIDS': '64', 'HTTPS_LOG_SIZE': '1m', 'HTTPS_LOG_FILES': '2'}
    caddyfile = SOURCE / 'Caddyfile'
    return {'schema': 2, 'config': cfg,
            'compose': (SOURCE / 'compose.yaml').read_text().replace('/opt/codex-top', str(m.ROOT)),
            'caddyfile': caddyfile.read_text() if caddyfile.exists() else '',
            'image_id': cfg['IMAGE'], 'https_image_id': cfg['HTTPS_IMAGE']}


def byte_size(value):
    """模拟 Compose 命令的单位规范化，不替代生产配额比较逻辑。"""
    if isinstance(value, int) or str(value).isdigit():
        return int(value)
    return int(value[:-1]) * {'k': 1024, 'm': 1024 ** 2, 'g': 1024 ** 3}[value[-1].lower()]


def render_fixture(command):
    """用现有 PyYAML读取实际文件，仅模拟外部 Compose config JSON 输出，非真实 Compose 验收。"""
    env = dict(line.split('=', 1) for line in Path(command[command.index('--env-file') + 1]).read_text().splitlines())
    text = Path(command[command.index('-f') + 1]).read_text()
    # 环境名可含数字，尤其是配置指纹的 SHA256；不要把未展开值误当真实 Compose 结果。
    text = re.sub(r'\$\{([A-Z_][A-Z0-9_]*)(?::\?[^}]*)?\}', lambda match: env[match[1]], text)
    model = yaml.safe_load(text)
    for service in model['services'].values():
        if isinstance(service.get('networks'), list):
            service['networks'] = {name: None for name in service['networks']}
        ports = []
        for port in service.get('ports', []):
            if isinstance(port, dict):
                ports.append(port)
                continue
            address, published, target = port.split(':')
            number, _, protocol = target.partition('/')
            ports.append({'host_ip': address, 'published': published, 'target': int(number),
                          'protocol': protocol or 'tcp', 'mode': 'ingress'})
        service['ports'] = ports
        mounts = []
        for mount in service.get('volumes', []):
            if isinstance(mount, dict):
                mounts.append(mount)
                continue
            source, target, *options = mount.split(':')
            mounts.append({'type': 'bind', 'source': source, 'target': target,
                           'read_only': 'ro' in options})
        service['volumes'] = mounts
        for field in ('mem_limit', 'memswap_limit'):
            service[field] = byte_size(service[field])
        service['cpus'] = float(service['cpus'])
        service['pids_limit'] = int(service['pids_limit'])
        service['logging']['options'] = {key: str(value) for key, value in service['logging']['options'].items()}
    return model


def populate(directory, marker):
    """创建真实 SQLite、合成主密钥与上传文件。"""
    directory.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(directory / 'happier-server-light.sqlite') as database:
        database.execute('CREATE TABLE sample(value TEXT)')
        database.execute('INSERT INTO sample VALUES (?)', (marker,))
    (directory / 'handy-master-secret.txt').write_text('synthetic-secret-' + marker)
    (directory / 'files').mkdir()
    (directory / 'files/upload.txt').write_text(marker)


def container_fixture(role, release, running=True):
    """构造该角色的外部 inspect 数据，包含实例身份和真实固定挂载边界。"""
    cfg = release['config']
    if role == 'server':
        mounts = [(m.ROOT / 'data', '/data', True)]
        port, target = cfg['PORT'], '3005/tcp'
    else:
        mounts = [(m.ROOT / 'Caddyfile', '/etc/caddy/Caddyfile', False),
                  (m.ROOT / 'https/data', '/data', True), (m.ROOT / 'https/config', '/config', True)]
        port, target = '443', '443/tcp'
    return {'Id': 'synthetic-' + role,
            'Image': release['image_id' if role == 'server' else 'https_image_id'],
            'Config': {'User': '1000:1000', 'Labels': {'com.docker.compose.project': m.PROJECT, 'com.docker.compose.service': role}},
            'Mounts': [{'Type': 'bind', 'Source': str(source), 'Destination': dest, 'RW': rw}
                       for source, dest, rw in mounts],
            'NetworkSettings': {'Networks': {m.NETWORK: {}}},
            'HostConfig': {'PortBindings': {target: [{'HostIp': '127.0.0.1' if role == 'server' else '0.0.0.0',
                                                      'HostPort': port}]}},
            'RestartCount': 0,
            'State': {'Running': running, 'StartedAt': 'synthetic-start', 'Health': {'Status': 'healthy'}}}


class ExternalCommands:
    """只模拟外部命令；生产解析、归属、停启、归档和恢复函数全部真实调用。"""

    def __init__(self, release):
        """保存独立容器视图及命令记录，默认两服务已运行。"""
        self.release = release
        self.containers = {role: container_fixture(role, release) for role in ('server', 'https')}
        self.commands = []
        self.after_stop = None
        self.fail_up = None
        self.fail_up_before = None
        self.fail_inspects = 0
        self.foreign_network = False

    def __call__(self, args, input_text=None):
        """响应白名单命令；任何新增或意外外部操作都明确失败，不回落真实 Docker。"""
        args = list(map(str, args))
        self.commands.append(args)
        if args[:3] == ['docker', 'compose', 'version']:
            return 'synthetic-compose'
        if args[:2] == ['docker', 'compose']:
            model = render_fixture(args)
            if args[-3:] == ['config', '--format', 'json']:
                return json.dumps(model)
            role = args[-1]
            if 'stop' in args:
                if role in self.containers:
                    self.containers[role]['State']['Running'] = False
                if self.after_stop:
                    callback, self.after_stop = self.after_stop, None
                    callback(role)
                return ''
            if 'up' in args:
                if self.fail_up_before == role:
                    raise RuntimeError('synthetic-up-before-failure')
                current = self.containers.get(role)
                image = model['services'][role]['image']
                updated = copy.deepcopy(self.release)
                updated['image_id' if role == 'server' else 'https_image_id'] = image
                item = container_fixture(role, updated)
                if current and current['Image'] != image:
                    item['Id'] = current['Id'] + '-new'
                elif current:
                    item['Id'] = current['Id']
                self.containers[role] = item
                if self.fail_up == role:
                    raise RuntimeError('synthetic-up-failure')
                return ''
            raise AssertionError('Unexpected compose action')
        if args[:3] == ['docker', 'ps', '-aq']:
            return '\n'.join(item['Id'] for item in self.containers.values())
        if args[:2] == ['docker', 'inspect']:
            if self.fail_inspects:
                self.fail_inspects -= 1
                raise RuntimeError('synthetic-inspect-failure')
            return json.dumps([item for item in self.containers.values() if item['Id'] in args[2:]])
        if args[:2] == ['docker', 'start']:
            item = next(item for item in self.containers.values() if item['Id'] == args[-1])
            item['State']['Running'] = True
            return item['Id']
        if args[:3] == ['docker', 'image', 'inspect']:
            server = args[-1] not in ('sha256:' + '2' * 64, 'sha256:' + '4' * 64)
            return json.dumps([{'Id': args[-1], 'Config': {'User': 'node' if server else '',
                'Cmd': ['run-server'] if server else ['caddy', 'run', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile']}}])
        if args[:3] == ['docker', 'network', 'ls']:
            return 'synthetic-network'
        if args[:3] == ['docker', 'network', 'inspect']:
            return json.dumps([{'Labels': {'com.docker.compose.project': 'pvtc' if self.foreign_network else m.PROJECT},
                                'Containers': {item['Id']: {} for item in self.containers.values()}}])
        if args[:2] == ['age', '-a']:
            return ''
        raise AssertionError('Unexpected external command: ' + repr(args[:3]))


class BoundaryTests(unittest.TestCase):
    """通用合成文件与外部边界，不连接 Docker，也不替代维护内部函数。"""

    def setUp(self):
        """每项使用独立目录，外部 age 用明确的非加密管道替代。"""
        self.temp = tempfile.TemporaryDirectory(prefix='codex-top-https-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(patch.stopall)
        patch.object(m, 'ROOT', self.root).start()
        self.release = sample_release()
        self.external = ExternalCommands(self.release)
        patch.object(m, 'run', side_effect=self.external).start()
        populate(self.root / 'data', 'current')
        for name in ('data', 'config'):
            directory = self.root / 'https' / name
            directory.mkdir(parents=True)
            (directory / 'synthetic-state').write_text('current-' + name)
        (self.root / 'Caddyfile').write_text(self.release['caddyfile'])
        self.real_popen = subprocess.Popen
        self.age_exit = 0
        patch.object(m.subprocess, 'Popen', side_effect=self.age_process).start()
        # UID 1000 属于目标 Linux；本机只替代 chown 系统调用，真实目录/文件仍完整替换。
        patch.object(m.os, 'chown').start()

    def age_process(self, args, **kwargs):
        """消费/输出真实归档字节；显式不加密，可注入尾部认证失败。"""
        if args[1] == '-d':
            program = 'import pathlib,sys; sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes()); sys.exit(int(sys.argv[2]))'
            return self.real_popen([sys.executable, '-c', program, args[-1], str(self.age_exit)], **kwargs)
        program = 'import sys,shutil; shutil.copyfileobj(sys.stdin.buffer,sys.stdout.buffer); sys.exit(int(sys.argv[1]))'
        return self.real_popen([sys.executable, '-c', program, str(self.age_exit)], **kwargs)

    def save_current(self):
        """用真实发布记录保存函数建立回滚当前版本，不替代内部逻辑。"""
        m.save_release(self.release)

    def rollback_args(self, archive, restore_https_state=False):
        """生成真实回滚参数及私有合成 age 私钥。"""
        identity = self.root / 'synthetic-key'
        identity.write_text('synthetic')
        identity.chmod(0o600)
        return m.argparse.Namespace(archive=str(archive), identity=str(identity), accept_data_loss=True,
                                   restore_https_state=restore_https_state)

    def make_archive(self, marker='old', origin=None):
        """生成含旧业务数据和旧 TLS 状态的真实 tar，供解密边界传送。"""
        directory = self.root / ('snapshot-' + marker)
        populate(directory / 'data', marker)
        for name in ('data', 'config'):
            child = directory / 'https' / name
            child.mkdir(parents=True)
            (child / 'synthetic-state').write_text(marker + '-' + name)
        release = copy.deepcopy(self.release)
        release['config']['IMAGE'] = release['image_id'] = 'sha256:' + '3' * 64
        release['config']['HTTPS_IMAGE'] = release['https_image_id'] = 'sha256:' + '4' * 64
        if origin:
            release['config']['PUBLIC_URL'] = origin
        target = self.root / (marker + '.tar.age')
        with tarfile.open(target, 'w') as archive:
            archive.add(directory / 'data', arcname='data')
            archive.add(directory / 'https', arcname='https')
            content = json.dumps(release).encode()
            member = tarfile.TarInfo('release.json')
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
        return target

    def host_boundaries(self):
        """仅替代目标 Linux 的内存文件和端口探测，配置文件读取保持真实。"""
        original = Path.read_text

        def read_text(path, *args, **kwargs):
            """只为 /proc/meminfo 提供合成资源余量，不遮蔽其他文件。"""
            if str(path) == '/proc/meminfo':
                return 'MemAvailable: 1000000 kB\n'
            return original(path, *args, **kwargs)
        patch.object(Path, 'read_text', read_text).start()
        patch.object(m.socket, 'socket').start()


class StaticConfigTests(BoundaryTests):
    """验证实际模板经过外部渲染边界后的双角色契约。"""

    def test_two_roles_and_single_origin(self):
        """仅允许 server/https，IP 必须由唯一 PUBLIC_URL 派生。"""
        model = m.validate_release(self.release)
        self.assertEqual(set(model['services']), {'server', 'https'})
        self.assertEqual(model['services']['https']['environment']['PUBLIC_IP'], '93.184.216.34')
        self.assertEqual(model['services']['https']['ports'][0]['target'], 443)
        self.assertEqual(model['services']['server']['ports'][0]['host_ip'], '127.0.0.1')

    def test_invalid_input_and_duplicate_ip(self):
        """拒绝空值、标签镜像、域名、额外 IP、私密字段和 shell 展开。"""
        valid = m.env_text(self.release['config'])
        for text in (valid.replace('CODEX_TOP_PIDS=128', 'CODEX_TOP_PIDS='),
                     valid.replace('sha256:' + '2' * 64, 'caddy:latest'),
                     valid.replace('93.184.216.34', 'example.com'), valid + 'CODEX_TOP_PUBLIC_IP=1.2.3.4\n',
                     valid + 'HANDY_MASTER_SECRET=secret\n', valid.replace('512m', '$(anything)'),
                     (SOURCE / '.env.example').read_text()):
            with self.subTest(text=text[:30]), self.assertRaises((RuntimeError, ValueError)):
                m.parse_env(text)

    def test_proxy_scope_and_server_guards(self):
        """渲染的第三服务、公网 HTTP、PVTC 挂载、host网络、额外 capability 均被拒绝。"""
        original = m.validate_release(self.release)
        mutations = [('public-http', lambda x: x['services']['server']['ports'][0].update(host_ip='0.0.0.0')),
                     ('port80', lambda x: x['services']['https']['ports'][0].update(published='80')),
                     ('port8088', lambda x: x['services']['https']['ports'][0].update(published='8088')),
                     ('socket', lambda x: x['services']['https']['volumes'][0].update(source='/var/run/docker.sock')),
                     ('upstream', lambda x: x['services']['https']['environment'].update(CODEXTOP_UPSTREAM='pvtc:8088')),
                     ('cap', lambda x: x['services']['https']['cap_add'].append('SYS_ADMIN')),
                     ('privileged', lambda x: x['services']['https'].update(privileged=True)),
                     ('extra', lambda x: x['services'].update(other=copy.deepcopy(x['services']['server']))),
                     ('network', lambda x: x['networks']['private'].update(external=True)),
                     ('internal', lambda x: x['networks']['private'].update(internal=True))]
        for name, mutate in mutations:
            model = copy.deepcopy(original)
            mutate(model)
            release = dict(self.release, compose=json.dumps(model, default=str))
            with self.subTest(case=name), self.assertRaises(RuntimeError):
                m.validate_release(release)

    def test_exact_quotas_on_both_roles(self):
        """两角色 CPU、内存/交换、PIDs、日志都不得偏离已审配置。"""
        original = m.validate_release(self.release)
        for role in ('server', 'https'):
            for field, value in (('cpus', 4), ('mem_limit', 1), ('memswap_limit', 2), ('pids_limit', 9999)):
                model = copy.deepcopy(original)
                model['services'][role][field] = value
                with self.subTest(role=role, field=field), self.assertRaises(RuntimeError):
                    m.validate_release(dict(self.release, compose=json.dumps(model, default=str)))

    def test_numeric_equivalence(self):
        """Compose 规范化后的数值等价写法不被错误拒绝。"""
        for size in ('1024K', '512m', '1G'):
            release = copy.deepcopy(self.release)
            release['config']['MEMORY'] = size
            release['config']['HTTPS_CPUS'] = '0.250'
            m.validate_release(release)

    def test_reject_caddyfile_drift(self):
        """归档不能注入不同上游、管理监听或额外站点。"""
        with self.assertRaises(RuntimeError):
            m.validate_release(dict(self.release, caddyfile=self.release['caddyfile'] + '\n:80 { respond unsafe }\n'))

    def test_modified_installed_template_is_not_its_own_allowlist(self):
        """安装位置的模板同时被改写时，不能用它自身证明未知上游已获准。"""
        content = self.release['caddyfile'].replace('server:3005', 'pvtc:8088')
        (self.root / 'Caddyfile').write_text(content)
        with patch.object(m, 'HERE', self.root), self.assertRaisesRegex(RuntimeError, 'Caddyfile'):
            m.validate_release(dict(self.release, caddyfile=content))

    def test_owned_roles_and_neighbors(self):
        """两个归属合格角色不算外部变化；相同项目标签下第三角色不能被豁免。"""
        items = list(self.external.containers.values())
        self.assertEqual(set(m.own_containers(items)), {'server', 'https'})
        self.assertEqual(m.neighbors(items), {})
        foreign = copy.deepcopy(items[0])
        foreign['Id'] = 'foreign'
        foreign['Config']['Labels']['com.docker.compose.service'] = 'database'
        with self.assertRaises(RuntimeError):
            m.neighbors(items + [foreign])

    def test_mount_ownership_rechecked_before_stop(self):
        """操作前发现代理挂载 PVTC 数据时不执行任何 stop。"""
        self.external.containers['https']['Mounts'][0]['Source'] = '/var/lib/pvtc'
        with self.assertRaises(RuntimeError):
            m.stop(self.release, 'https')
        self.assertFalse(any('stop' in args for args in self.external.commands))

    def test_preflight_two_endpoints_and_foreign_network(self):
        """预检允许本项目两个网络端点，但拒绝其他项目拥有的网络。"""
        self.host_boundaries()
        m.preflight(self.release)
        self.external.foreign_network = True
        with self.assertRaisesRegex(RuntimeError, '网络'):
            m.preflight(self.release)

    def test_actual_proxy_port_drift_refuses_stop(self):
        """同名代理实际占用80时不能被当作本部署实例接管或停止。"""
        self.external.containers['https']['HostConfig']['PortBindings']['443/tcp'][0]['HostPort'] = '80'
        with self.assertRaisesRegex(RuntimeError, '端口'):
            m.stop(self.release, 'https')
        self.assertFalse(any('stop' in args for args in self.external.commands))

    def test_foreign_443_and_total_memory_preflight(self):
        """只读预检拒绝他人443及两角色合计超额，不触发容器启动。"""
        self.host_boundaries()
        foreign = container_fixture('https', self.release)
        foreign['Id'] = 'synthetic-pvtc'
        foreign['Config']['Labels']['com.docker.compose.project'] = 'pvtc'
        self.external.containers['foreign'] = foreign
        with self.assertRaisesRegex(RuntimeError, '端口'):
            m.preflight(self.release)
        del self.external.containers['foreign']
        self.release['config']['HTTPS_MEMORY'] = '1g'
        with self.assertRaisesRegex(RuntimeError, '合计内存'):
            m.preflight(self.release)
        self.assertFalse(any('up' in args for args in self.external.commands))


class OperationTests(BoundaryTests):
    """经外部命令边界驱动真实维护流程、SQLite与归档。"""

    def test_start_order_and_no_build_pull(self):
        """启动先 server 再 https，各命令只指向该角色且不自动构建拉取。"""
        self.external.containers = {}
        m.start(self.release)
        m.start(self.release, 'https')
        calls = [args for args in self.external.commands if 'up' in args]
        self.assertEqual([args[-1] for args in calls], ['server', 'https'])
        for args in calls:
            self.assertIn('--no-build', args)
            self.assertIn('--no-deps', args)
            self.assertEqual(args[args.index('--pull') + 1], 'never')
        self.assertEqual((self.root / 'Caddyfile').read_text(), self.release['caddyfile'])

    def test_failed_start_keeps_new_server_stopped(self):
        """迁移后启动失败只停止失败版本，不重启旧镜像。"""
        self.save_current()
        self.external.fail_up = 'server'
        self.release['config']['IMAGE'] = self.release['image_id'] = 'sha256:' + '5' * 64
        with self.assertRaises(RuntimeError):
            m.start(self.release)
        self.assertFalse(self.external.containers['server']['State']['Running'])
        self.assertTrue(self.external.containers['https']['State']['Running'])
        self.assertFalse(any(args[:2] == ['docker', 'start'] for args in self.external.commands))

    def test_failed_two_image_upgrade_can_restore_original_backup(self):
        """双镜像升级的业务启动失败后，原备份仍可恢复业务且原代理身份和 TLS 不变。"""
        self.save_current()
        proxy = copy.deepcopy(self.external.containers['https'])
        archive = m.backup(self.release, self.release['config'], resume=False)
        candidate = copy.deepcopy(self.release)
        candidate['config']['IMAGE'] = candidate['image_id'] = 'sha256:' + '3' * 64
        candidate['config']['HTTPS_IMAGE'] = candidate['https_image_id'] = 'sha256:' + '4' * 64
        candidate['config']['HTTPS_MEMORY'] = '256m'
        self.external.fail_up = 'server'
        with self.assertRaisesRegex(RuntimeError, 'synthetic-up-failure'):
            m.start(candidate)
        self.assertFalse(self.external.containers['server']['State']['Running'])
        self.assertEqual(m.load_release()['image_id'], candidate['image_id'])
        (self.root / 'data/files/upload.txt').write_text('after-failed-migration')
        with sqlite3.connect(self.root / 'data/happier-server-light.sqlite') as database:
            database.execute('UPDATE sample SET value = ?', ('after-failed-migration',))

        # 从真实旧快照恢复；不能把取消漂移检查作为修复，也不能直接重启旧镜像读新数据。
        self.external.fail_up = None
        self.external.commands.clear()
        self.host_boundaries()
        m.rollback(self.rollback_args(archive), candidate['config'])
        saved = m.load_release()
        self.assertEqual(saved['image_id'], self.release['image_id'])
        self.assertEqual(saved['https_image_id'], self.release['https_image_id'])
        self.assertEqual(saved['config']['HTTPS_MEMORY'], self.release['config']['HTTPS_MEMORY'])
        self.assertEqual(self.external.containers['https'], proxy)
        self.assertEqual(self.external.containers['server']['Image'], self.release['image_id'])
        self.assertTrue(self.external.containers['server']['State']['Running'])
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'current')
        with sqlite3.connect(self.root / 'data/happier-server-light.sqlite') as database:
            self.assertEqual(database.execute('SELECT value FROM sample').fetchone()[0], 'current')
        for name in ('data', 'config'):
            self.assertEqual((self.root / 'https' / name / 'synthetic-state').read_text(), 'current-' + name)
        self.assertFalse(any(('stop' in args or 'up' in args) and args[-1] == 'https'
                             for args in self.external.commands))

    def test_successful_upgrade_records_each_role_after_its_turn(self):
        """业务 ready 后仍记录原代理镜像及配额，代理成功后才推进整份记录且不改候选输入。"""
        self.save_current()
        candidate = copy.deepcopy(self.release)
        candidate['config']['IMAGE'] = candidate['image_id'] = 'sha256:' + '3' * 64
        candidate['config']['HTTPS_IMAGE'] = candidate['https_image_id'] = 'sha256:' + '4' * 64
        candidate['config']['HTTPS_MEMORY'] = '256m'
        expected = copy.deepcopy(candidate)
        m.start(candidate)
        saved = m.load_release()
        self.assertEqual(saved['image_id'], candidate['image_id'])
        self.assertEqual(saved['https_image_id'], self.release['https_image_id'])
        self.assertEqual(saved['config']['HTTPS_MEMORY'], self.release['config']['HTTPS_MEMORY'])
        self.assertEqual(m.validate_release(saved)['services']['https'],
                         m.validate_release(self.release)['services']['https'])
        m.start(candidate, 'https')
        self.assertEqual(m.load_release(), candidate)
        self.assertEqual(candidate, expected)

    def test_proxy_failure_before_replacement_keeps_old_record(self):
        """代理 up 尚未替换实例即报错时，业务回滚仍使用实际旧代理记录。"""
        self.save_current()
        archive = m.backup(self.release, self.release['config'], resume=False)
        candidate = copy.deepcopy(self.release)
        candidate['config']['IMAGE'] = candidate['image_id'] = 'sha256:' + '3' * 64
        candidate['config']['HTTPS_IMAGE'] = candidate['https_image_id'] = 'sha256:' + '4' * 64
        m.start(candidate)
        self.external.fail_up_before = 'https'
        with self.assertRaisesRegex(RuntimeError, 'synthetic-up-before-failure'):
            m.start(candidate, 'https')
        self.assertEqual(m.load_release()['https_image_id'], self.release['https_image_id'])
        self.assertEqual(self.external.containers['https']['Id'], 'synthetic-https')
        self.host_boundaries()
        m.rollback(self.rollback_args(archive), candidate['config'])
        self.assertEqual(self.external.containers['server']['Image'], self.release['image_id'])
        self.assertTrue(self.external.containers['server']['State']['Running'])

    def test_proxy_failure_after_replacement_records_new_instance(self):
        """代理已替换再报错时记录实际新版本，停止它并允许保留该版本的业务回滚。"""
        self.save_current()
        archive = m.backup(self.release, self.release['config'], resume=False)
        candidate = copy.deepcopy(self.release)
        candidate['config']['IMAGE'] = candidate['image_id'] = 'sha256:' + '3' * 64
        candidate['config']['HTTPS_IMAGE'] = candidate['https_image_id'] = 'sha256:' + '4' * 64
        m.start(candidate)
        self.external.fail_up = 'https'
        with self.assertRaisesRegex(RuntimeError, 'synthetic-up-failure'):
            m.start(candidate, 'https')
        self.assertEqual(m.load_release(), candidate)
        proxy = copy.deepcopy(self.external.containers['https'])
        self.assertEqual(proxy['Image'], candidate['https_image_id'])
        self.assertFalse(proxy['State']['Running'])
        self.host_boundaries()
        m.rollback(self.rollback_args(archive), candidate['config'])
        self.assertEqual(self.external.containers['https'], proxy)
        self.assertEqual(self.external.containers['server']['Image'], self.release['image_id'])
        self.assertTrue(self.external.containers['server']['State']['Running'])

    def test_server_start_rejects_unrecorded_proxy(self):
        """分阶段写记录不能吞掉真实代理漂移，拒绝前不启动、不停止、不改记录。"""
        self.save_current()
        self.external.containers['https']['Image'] = 'sha256:' + '9' * 64
        with self.assertRaisesRegex(RuntimeError, '当前代理'):
            m.start(self.release)
        self.assertEqual(m.load_release(), self.release)
        self.assertFalse(any('up' in args or 'stop' in args for args in self.external.commands))

    def test_server_start_rejects_mixed_origins(self):
        """已有代理时不写入业务与代理 origin 不一致的快照，也不改候选配置。"""
        self.save_current()
        candidate = copy.deepcopy(self.release)
        candidate['config']['PUBLIC_URL'] = 'https://1.1.1.1'
        with self.assertRaisesRegex(RuntimeError, 'PUBLIC_URL'):
            m.start(candidate)
        self.assertEqual(m.load_release(), self.release)
        self.assertEqual(candidate['config']['PUBLIC_URL'], 'https://1.1.1.1')
        self.assertFalse(any('up' in args or 'stop' in args for args in self.external.commands))

    def test_full_backup_captures_tls_and_resumes(self):
        """同一加密边界归档含业务/TLS/旧配置，恢复原实例且代理先恢复。"""
        output = m.backup(self.release, self.release['config'], resume=True)
        with tarfile.open(output) as archive:
            self.assertEqual(archive.extractfile('data/files/upload.txt').read(), b'current')
            self.assertEqual(archive.extractfile('https/data/synthetic-state').read(), b'current-data')
            release = json.load(archive.extractfile('release.json'))
            self.assertEqual(release['caddyfile'], self.release['caddyfile'])
            self.assertEqual(release['https_image_id'], self.release['https_image_id'])
        starts = [args[-1] for args in self.external.commands if args[:2] == ['docker', 'start']]
        self.assertEqual(starts, ['synthetic-https', 'synthetic-server'])

    def test_upgrade_snapshot_resumes_only_proxy(self):
        """升级的 resume=False 保持 server 停止，但恢复代理续期。"""
        m.backup(self.release, self.release['config'], resume=False)
        self.assertFalse(self.external.containers['server']['State']['Running'])
        self.assertTrue(self.external.containers['https']['State']['Running'])

    def test_backup_preserves_originally_stopped_roles(self):
        """原来停止的角色不因备份被启动。"""
        for item in self.external.containers.values():
            item['State']['Running'] = False
        m.backup(self.release, self.release['config'], resume=True)
        self.assertFalse(any(item['State']['Running'] for item in self.external.containers.values()))

    def test_stop_error_after_effect_recovers_originals(self):
        """stop 命令实际停掉代理后报错，仍重新核验并恢复同一实例。"""
        def fail_after_stop(role):
            """模拟真实停止已发生但外部命令返回失败。"""
            raise RuntimeError('synthetic-stop-failure')
        self.external.after_stop = fail_after_stop
        with self.assertRaisesRegex(RuntimeError, 'synthetic-stop-failure'):
            m.backup(self.release, self.release['config'], resume=False)
        self.assertTrue(all(item['State']['Running'] for item in self.external.containers.values()))
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_inspect_error_after_stop_recovers(self):
        """停止后的第一次 inspect 失败也纳入恢复分支。"""
        def fail_next_inspect(role):
            """只失败下一次外部 inspect，后续恢复核验可用。"""
            self.external.fail_inspects = 1
        self.external.after_stop = fail_next_inspect
        with self.assertRaisesRegex(RuntimeError, 'synthetic-inspect-failure'):
            m.backup(self.release, self.release['config'], resume=False)
        self.assertTrue(self.external.containers['https']['State']['Running'])

    def test_recovery_refuses_replacement(self):
        """原 ID 被替换时拒绝自动恢复替代容器。"""
        def replace_stopped(role):
            """模拟停止阶段外部实例替换，然后返回失败。"""
            self.external.containers[role]['Id'] = 'replacement'
            raise RuntimeError('synthetic-stop-failure')
        self.external.after_stop = replace_stopped
        with self.assertRaisesRegex(RuntimeError, '恢复'):
            m.backup(self.release, self.release['config'], resume=False)
        self.assertFalse(any(args[-1] == 'replacement' and args[:2] == ['docker', 'start']
                             for args in self.external.commands))

    def test_bad_sqlite_restores_both_without_archive(self):
        """真实数据库损坏触发归档前校验失败，恢复两原实例。"""
        (self.root / 'data/happier-server-light.sqlite').write_bytes(b'bad sqlite')
        with self.assertRaises((RuntimeError, sqlite3.DatabaseError)):
            m.backup(self.release, self.release['config'], resume=False)
        self.assertTrue(all(item['State']['Running'] for item in self.external.containers.values()))
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_budget_fails_before_stop_and_counts_tls(self):
        """TLS 数据计入预算；超额不先停服务、不删既有备份。"""
        (self.root / 'https/data/large').write_bytes(b'x' * 2000000)
        policy = dict(self.release['config'], BACKUP_MAX_BYTES='2000000')
        with self.assertRaises(RuntimeError):
            m.backup(self.release, policy, resume=False)
        self.assertFalse(any('stop' in args for args in self.external.commands))

    def test_age_failure_never_publishes_partial(self):
        """age 子进程失败恢复两服务，不发布半成品。"""
        self.age_exit = 2
        with self.assertRaises(RuntimeError):
            m.backup(self.release, self.release['config'], resume=False)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])
        self.assertTrue(all(item['State']['Running'] for item in self.external.containers.values()))

    def test_rollback_keeps_current_tls_and_proxy(self):
        """真实替换旧业务库并保留现有TLS、代理镜像/实例及原业务隔离副本。"""
        self.save_current()
        archive = self.make_archive()
        self.host_boundaries()
        m.rollback(self.rollback_args(archive), self.release['config'])
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'old')
        self.assertEqual((self.root / 'https/data/synthetic-state').read_text(), 'current-data')
        saved = m.load_release()
        self.assertEqual(saved['image_id'], 'sha256:' + '3' * 64)
        self.assertEqual(saved['https_image_id'], 'sha256:' + '2' * 64)
        self.assertEqual(self.external.containers['https']['Id'], 'synthetic-https')
        self.assertFalse(any('stop' in args and args[-1] == 'https' for args in self.external.commands))
        quarantine, = self.root.glob('data-before-rollback-*')
        self.assertEqual((quarantine / 'files/upload.txt').read_text(), 'current')

    def test_rollback_rejects_origin_change_before_stop(self):
        """旧业务 origin 不匹配现入口时，不停服也不替换数据。"""
        self.save_current()
        archive = self.make_archive(origin='https://1.1.1.1')
        self.host_boundaries()
        with self.assertRaisesRegex(RuntimeError, '入口|PUBLIC_URL'):
            m.rollback(self.rollback_args(archive), self.release['config'])
        self.assertFalse(any('stop' in args for args in self.external.commands))

    def test_rollback_rejects_unrecorded_proxy_before_stop(self):
        """不能把漂移的真实代理冒充记录中的当前版本而继续业务回滚。"""
        self.save_current()
        archive = self.make_archive()
        self.external.containers['https']['Image'] = 'sha256:' + '9' * 64
        self.host_boundaries()
        with self.assertRaisesRegex(RuntimeError, '当前代理'):
            m.rollback(self.rollback_args(archive), self.release['config'])
        self.assertFalse(any('stop' in args for args in self.external.commands))

    def test_disaster_tls_recheck_precedes_business_swap(self):
        """停止边界后发现TLS目录被写入时，业务数据也必须尚未替换。"""
        archive = self.make_archive()
        for name in ('data', 'config'):
            (self.root / 'https' / name / 'synthetic-state').unlink()
        self.external.containers.pop('https')
        self.host_boundaries()

        def write_after_stop(role):
            """模拟外部写者在检查后写入，确保不会覆盖其文件。"""
            (self.root / 'https/data/unexpected').write_text('preserve')
        self.external.after_stop = write_after_stop
        with self.assertRaisesRegex(RuntimeError, '空'):
            m.rollback(self.rollback_args(archive, True), self.release['config'])
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'current')
        self.assertEqual((self.root / 'https/data/unexpected').read_text(), 'preserve')

    def test_explicit_tls_restore_requires_empty_directories(self):
        """显式灾备也不能覆盖当前已有ACME状态。"""
        self.save_current()
        archive = self.make_archive()
        self.host_boundaries()
        with self.assertRaisesRegex(RuntimeError, '空'):
            m.rollback(self.rollback_args(archive, True), self.release['config'])
        self.assertFalse(any('stop' in args for args in self.external.commands))

    def test_empty_tls_disaster_restore(self):
        """空TLS目录可显式恢复归档状态，并启动归档代理版本。"""
        archive = self.make_archive()
        for name in ('data', 'config'):
            (self.root / 'https' / name / 'synthetic-state').unlink()
        self.external.containers.pop('https')
        self.host_boundaries()
        m.rollback(self.rollback_args(archive, True), self.release['config'])
        self.assertEqual((self.root / 'https/data/synthetic-state').read_text(), 'old-data')
        self.assertEqual(m.load_release()['https_image_id'], 'sha256:' + '4' * 64)
        self.assertEqual(self.external.containers['https']['Image'], 'sha256:' + '4' * 64)

    def test_empty_tls_disaster_restore_with_stopped_proxy(self):
        """没有现行记录但保留停止代理的显式空 TLS 灾备，仍按归档完整恢复两角色。"""
        archive = self.make_archive()
        for name in ('data', 'config'):
            (self.root / 'https' / name / 'synthetic-state').unlink()
        self.external.containers['https']['State']['Running'] = False
        self.host_boundaries()
        m.rollback(self.rollback_args(archive, True), self.release['config'])
        self.assertEqual(m.load_release()['https_image_id'], 'sha256:' + '4' * 64)
        self.assertEqual(self.external.containers['https']['Image'], 'sha256:' + '4' * 64)
        self.assertTrue(all(item['State']['Running'] for item in self.external.containers.values()))
        self.assertEqual((self.root / 'https/data/synthetic-state').read_text(), 'old-data')

    def test_authentication_failure_after_tar_never_stops(self):
        """有效tar后的age尾部认证失败不能跨过停服边界。"""
        archive = self.make_archive()
        self.age_exit = 2
        with self.assertRaisesRegex(RuntimeError, '认证'):
            m.rollback(self.rollback_args(archive), self.release['config'])
        self.assertFalse(any('stop' in args for args in self.external.commands))
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'current')

    def test_untrusted_archive_paths_links_and_budget(self):
        """业务及TLS归档均拒绝路径逃逸、符号链接、重复和超额展开。"""
        for name, kind in (('../escape', 'file'), ('https/../../escape', 'file'),
                           ('https/other/a', 'file'), ('https/data/a', 'link'),
                           ('data/a', 'duplicate'), ('https/data/a', 'size')):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as archive:
                member = tarfile.TarInfo(name)
                member.size = 2
                if kind == 'link':
                    member.type, member.linkname = tarfile.SYMTYPE, '/etc/passwd'
                archive.addfile(member, io.BytesIO(b'ab'))
                if kind == 'duplicate':
                    archive.addfile(member, io.BytesIO(b'ab'))
            stream.seek(0)
            with tempfile.TemporaryDirectory(dir=self.root) as target, tarfile.open(fileobj=stream) as archive:
                with self.subTest(name=name, kind=kind), self.assertRaises(RuntimeError):
                    m.unpack(archive, Path(target), 1 if kind == 'size' else 100000)


if __name__ == '__main__':
    unittest.main()
