"""只用合成目录验证发布边界；不会访问 Docker daemon，也不冒充真实 age 演练。"""

import contextlib
import copy
import io
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import manage as m


def sample_config():
    """提供仅用于静态/合成检查的参数，不是生产推荐配额。"""
    return {'ROOT': '/opt/codex-top', 'IMAGE': 'sha256:' + '1' * 64, 'PORT': '43117',
            'PUBLIC_URL': 'https://codex.example.invalid', 'CPUS': '0.5', 'MEMORY': '512m',
            'PIDS': '128', 'LOG_SIZE': '1m', 'LOG_FILES': '2', 'MIN_FREE_MEMORY_BYTES': '1',
            'MIN_FREE_DISK_BYTES': '1', 'BACKUP_MAX_BYTES': '20000000', 'BACKUP_MAX_COUNT': '3',
            'BACKUP_RECIPIENT': 'age1syntheticrecipient', 'WAIT_SECONDS': '5', 'STOP_SECONDS': '5'}


def sample_release():
    """使用真实 Compose 文件构造候选快照，镜像 ID 为合成值。"""
    return {'config': sample_config(), 'compose': (m.HERE / 'compose.yaml').read_text(),
            'image_id': 'sha256:' + '1' * 64}


def sample_container(running=True):
    """提供本项目合成容器元数据，可指定运行状态，不读取真实 Docker。"""
    return {'Id': 'synthetic-own', 'Image': 'sha256:' + '1' * 64,
            'Config': {'Labels': {'com.docker.compose.project': m.PROJECT,
                                  'com.docker.compose.service': 'server'}},
            'Mounts': [{'Source': str(m.ROOT / 'data'), 'Destination': '/data'}],
            'NetworkSettings': {'Networks': {m.NETWORK: {}}},
            'State': {'Running': running, 'Health': {'Status': 'healthy'}}}


def populate(directory, marker):
    """创建可做完整性校验的独立 SQLite、合成主密钥及上传文件。"""
    directory.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(directory / 'happier-server-light.sqlite') as database:
        database.execute('CREATE TABLE sample (value TEXT)')
        database.execute('INSERT INTO sample VALUES (?)', (marker,))
    (directory / 'handy-master-secret.txt').write_text('synthetic-secret-' + marker)
    (directory / 'files').mkdir()
    (directory / 'files/upload.txt').write_text(marker)


def snapshot(directory, release):
    """打包合成数据用于恢复检查；此方法不进行加密。"""
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        archive.add(directory, arcname='data')
        content = json.dumps(release).encode()
        member = tarfile.TarInfo('release.json')
        member.size = len(content)
        archive.addfile(member, io.BytesIO(content))
    return data.getvalue()


class StaticConfigTests(unittest.TestCase):
    """用真实 Compose 解析器检查配置边界，始终只执行 config/version。"""

    def test_real_compose_and_ambient_env(self):
        """环境变量不得覆盖文件中的镜像或对公网开放端口。"""
        with patch.dict(m.os.environ, {'CODEX_TOP_PORT': '22', 'COMPOSE_PROJECT_NAME': 'pvtc'}):
            rendered = m.validate_release(sample_release())
        self.assertEqual(rendered['services']['server']['ports'][0]['published'], '43117')

    def test_required_values_and_unpinned_image(self):
        """空值、浮动标签、重复项、shell 表达式和私密扩展字段都不能通过。"""
        valid = m.env_text(sample_config())
        cases = [valid.replace('CODEX_TOP_PIDS=128', 'CODEX_TOP_PIDS='),
                 valid.replace('sha256:' + '1' * 64, 'latest'), valid + 'CODEX_TOP_PORT=3\n',
                 valid.replace('512m', '$(echo-secret)'), valid + 'HANDY_MASTER_SECRET=x\n',
                 (m.HERE / '.env.example').read_text()]
        for content in cases:
            with self.subTest(content=content[:20]), self.assertRaises(RuntimeError):
                m.parse_env(content)

    def test_rejects_scope_expansion(self):
        """真实渲染结果必须拒绝公网端口、其他挂载、主机网络及环境逃逸。"""
        changes = [('127.0.0.1:', '0.0.0.0:'), ('/opt/codex-top/data:/data', '/var/lib/pvtc:/data'),
                   ('    init: true', '    init: true\n    privileged: true'),
                   ('      NODE_ENV: production', '      DATABASE_URL: file:/elsewhere\n      NODE_ENV: production'),
                   ('    name: codex-top-private', '    name: pvtc-network')]
        for old, new in changes:
            release = sample_release()
            release['compose'] = release['compose'].replace(old, new)
            with self.subTest(change=old), self.assertRaises(RuntimeError):
                m.validate_release(release)

    def test_foreign_project_collision(self):
        """相同项目名下的异服务或外部挂载不能被停止或接管。"""
        own = sample_container()
        own['Mounts'][0]['Source'] = '/var/lib/pvtc'
        with self.assertRaises(RuntimeError):
            m.own_container([own])

    def test_rendered_quotas_must_match_release_config(self):
        """真实 Compose 中 CPU、PIDs、内存或交换配额偏离已审配置时必须拒绝。"""
        cases = ({'cpus': '4'}, {'pids_limit': '1000000'},
                 {'cpus': '4', 'pids_limit': '1000000'},
                 {'mem_limit': '1g', 'memswap_limit': '1g'},
                 {'mem_limit': '256m', 'memswap_limit': '256m'},
                 {'memswap_limit': '1g'}, {'cpus': '0.25'})
        for changes in cases:
            release = sample_release()
            for field, value in changes.items():
                release['compose'] = re.sub(r'(?m)^    ' + field + r':.*$',
                                            '    ' + field + ': ' + value, release['compose'])
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                m.validate_release(release)

    def test_equivalent_numeric_quotas_remain_valid(self):
        """数值等价的 CPU 小数和内存字节写法保持兼容。"""
        release = sample_release()
        for field, value in {'cpus': '0.500', 'mem_limit': '536870912',
                             'memswap_limit': '536870912'}.items():
            release['compose'] = re.sub(r'(?m)^    ' + field + r':.*$',
                                        '    ' + field + ': ' + value, release['compose'])
        m.validate_release(release)

    def test_memory_unit_normalization_matches_compose(self):
        """配置允许的 k/m/g 单位和大小写都与 Compose 的字节值一致。"""
        for memory in ('1024K', '512m', '1G'):
            release = sample_release()
            release['config']['MEMORY'] = memory
            with self.subTest(memory=memory):
                m.validate_release(release)


class OperationTests(unittest.TestCase):
    """替换 Docker/age 边界，验证停服顺序、归档内容和错误恢复。"""

    def setUp(self):
        """每项测试使用独立临时根目录，退出后只清理这些合成数据。"""
        self.temp = tempfile.TemporaryDirectory(prefix='codex-top-deploy-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(patch.stopall)
        patch.object(m, 'ROOT', self.root).start()
        self.release = sample_release()
        populate(self.root / 'data', 'current')
        self.real_popen = subprocess.Popen

    def fake_age(self, args, **kwargs):
        """用无加密字节管道替代 age，仅验证控制流和归档；不声称密码学验证。"""
        if args[1] == '-d':
            program = 'import pathlib,sys; sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())'
            return self.real_popen([sys.executable, '-c', program, args[-1]], **kwargs)
        self.assertEqual(args[:2], ['age', '-r'])
        program = 'import sys,shutil; shutil.copyfileobj(sys.stdin.buffer,sys.stdout.buffer)'
        return self.real_popen([sys.executable, '-c', program], **kwargs)

    def test_start_has_no_build_pull_or_other_service(self):
        """真实启动参数禁止构建、拉取和依赖扩张，只指定 server。"""
        with patch.object(m, 'compose_command', return_value=contextlib.nullcontext(['compose'])), \
                patch.object(m, 'run') as command, patch.object(m, 'save_release'), \
                patch.object(m, 'inspect_containers', return_value=[sample_container()]):
            m.start(self.release)
        args = command.call_args.args[0]
        self.assertIn('--no-build', args)
        self.assertIn('--no-deps', args)
        self.assertEqual(args[args.index('--pull') + 1], 'never')
        self.assertEqual(args[-1], 'server')

    def test_failed_start_stops_without_old_image_restart(self):
        """启动失败只停止当前服务，没有自动以旧镜像读取迁移数据的路径。"""
        with patch.object(m, 'compose_command', return_value=contextlib.nullcontext(['compose'])), \
                patch.object(m, 'save_release'), patch.object(m, 'run', side_effect=RuntimeError('failed')) as command, \
                patch.object(m, 'inspect_containers', return_value=[sample_container()]), \
                patch.object(m, 'stop') as stop:
            with self.assertRaises(RuntimeError):
                m.start(self.release)
        self.assertEqual(command.call_count, 1)
        stop.assert_called_once_with(self.release)

    def test_stop_rechecks_owner_before_mutating(self):
        """停止前再次检查归属，防止预检后项目名冲突导致停止其他数据服务。"""
        foreign = sample_container()
        foreign['Mounts'][0]['Source'] = '/var/lib/pvtc'
        with patch.object(m, 'inspect_containers', return_value=[foreign]), patch.object(m, 'run') as command:
            with self.assertRaises(RuntimeError):
                m.stop(self.release)
        command.assert_not_called()

    def test_backup_recovers_if_inspect_fails_after_compose_stopped(self):
        """真实 stop 控制流中 Compose 已停止、随后 inspect 失败，也必须安全恢复原实例。"""
        inspections = [[sample_container()], [sample_container()],
                       RuntimeError('stop-inspect-failed'), [sample_container(running=False)]]
        with patch.object(m, 'inspect_containers', side_effect=inspections) as inspect, \
                patch.object(m, 'compose_command', return_value=contextlib.nullcontext(['compose'])), \
                patch.object(m, 'run') as command, patch.object(m, 'start') as start, \
                patch.object(m.subprocess, 'Popen') as age:
            with self.assertRaisesRegex(RuntimeError, 'stop-inspect-failed'):
                m.backup(self.release, self.release['config'], resume=False)
        command.assert_called_once_with(['compose', 'stop', '--timeout', '5', 'server'])
        self.assertEqual(inspect.call_count, 4)
        start.assert_called_once_with(self.release)
        age.assert_not_called()
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_backup_rechecks_after_stop_command_reports_failure(self):
        """停止命令报错但容器已停止时，重查原实例后恢复且不进入归档。"""
        inspections = [[sample_container()], [sample_container()], [sample_container(running=False)]]
        with patch.object(m, 'inspect_containers', side_effect=inspections), \
                patch.object(m, 'compose_command', return_value=contextlib.nullcontext(['compose'])), \
                patch.object(m, 'run', side_effect=RuntimeError('stop-command-failed')), \
                patch.object(m, 'start') as start, patch.object(m.subprocess, 'Popen') as age:
            with self.assertRaisesRegex(RuntimeError, 'stop-command-failed'):
                m.backup(self.release, self.release['config'], resume=False)
        start.assert_called_once_with(self.release)
        age.assert_not_called()

    def test_backup_recovery_refuses_changed_or_unknown_owner(self):
        """恢复时遇到归属改变、实例替换、镜像改变、缺失或状态未知，都不启动。"""
        foreign = sample_container(running=False)
        foreign['Mounts'][0]['Source'] = '/var/lib/pvtc'
        replacement = sample_container(running=False)
        replacement['Id'] = 'replacement'
        changed_image = sample_container(running=False)
        changed_image['Image'] = 'sha256:' + '9' * 64
        unknown_state = sample_container(running=False)
        del unknown_state['State']['Running']
        cases = ([foreign], [replacement], [changed_image], [], [unknown_state], RuntimeError('inspect-unavailable'))
        for current in cases:
            failure = RuntimeError('stop-phase-failed')
            with self.subTest(current=current), \
                    patch.object(m, 'inspect_containers', side_effect=[[sample_container()], current]) as inspect, \
                    patch.object(m, 'stop', side_effect=failure), patch.object(m, 'start') as start, \
                    patch.object(m.subprocess, 'Popen') as age:
                with self.assertRaisesRegex(RuntimeError, '无法安全恢复原服务') as caught:
                    m.backup(self.release, self.release['config'], resume=False)
                self.assertIs(caught.exception.__cause__, failure)
                self.assertEqual(inspect.call_count, 2)
                start.assert_not_called()
                age.assert_not_called()

    def test_backup_failure_does_not_restart_still_running_instance(self):
        """停止失败后原实例仍在运行时不重建或重复启动它。"""
        with patch.object(m, 'inspect_containers', side_effect=[[sample_container()], [sample_container()]]), \
                patch.object(m, 'stop', side_effect=RuntimeError('stop-phase-failed')), \
                patch.object(m, 'start') as start:
            with self.assertRaisesRegex(RuntimeError, 'stop-phase-failed'):
                m.backup(self.release, self.release['config'], resume=False)
        start.assert_not_called()

    def test_backup_failure_preserves_originally_stopped_instance(self):
        """备份前原本停止的实例，在停止阶段失败后也不得被启动。"""
        with patch.object(m, 'inspect_containers', return_value=[sample_container(running=False)]) as inspect, \
                patch.object(m, 'stop', side_effect=RuntimeError('stop-phase-failed')), \
                patch.object(m, 'start') as start:
            with self.assertRaisesRegex(RuntimeError, 'stop-phase-failed'):
                m.backup(self.release, self.release['config'], resume=False)
        self.assertEqual(inspect.call_count, 1)
        start.assert_not_called()

    def test_full_backup_and_same_version_resume(self):
        """完整快照保存旧版本配置、数据库、主密钥和文件，并只恢复原版本。"""
        policy = copy.deepcopy(self.release['config'])
        policy['IMAGE'] = 'sha256:' + '2' * 64
        with patch.object(m, 'inspect_containers', side_effect=[[sample_container()], [sample_container(running=False)]]), \
                patch.object(m, 'stop') as stop, patch.object(m, 'start') as start, \
                patch.object(m.subprocess, 'Popen', side_effect=self.fake_age):
            output = m.backup(self.release, policy, resume=True)
        stop.assert_called_once_with(self.release)
        start.assert_called_once_with(self.release)
        with tarfile.open(output) as archive:
            self.assertIn('data/happier-server-light.sqlite', archive.getnames())
            self.assertEqual(archive.extractfile('data/files/upload.txt').read(), b'current')
            self.assertEqual(archive.extractfile('data/handy-master-secret.txt').read(), b'synthetic-secret-current')
            self.assertEqual(json.load(archive.extractfile('release.json'))['config']['IMAGE'], self.release['config']['IMAGE'])

    def test_backup_failure_resumes_before_migration(self):
        """归档失败必须恢复原本运行的版本，并清理本次不完整输出。"""
        with patch.object(m, 'inspect_containers', side_effect=[[sample_container()], [sample_container(running=False)]]), \
                patch.object(m, 'stop'), patch.object(m, 'start') as start, \
                patch.object(m, 'verify_data', side_effect=RuntimeError('bad snapshot')):
            with self.assertRaises(RuntimeError):
                m.backup(self.release, self.release['config'], resume=False)
        start.assert_called_once_with(self.release)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_quota_refusal_happens_before_stop(self):
        """备份容量不足时不得先停服，也不得删除旧备份。"""
        cfg = dict(self.release['config'], BACKUP_MAX_BYTES='1')
        with patch.object(m, 'inspect_containers', return_value=[sample_container()]), patch.object(m, 'stop') as stop:
            with self.assertRaises(RuntimeError):
                m.backup(self.release, cfg, resume=False)
        stop.assert_not_called()

    def test_age_failure_resumes_without_publishing_archive(self):
        """真实子进程边界返回错误时清理本次半成品并恢复原服务。"""
        def failed_age(args, **kwargs):
            """消费全部输入后失败，模拟 age 写出中断或加密错误。"""
            return self.real_popen([sys.executable, '-c', 'import sys; sys.stdin.buffer.read(); sys.exit(2)'], **kwargs)
        with patch.object(m, 'inspect_containers', side_effect=[[sample_container()], [sample_container(running=False)]]), \
                patch.object(m, 'stop'), patch.object(m, 'start') as start, \
                patch.object(m.subprocess, 'Popen', side_effect=failed_age):
            with self.assertRaisesRegex(RuntimeError, 'age 加密失败'):
                m.backup(self.release, self.release['config'], resume=False)
        start.assert_called_once_with(self.release)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_authentication_failure_after_valid_tar_never_stops(self):
        """tar 已可解析但 age 最终认证失败时，仍不得停止或替换现有数据。"""
        content = snapshot(self.root / 'data', self.release)
        archive = self.root / 'synthetic.tar.age'
        archive.write_bytes(content)
        identity = self.root / 'synthetic-key'
        identity.write_text('synthetic')
        identity.chmod(0o600)
        args = m.argparse.Namespace(accept_data_loss=True, identity=str(identity), archive=str(archive))
        def failed_auth(command, **kwargs):
            """输出完整合成 tar 后报错，模拟尾部认证失败。"""
            program = 'import pathlib,sys; sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes()); sys.exit(2)'
            return self.real_popen([sys.executable, '-c', program, command[-1]], **kwargs)
        with patch.object(m.subprocess, 'Popen', side_effect=failed_auth), patch.object(m, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, '认证失败'):
                m.rollback(args, self.release['config'])
        stop.assert_not_called()
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'current')

    def test_restore_keeps_current_data_and_matching_version(self):
        """恢复使用归档版本，完整替换数据库/密钥/文件，并保留原数据供排查。"""
        old_data = self.root / 'synthetic-old'
        populate(old_data, 'old')
        old_release = copy.deepcopy(self.release)
        old_release['config']['IMAGE'] = old_release['image_id'] = 'sha256:' + '3' * 64
        archive = self.root / 'synthetic.tar.age'
        archive.write_bytes(snapshot(old_data, old_release))
        identity = self.root / 'synthetic-key'
        identity.write_text('synthetic')
        identity.chmod(0o600)
        args = m.argparse.Namespace(accept_data_loss=True, identity=str(identity), archive=str(archive))
        with patch.object(m.subprocess, 'Popen', side_effect=self.fake_age), patch.object(m, 'validate_release'), \
                patch.object(m, 'preflight'), patch.object(m, 'stop') as stop, \
                patch.object(m, 'start') as start, patch.object(m.os, 'chown'):
            m.rollback(args, self.release['config'])
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'old')
        self.assertEqual((self.root / 'data/handy-master-secret.txt').read_text(), 'synthetic-secret-old')
        quarantine = list(self.root.glob('data-before-rollback-*'))
        self.assertEqual(len(quarantine), 1)
        self.assertEqual((quarantine[0] / 'files/upload.txt').read_text(), 'current')
        self.assertEqual(stop.call_args.args[0]['image_id'], old_release['image_id'])
        self.assertEqual(start.call_args.args[0]['image_id'], old_release['image_id'])

    def test_corrupt_restore_does_not_stop_current(self):
        """解密/归档损坏时保留原服务和数据，不跨入停止阶段。"""
        archive = self.root / 'broken.tar.age'
        archive.write_bytes(b'not an archive')
        identity = self.root / 'synthetic-key'
        identity.write_text('synthetic')
        identity.chmod(0o600)
        args = m.argparse.Namespace(accept_data_loss=True, identity=str(identity), archive=str(archive))
        with patch.object(m.subprocess, 'Popen', side_effect=self.fake_age), patch.object(m, 'stop') as stop:
            with self.assertRaises(tarfile.TarError):
                m.rollback(args, self.release['config'])
        stop.assert_not_called()
        self.assertEqual((self.root / 'data/files/upload.txt').read_text(), 'current')

    def test_untrusted_archive_members_and_size(self):
        """归档路径穿越、链接、重复项和超预算内容均在暂存阶段拒绝。"""
        for kind in ('traversal', 'link', 'duplicate', 'size'):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as archive:
                member = tarfile.TarInfo('../escape' if kind == 'traversal' else 'data/a')
                member.size = 2
                if kind == 'link':
                    member.type, member.linkname = tarfile.SYMTYPE, '/etc/passwd'
                archive.addfile(member, io.BytesIO(b'ab'))
                if kind == 'duplicate':
                    archive.addfile(member, io.BytesIO(b'ab'))
            stream.seek(0)
            with tempfile.TemporaryDirectory(dir=self.root) as output, tarfile.open(fileobj=stream) as archive:
                with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                    m.unpack(archive, Path(output), 1 if kind == 'size' else 100000)

    def test_preflight_rejects_foreign_network(self):
        """预检不会接管同名但属于其他项目的网络。"""
        def docker_response(args, input_text=None):
            """只返回白名单合成元数据，任何意外 Docker 命令都使测试失败。"""
            if args[0] == 'age':
                return ''
            if args[:3] == ['docker', 'image', 'inspect']:
                return json.dumps([{'Id': self.release['image_id'], 'Config': {'User': 'node', 'Cmd': ['run-server']}}])
            if args[:3] == ['docker', 'network', 'ls']:
                return 'synthetic-network'
            if args[:3] == ['docker', 'network', 'inspect']:
                return json.dumps([{'Labels': {'com.docker.compose.project': 'pvtc'}, 'Containers': {}}])
            self.fail('意外外部命令：' + str(args))
        self.release['config']['PUBLIC_URL'] = 'https://codex.test.example.org'
        with patch.object(m, 'run', side_effect=docker_response), \
                patch.object(Path, 'read_text', return_value='MemAvailable: 1000000 kB\n'), \
                patch.object(m, 'validate_release', return_value={'services': {'server': {'mem_limit': '1'}}}), \
                patch.object(m, 'inspect_containers', return_value=[]), patch.object(m.socket, 'socket'):
            with self.assertRaisesRegex(RuntimeError, '网络已被其他'):
                m.preflight(self.release)


if __name__ == '__main__':
    unittest.main()
