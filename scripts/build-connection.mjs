#!/usr/bin/env node
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve, join } from 'node:path';
import { access, readFile, symlink, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';

/** 复用相邻开源仓库的正式二进制打包器，包含托管运行时和其既有资源依赖。 */
async function main() {
    const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
    const defaults = JSON.parse(await readFile(join(root, 'scripts/build-version.json'), 'utf8'));
    const version = process.env.VERSION || defaults.version;
    const buildNumber = String(process.env.CODEX_TOP_BUILD_NUMBER || defaults.buildNumber);
    if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/.test(version) || !/^[1-9]\d*$/.test(buildNumber)) {
        throw new Error('Use a semantic VERSION and a positive CODEX_TOP_BUILD_NUMBER.');
    }
    const releaseVersion = `${version}+codextop.${buildNumber}`;
    const source = resolve(process.env.CODEX_TOP_CONNECTION_SOURCE || join(root, '../happier'));
    const payloadDir = join(root, '.local/connection-payload');
    const modulePath = join(source, 'packages/cli-common/dist/componentArtifacts/index.js');
    await access(modulePath);
    const { buildCliBinaryArtifactPayload } = await import(pathToFileURL(modulePath).href);
    // 只构建本机架构；真正分发 Intel 版需使用打包器的对应目标单独验证。
    const result = await buildCliBinaryArtifactPayload({ repoRoot: source, payloadDir, releaseVersion });
    // canonical 参数会把版本写进不可变构建源和编译配置；旧 manifest 不得冒充新包。
    const manifest = JSON.parse(await readFile(join(payloadDir, 'package-dist/.build-manifest.json'), 'utf8'));
    if (manifest.buildVersion !== releaseVersion) throw new Error('Connection build manifest does not match the requested version.');
    const { DEFAULT_CLI_RUNTIME_IMPORT_TIMEOUT_MS } = await import(pathToFileURL(join(source, 'packages/cli-common/runtimeImportProbePolicy.mjs')).href);
    const probeHome = await mkdtemp(join(tmpdir(), 'codextop-version-'));
    try {
        // --version 在认证前退出；使用临时产品 HOME 核对实际二进制，不读写已有登录。
        const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('HAPPIER_') && !key.startsWith('HAPPY_')));
        const reportedVersion = execFileSync(join(payloadDir, result.executableName), ['--version'], {
            encoding: 'utf8', timeout: DEFAULT_CLI_RUNTIME_IMPORT_TIMEOUT_MS,
            env: { ...env, HAPPIER_HOME_DIR: probeHome, HAPPIER_PRODUCT_MODE: 'codextop' },
        }).trim();
        if (reportedVersion !== releaseVersion) throw new Error('Compiled connection version does not match the requested version.');
    } finally { await rm(probeHome, { recursive: true, force: true }); }
    // 仅在 manifest 与编译版本一致后发布原生入口，失败产物不能被下一步打包选中。
    await symlink(result.executableName, join(payloadDir, 'codex-top-bridge'));
    console.log(`Codex Top connection component ${releaseVersion} built for this Mac.`);
}

// 打包错误仅出现在开发日志，不能作为产品登录的原始错误信息显示。
main().catch((error) => { console.error(error); process.exitCode = 1; });
