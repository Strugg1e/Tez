import assert from 'node:assert/strict'
import { spawn, execFile } from 'node:child_process'
import { constants } from 'node:fs'
import fs from 'node:fs/promises'
import { createHash, randomBytes } from 'node:crypto'
import { once } from 'node:events'
import http from 'node:http'
import https from 'node:https'
import os from 'node:os'
import path from 'node:path'
import { promisify } from 'node:util'

const execute = promisify(execFile)
const [binary, candidate, flag] = process.argv.slice(2)
assert.equal(process.platform, 'darwin')
assert.equal(flag, '--run', 'Usage: test-native-subscriptions.mjs <check binary> <candidate app> --run')
assert.match(process.env.TEZ_PROTECTED_PID ?? '', /^[1-9]\d*$/, 'TEZ_PROTECTED_PID is required')
const digest = (value) => createHash('sha256').update(value).digest('hex')
const root = `/private/tmp/tez-subscription-check-${randomBytes(8).toString('hex')}`
const liveData = path.join(os.homedir(), 'Library/Application Support/app.tez.client')
const state = async () => {
  const values = {}
  for (const name of ['config.yaml', 'profiles.yaml', 'tez.yaml']) {
    values[name] = digest(await fs.readFile(path.join(liveData, name)))
  }
  for (const option of ['--proxy', '--dns']) {
    values[option] = digest((await execute('/usr/sbin/scutil', [option], { timeout: 5000 })).stdout)
  }
  values.core = digest((await execute('/bin/ps', ['-p', process.env.TEZ_PROTECTED_PID, '-o', 'lstart=,comm='], { timeout: 5000 })).stdout)
  assert.notEqual(values.core, digest(''), 'Current Core is not running')
  return values
}
const before = await state()
await fs.mkdir(root, { mode: 0o700 })
await fs.mkdir(path.join(root, 'home'), { mode: 0o700 })
await fs.mkdir(path.join(root, 'tmp'), { mode: 0o700 })
const app = path.join(root, 'Backend Check.app')
const helpers = path.join(app, 'Contents/Helpers')
await fs.mkdir(helpers, { recursive: true })
const copy = async (from, to) => fs.copyFile(from, to, constants.COPYFILE_FICLONE)
await copy(path.resolve(binary), path.join(helpers, 'tez-subscription-check'))
await copy(path.join(path.resolve(candidate), 'Contents/Helpers/verge-mihomo'), path.join(helpers, 'verge-mihomo'))
await copy(path.join(path.resolve(candidate), 'Contents/Info.plist'), path.join(app, 'Contents/Info.plist'))
await fs.cp(path.join(path.resolve(candidate), 'Contents/Resources'), path.join(app, 'Contents/Resources'), { recursive: true })
await execute('/usr/bin/codesign', ['--force', '--sign', '-', path.join(helpers, 'tez-subscription-check')])

let revision = 0
let downloads = 0
const davFiles = new Map()
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost')
  if (url.pathname.startsWith('/dav/')) {
    if (request.headers.authorization !== `Basic ${Buffer.from('fixture:fixture-secret').toString('base64')}`) {
      response.writeHead(401).end(); return
    }
    const name = decodeURIComponent(url.pathname.split('/').pop())
    if (request.method === 'MKCOL') { response.writeHead(405).end(); return }
    if (request.method === 'PROPFIND') {
      const folder = '<response><href>/dav/tez-backup/</href><propstat><status>HTTP/1.1 200 OK</status><prop><resourcetype><collection/></resourcetype></prop></propstat></response>'
      const files = [...davFiles.entries()].map(([file, bytes]) => `<response><href>/dav/tez-backup/${encodeURIComponent(file)}</href><propstat><status>HTTP/1.1 200 OK</status><prop><resourcetype/><getlastmodified>Wed, 01 Jan 2025 00:00:00 GMT</getlastmodified><getcontentlength>${bytes.length}</getcontentlength></prop></propstat></response>`).join('')
      response.writeHead(207, { 'Content-Type': 'application/xml' }).end(`<?xml version="1.0"?><multistatus xmlns="DAV:">${folder}${files}</multistatus>`); return
    }
    if (request.method === 'PUT') {
      const chunks = []; request.on('data', chunk => chunks.push(chunk)); request.on('end', () => { davFiles.set(name, Buffer.concat(chunks)); response.writeHead(201).end() }); return
    }
    if (request.method === 'GET' && name === 'oversize.zip') { response.writeHead(200, { 'Content-Length': '536870913' }).end(); return }
    if (request.method === 'GET' && davFiles.has(name)) { response.writeHead(200).end(davFiles.get(name)); return }
    if (request.method === 'DELETE' && davFiles.delete(name)) { response.writeHead(204).end(); return }
    response.writeHead(404).end(); return
  }
  if (request.method !== 'GET') { response.writeHead(405).end(); return }
  if (url.pathname === '/control') {
    if (url.searchParams.get('alias') === '1') {
      assert.ok(davFiles.size > 0)
      davFiles.set('backup #?%.zip', Buffer.from(davFiles.values().next().value))
    } else {
      assert.match(url.searchParams.get('revision'), /^[0-3]$/)
      revision = Number(url.searchParams.get('revision'))
    }
    response.setHeader('Content-Type', 'application/json')
    response.end(JSON.stringify({ downloads, revision }))
  } else if (url.pathname === '/subscription') {
    downloads++
    response.setHeader('Content-Type', 'text/yaml')
    response.setHeader('Subscription-Userinfo', `upload=${revision}; download=${revision}; total=1000; expire=0`)
    response.end(`proxies: []\nproxy-groups: []\nrules:\n  - DOMAIN,revision-${revision}.tez.invalid,DIRECT\n  - MATCH,DIRECT\n`)
  } else response.writeHead(404).end()
})
server.listen(0, '127.0.0.1')
await once(server, 'listening')
const port = server.address().port
const certificateConfig = path.join(root, 'certificate.cnf')
await fs.writeFile(certificateConfig, '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=127.0.0.1\n[v3]\nsubjectAltName=IP:127.0.0.1\n')
await execute('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', certificateConfig, '-keyout', path.join(root, 'key.pem'), '-out', path.join(root, 'certificate.pem')], { timeout: 15000 })
let untrustedRequests = 0
const untrustedServer = https.createServer({ key: await fs.readFile(path.join(root, 'key.pem')), cert: await fs.readFile(path.join(root, 'certificate.pem')) }, (_, response) => { untrustedRequests++; response.writeHead(200).end() })
untrustedServer.on('tlsClientError', () => {})
untrustedServer.listen(0, '127.0.0.1')
await once(untrustedServer, 'listening')
const untrustedPort = untrustedServer.address().port
const socket = path.join(root, 'core.sock')
const profile = `(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath ${JSON.stringify(root)}) (literal "/dev/null"))
(deny file-read-data (subpath ${JSON.stringify(liveData)}) (subpath "/Library/Application Support/clash-verge-service"))
(deny process-exec (literal "/usr/sbin/networksetup") (literal "/usr/bin/osascript") (literal "/bin/launchctl") (literal "/usr/bin/sudo"))
(deny mach-lookup (global-name "com.apple.SystemConfiguration.configd"))
(deny network*)
(allow network-outbound (remote tcp "localhost:${port}") (remote tcp "localhost:${untrustedPort}") (remote unix-socket (path-literal ${JSON.stringify(socket)})))
(allow network-bind (local unix-socket (path-literal ${JSON.stringify(socket)})))
(allow network-inbound (local unix-socket (path-literal ${JSON.stringify(socket)})))
`
const sandbox = path.join(root, 'sandbox.sb')
await fs.writeFile(sandbox, profile)
const child = spawn('/usr/bin/sandbox-exec', ['-f', sandbox, path.join(helpers, 'tez-subscription-check'), root, `http://127.0.0.1:${port}/subscription`, `https://127.0.0.1:${untrustedPort}/dav/`], {
  cwd: root,
  env: { ...process.env, HOME: path.join(root, 'home'), TMPDIR: `${root}/tmp/`, HTTP_PROXY: '', HTTPS_PROXY: '', ALL_PROXY: '', http_proxy: '', https_proxy: '', all_proxy: '', NO_PROXY: '*', no_proxy: '*' },
  detached: true,
  stdio: ['ignore', 'pipe', 'pipe'],
})
let diagnostic = ''
for (const stream of [child.stdout, child.stderr]) {
  stream.setEncoding('utf8').on('data', (chunk) => { diagnostic = (diagnostic + chunk).slice(-32768) })
}
const timeout = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL') } catch {} }, 90000)
try {
  const [code, signal] = await once(child, 'exit')
  try { diagnostic += await fs.readFile(path.join(root, 'failure.txt'), 'utf8') } catch (error) { if (error.code !== 'ENOENT') throw error }
  assert.equal(code, 0, `Production subscription check failed (${signal ?? code}): ${diagnostic}`)
  const report = JSON.parse(await fs.readFile(path.join(root, 'report.json'), 'utf8'))
  assert.equal(downloads, 4, 'Exactly four loopback fixture downloads expected')
  for (const key of ['activation', 'manualUpdate', 'defaultScheduler', 'disabledUpdate', 'reenabledUpdate', 'localBackups', 'backupTransfers', 'webdav', 'invalidTlsRejected']) assert.equal(report[key], true)
  assert.equal(untrustedRequests, 0, 'Credentials must not be sent to an untrusted HTTPS server')
  await assert.rejects(execute('/bin/ps', ['-p', String(report.fixtureCorePid), '-o', 'comm=']))
  console.log('PASS: production workspace activation, persisted profile selection, manual update, default scheduler, disable/re-enable and drain; four loopback downloads, no nodes or latency tests.')
  console.log('PASS: production local backup create, list, archive contents, traversal rejection and delete in the isolated HOME.')
  console.log('PASS: local import/export and local/WebDAV restore changed isolated profile data; pre-restore archive, credential preservation and loopback WebDAV upload/list/delete verified.')
  console.log('PASS: the untrusted HTTPS fixture was rejected before an HTTP request reached it.')
  console.log(`Coverage: ${report.coverage}`)
} finally {
  clearTimeout(timeout)
  try { process.kill(-child.pid, 'SIGKILL') } catch (error) { if (error.code !== 'ESRCH') throw error }
  await new Promise((resolve) => server.close(resolve))
  await new Promise((resolve) => untrustedServer.close(resolve))
  assert.deepEqual(await state(), before, 'Current Core, configuration, system proxy or DNS changed')
  console.log('PASS: current Core identity, configuration hashes, proxy and DNS unchanged. No application update performed.')
  console.log(`Acceptance artifacts: ${root}`)
}
