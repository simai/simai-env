import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, extname, normalize, relative, resolve, sep } from 'node:path';
import { defineConfig } from 'vite';
import fg from 'fast-glob';

function copyIfExists(from, to) {
    if (! existsSync(from)) {
        return;
    }

    mkdirSync(dirname(to), { recursive: true });
    cpSync(from, to, { recursive: true });
}

function copyStaticAssets() {
    copyIfExists('source/_core/_assets/img', 'source/assets/build/img');
    copyIfExists('source/img', 'source/assets/build/img');
}

function rebuildStaticAssets() {
    rmSync('source/assets/build/img', { recursive: true, force: true });
    copyStaticAssets();
}

function staticAssetFiles() {
    return fg.sync([
        'source/_core/_assets/img/**/*',
        'source/img/**/*',
    ], { onlyFiles: true, dot: true });
}

function projectPath(path) {
    const candidate = relative(resolve('.'), resolve(path)).replaceAll('\\', '/');
    return candidate === '..' || candidate.startsWith('../') ? null : candidate;
}

function staticAssetRelativePath(path) {
    const candidate = projectPath(path);
    if (candidate?.startsWith('source/img/')) {
        return candidate.slice('source/img/'.length);
    }
    if (candidate?.startsWith('source/_core/_assets/img/')) {
        return candidate.slice('source/_core/_assets/img/'.length);
    }

    return null;
}

function syncStaticAsset(path) {
    const assetPath = staticAssetRelativePath(path);
    if (assetPath === null) {
        return false;
    }
    const target = resolve('source/assets/build/img', assetPath);
    const projectSource = resolve('source/img', assetPath);
    const coreSource = resolve('source/_core/_assets/img', assetPath);
    const source = existsSync(projectSource) ? projectSource : existsSync(coreSource) ? coreSource : null;
    if (source === null) {
        rmSync(target, { force: true });
        return true;
    }

    mkdirSync(dirname(target), { recursive: true });
    cpSync(source, target);
    return true;
}

function isDocaraAuthorInput(path) {
    const candidate = projectPath(path);
    if (candidate === null
        || candidate === 'source/hot'
        || candidate.startsWith('build_')
        || candidate.startsWith('.cache/')
        || candidate.startsWith('source/assets/build/')
        || candidate.startsWith('node_modules/')
        || candidate.startsWith('vendor/')
    ) {
        return false;
    }
    if (['config.php', 'bootstrap.php', 'blade.php'].includes(candidate)) {
        return true;
    }
    if (candidate.startsWith('listeners/')) {
        return candidate.endsWith('.php');
    }

    return candidate.startsWith('source/')
        && /\.(?:md|php|html|json|ya?ml)$/i.test(candidate);
}

function resolveBuildFile(requestUrl) {
    let requestPath;
    try {
        requestPath = decodeURIComponent((requestUrl || '/').split('?')[0]);
    } catch {
        return null;
    }
    if (requestPath.includes('\0')
        || requestPath.includes('\\')
        || requestPath.split('/').includes('..')
    ) {
        return null;
    }

    const buildRoot = resolve('build_local');
    const relativePath = requestPath === '/' ? 'index.html' : requestPath.replace(/^\/+/, '');
    let candidate = resolve(buildRoot, relativePath);
    if (candidate !== buildRoot && ! candidate.startsWith(buildRoot + sep)) {
        return null;
    }
    if (! existsSync(candidate)) {
        return null;
    }
    if (statSync(candidate).isDirectory()) {
        candidate = resolve(candidate, 'index.html');
        if (! existsSync(candidate)) {
            return null;
        }
    }

    const realCandidate = realpathSync(candidate);
    if ((realCandidate !== buildRoot && ! realCandidate.startsWith(buildRoot + sep))
        || ! statSync(realCandidate).isFile()
    ) {
        return null;
    }

    return realCandidate;
}

function buildFileContentType(filePath) {
    const types = {
        '.html': 'text/html; charset=utf-8',
        '.css': 'text/css; charset=utf-8',
        '.js': 'text/javascript; charset=utf-8',
        '.mjs': 'text/javascript; charset=utf-8',
        '.json': 'application/json; charset=utf-8',
        '.map': 'application/json; charset=utf-8',
        '.svg': 'image/svg+xml',
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.gif': 'image/gif',
        '.webp': 'image/webp',
        '.avif': 'image/avif',
        '.ico': 'image/x-icon',
        '.woff': 'font/woff',
        '.woff2': 'font/woff2',
        '.ttf': 'font/ttf',
        '.otf': 'font/otf',
        '.eot': 'application/vnd.ms-fontobject',
        '.xml': 'application/xml; charset=utf-8',
        '.txt': 'text/plain; charset=utf-8',
    };

    return types[extname(filePath).toLowerCase()] || 'application/octet-stream';
}

function findDocaraCommand() {
    const localBin = normalize('./vendor/bin/docara');
    if (existsSync(localBin)) {
        return {
            command: process.env.DOCARA_PHP_BINARY || 'php',
            args: [localBin],
        };
    }

    return {
        command: 'docara',
        args: [],
    };
}

function runDocaraBuild(env) {
    if (process.env.DOCARA_SKIP_BUILD === '1') {
        return Promise.resolve();
    }

    return new Promise((resolveBuild, rejectBuild) => {
        const docaraCommand = findDocaraCommand();
        const child = spawn(docaraCommand.command, [...docaraCommand.args, 'build', env, '--cache=false'], {
            stdio: 'inherit',
            shell: process.platform === 'win32',
        });

        let settled = false;
        child.once('error', (error) => {
            settled = true;
            rejectBuild(new Error(`Unable to start Docara build: ${error.message}`));
        });
        child.once('close', (code, signal) => {
            if (settled) {
                return;
            }
            if (code !== 0 || signal !== null) {
                const outcome = signal !== null ? `signal ${signal}` : `exit code ${String(code)}`;
                rejectBuild(new Error(`Docara build failed with ${outcome}.`));
                return;
            }

            resolveBuild();
        });
    });
}

function docara() {
    const modeToEnv = (mode) => mode === 'production' ? 'production' : 'local';

    let buildEnv = 'local';

    return {
        name: 'docara',
        configResolved(config) {
            buildEnv = modeToEnv(config.mode);
            if (config.command === 'build') {
                rmSync('source/hot', { force: true });
            }
        },
        buildStart() {
            ['source/_core/_assets/img', 'source/img']
                .filter((path) => existsSync(path))
                .forEach((path) => this.addWatchFile(path));
            staticAssetFiles().forEach((file) => this.addWatchFile(file));
        },
        watchChange(path) {
            syncStaticAsset(path);
        },
        configureServer(server) {
            let buildQueue = Promise.resolve();
            let buildTimer = null;
            const scheduleBuild = () => {
                if (buildTimer !== null) {
                    clearTimeout(buildTimer);
                }
                buildTimer = setTimeout(() => {
                    buildTimer = null;
                    buildQueue = buildQueue
                        .then(() => runDocaraBuild('local'))
                        .catch((error) => {
                            server.config.logger.error(error.message);
                        });
                }, 75);
            };
            const handleAuthorChange = (path) => {
                if (syncStaticAsset(path)) {
                    return;
                }
                if (isDocaraAuthorInput(path)) {
                    scheduleBuild();
                }
            };
            const writeHotFile = () => {
                const address = server.httpServer?.address();
                const protocol = server.config.server.https ? 'https' : 'http';
                const host = server.config.server.host === true || server.config.server.host === '0.0.0.0'
                    ? 'localhost'
                    : (server.config.server.host || 'localhost');
                const port = typeof address === 'object' && address ? address.port : server.config.server.port;

                writeFileSync('source/hot', `${protocol}://${host}:${port}`);
            };
            const cleanupHotFile = () => {
                rmSync('source/hot', { force: true });
            };
            const handleSigint = () => {
                cleanupHotFile();
                process.exit(130);
            };
            const handleSigterm = () => {
                cleanupHotFile();
                process.exit(143);
            };

            cleanupHotFile();
            process.once('exit', cleanupHotFile);
            process.prependOnceListener('SIGINT', handleSigint);
            process.prependOnceListener('SIGTERM', handleSigterm);

            server.middlewares.use((req, res, next) => {
                const filePath = resolveBuildFile(req.url);
                if (filePath === null) {
                    next();
                    return;
                }

                res.setHeader('Content-Type', buildFileContentType(filePath));
                res.setHeader('X-Content-Type-Options', 'nosniff');
                res.statusCode = 200;
                res.end(req.method === 'HEAD' ? undefined : readFileSync(filePath));
            });

            server.httpServer?.once('listening', () => {
                writeHotFile();
                rebuildStaticAssets();
                scheduleBuild();
            });

            server.httpServer?.once('close', () => {
                if (buildTimer !== null) {
                    clearTimeout(buildTimer);
                }
                cleanupHotFile();
                process.removeListener('exit', cleanupHotFile);
                process.removeListener('SIGINT', handleSigint);
                process.removeListener('SIGTERM', handleSigterm);
            });

            server.watcher.on('add', handleAuthorChange);
            server.watcher.on('change', handleAuthorChange);
            server.watcher.on('unlink', handleAuthorChange);

        },
        async closeBundle() {
            copyStaticAssets();
            await runDocaraBuild(buildEnv);
        },
    };
}

export default defineConfig({
    publicDir: false,
    server: {
        host: '0.0.0.0',
        port: 3000,
    },
    build: {
        manifest: 'manifest.json',
        outDir: 'source/assets/build',
        emptyOutDir: true,
        rollupOptions: {
            input: {
                main: 'source/_core/_assets/js/main.js',
                turbo: 'source/_core/_assets/js/turbo.js',
                styles: 'source/_core/_assets/css/main.scss',
            },
            output: {
                entryFileNames: 'js/[name].[hash].js',
                chunkFileNames: 'js/[name].[hash].js',
                assetFileNames: (assetInfo) => {
                    const name = assetInfo.names?.[0] ?? assetInfo.name ?? '';
                    const ext = name.split('.').pop();

                    if (ext === 'css') {
                        return 'css/[name].[hash][extname]';
                    }

                    if (['woff', 'woff2', 'ttf', 'otf', 'eot'].includes(ext)) {
                        return 'css/files/[name].[hash][extname]';
                    }

                    if (['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'avif'].includes(ext)) {
                        return 'img/[name].[hash][extname]';
                    }

                    return 'assets/[name].[hash][extname]';
                },
            },
        },
    },
    plugins: [
        docara(),
    ],
});
