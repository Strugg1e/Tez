import assert from 'node:assert/strict'
import { spawn, execFile } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { EventEmitter, once } from 'node:events'
import fs from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { promisify } from 'node:util'
import * as yaml from 'js-yaml'
import WebSocket from 'ws'

const execute = promisify(execFile)
const binary = process.argv[2]
const preparedShutdown = process.argv[4] === '--prepare'
if (!binary || process.argv[3] !== '--run' || (process.argv.length !== 4 && !(process.argv.length === 5 && preparedShutdown))) {
  throw new Error('Usage: test-native-isolated.mjs <packaged tez-native-host> --run [--prepare]')
}
assert.equal(process.platform, 'darwin', 'This acceptance check is macOS-only')
const helper = path.resolve(binary)
assert.ok(
  helper.endsWith('.app/Contents/Helpers/tez-native-host'),
  'Acceptance requires the independently packaged helper',
)
assert.equal(await fs.realpath(helper), helper, 'Packaged helper must not traverse symlinks')
assert.ok((await fs.lstat(helper)).isFile(), 'Packaged helper must be an ordinary file')

const root = `/private/tmp/tez-native-isolated-${randomBytes(12).toString('hex')}`
const profilePath = path.join(root, 'profile.yaml')
const selectionPath = path.join(root, 'selection.json')
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex')
const protectedPid = process.env.TEZ_PROTECTED_PID
if (protectedPid !== undefined) {
  assert.match(protectedPid, /^[1-9]\d*$/, 'TEZ_PROTECTED_PID must be a positive process ID')
  assert.ok(Number.isSafeInteger(Number(protectedPid)) && Number(protectedPid) > 1)
}

async function systemDigest(flag) {
  const { stdout } = await execute('/usr/sbin/scutil', [flag], {
    timeout: 5000,
    maxBuffer: 1024 * 1024,
  })
  return digest(stdout)
}

async function protectedState() {
  const directory = path.join(os.homedir(), 'Library/Application Support/app.tez.client')
  const files = {}
  for (const name of ['profiles.yaml', 'tez.yaml', 'config.yaml']) {
    try {
      files[name] = digest(await fs.readFile(path.join(directory, name)))
    } catch (error) {
      if (error.code !== 'ENOENT') throw new Error('Cannot establish existing configuration baseline')
      files[name] = null
    }
  }
  let processIdentity = null
  if (protectedPid !== undefined) {
    const { stdout } = await execute('/bin/ps', ['-p', protectedPid, '-o', 'lstart=', '-o', 'comm='], {
      timeout: 5000,
      maxBuffer: 16 * 1024,
    })
    assert.ok(stdout.trim(), 'Protected core process is not running')
    processIdentity = digest(stdout)
  }
  return {
    files,
    proxy: await systemDigest('--proxy'),
    dns: await systemDigest('--dns'),
    processIdentity,
  }
}

const baseline = await protectedState()
const child = spawn(
  '/bin/bash',
  [
    '-o', 'pipefail', '-c',
    'cat | "$1" --stdio --isolated "$2" | cat',
    'tez-isolated-check', helper, root,
  ],
  { stdio: ['pipe', 'pipe', 'pipe'] },
)
const frames = []
const signal = new EventEmitter()
let buffered = ''
let protocolError
let exitResult
let requestCount = 0
const seenPids = new Set()
const exit = once(child, 'exit').then((result) => {
  exitResult = result
  signal.emit('frame')
  return result
}, () => {
  exitResult = [null, 'spawn-error']
  signal.emit('frame')
  return exitResult
})
child.on('error', () => {
  protocolError = new Error('Could not launch isolated helper')
  signal.emit('frame')
})
child.stdin.on('error', () => {})
child.stdout.setEncoding('utf8').on('data', (chunk) => {
  buffered += chunk
  if (Buffer.byteLength(buffered) > 8 * 1024 * 1024) {
    protocolError = new Error('Isolated helper frame exceeded the protocol limit')
  }
  let end
  while (!protocolError && (end = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, end)
    buffered = buffered.slice(end + 1)
    try {
      frames.push(JSON.parse(line))
    } catch {
      protocolError = new Error('Isolated helper emitted an invalid frame')
    }
  }
  signal.emit('frame')
})
// Diagnostic content is intentionally not retained: acceptance never prints config data.
child.stderr.resume()

function waitFor(predicate) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer)
      signal.off('frame', inspect)
    }
    const inspect = () => {
      const found = frames.find(predicate)
      if (protocolError || found || exitResult) {
        cleanup()
        if (protocolError) reject(protocolError)
        else if (found) resolve(found)
        else reject(new Error('Isolated helper exited before its response'))
      }
    }
    const timer = setTimeout(() => {
      cleanup()
      reject(new Error('Isolated request deadline exceeded'))
    }, 30_000)
    signal.on('frame', inspect)
    inspect()
  })
}

async function request(command, params = {}) {
  const id = `isolated-${++requestCount}`
  child.stdin.write(`${JSON.stringify({ version: 1, kind: 'request', id, command, params })}\n`)
  return waitFor((frame) => frame.kind === 'response' && frame.id === id)
}

async function result(command, params = {}) {
  const response = await request(command, params)
  assert.ok(!response.error, `${command} unexpectedly failed`)
  return response.result
}

function runtime(value, running) {
  assert.equal(value.isolated, true)
  assert.equal(value.running, running)
  assert.equal(value.dataDir, root)
  assert.equal(value.socketPath, path.join(root, 'controller.sock'))
  if (running) {
    assert.ok(Number.isSafeInteger(value.pid) && value.pid > 1)
    seenPids.add(value.pid)
  } else {
    assert.equal(value.pid, null)
  }
  return value.pid
}

function assertExited(pid) {
  assert.throws(
    () => process.kill(pid, 0),
    (error) => error.code === 'ESRCH',
    'The isolated core must exit before its stop is acknowledged',
  )
}

async function unchangedProtectedState() {
  const current = await protectedState()
  assert.deepEqual(current.files, baseline.files, 'Existing proxy configuration files changed')
  assert.equal(current.proxy, baseline.proxy, 'Existing system proxy settings changed')
  assert.equal(current.dns, baseline.dns, 'Existing system DNS state changed')
  assert.equal(current.processIdentity, baseline.processIdentity, 'Protected core process changed')
}

function controller(route) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath: path.join(root, 'controller.sock'), path: route, method: 'GET',
    }, (response) => {
      let data = ''
      response.setEncoding('utf8').on('data', (chunk) => {
        data += chunk
        if (Buffer.byteLength(data) > 1024 * 1024) request.destroy(new Error('Fixture response exceeded limit'))
      })
      response.on('error', reject)
      response.on('end', () => {
        if (response.statusCode !== 200) { reject(new Error('Fixture controller read failed')); return }
        try { resolve(JSON.parse(data)) } catch { reject(new Error('Fixture controller JSON is invalid')) }
      })
    })
    request.on('error', reject)
    request.setTimeout(5000, () => request.destroy(new Error('Fixture controller read timed out')))
    request.end()
  })
}

async function assertNoNetworkEndpoints(pid) {
  process.kill(pid, 0)
  try {
    const { stdout } = await execute('/usr/sbin/lsof', ['-nP', '-a', '-p', String(pid), '-i'], {
      timeout: 5000,
      maxBuffer: 1024 * 1024,
    })
    assert.equal(stdout.trim(), '', 'Fixture core opened a TCP or UDP endpoint')
  } catch (error) {
    if (error.code !== 1 || error.stdout?.trim() || error.stderr?.trim()) {
      throw new Error('Fixture network endpoint inspection failed', { cause: error })
    }
  }
  process.kill(pid, 0)
}

async function assertNetworkDisabled(pid) {
  const config = await controller('/configs')
  for (const port of ['port', 'socks-port', 'redir-port', 'tproxy-port', 'mixed-port']) {
    assert.equal(config[port], 0, 'Fixture unexpectedly enabled a proxy listener')
  }
  assert.equal(config['allow-lan'], false)
  assert.equal(config.tun?.enable, false)
  const runtimeConfig = yaml.load(await fs.readFile(path.join(root, 'runtime.yaml'), 'utf8'))
  assert.equal(runtimeConfig.dns?.enable, false)
  assert.equal(runtimeConfig.tun?.enable, false)
  assert.equal(runtimeConfig['external-controller'], '')
  await assertNoNetworkEndpoints(pid)
  return config
}

async function endSession() {
  child.stdin.end()
  let timer
  try {
    const response = await Promise.race([
      exit,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error('Isolated helper did not confirm safe EOF shutdown')),
          20_000,
        )
      }),
    ])
    return response
  } finally {
    clearTimeout(timer)
  }
}

let accepted = false
let logStream
try {
  const hello = await waitFor((frame) => frame.kind === 'hello')
  for (const command of [
    'native_read_profile', 'native_save_profile', 'native_select_route',
    'native_core_start', 'native_core_stop', 'native_core_restart', 'native_get_runtime',
  ]) assert.ok(hello.capabilities.includes(command), `Missing isolated capability: ${command}`)
  for (const command of ['native_get_settings', 'native_patch_settings', 'native_set_mode', 'native_get_dns', 'native_save_dns', 'native_get_logs',
    'native_import_subscription', 'native_subscription_details', 'native_patch_subscription', 'native_update_subscription', 'native_activate_profile', 'native_test_latency']) {
    assert.ok(hello.capabilities.includes(command), `Missing isolated workspace capability: ${command}`)
  }
  for (const command of ['native_set_dns_override']) {
    assert.ok(!hello.capabilities.includes(command), `Unsafe or unimplemented capability was advertised: ${command}`)
  }
  const defaults = await result('native_get_settings')
  assert.equal(defaults.mode, 'rule')
  assert.equal(defaults.values.enable_system_proxy, false)
  assert.equal((await request('native_patch_settings', { values: { enable_system_proxy: true } })).error?.code, 'ISOLATED_NETWORK_FORBIDDEN')
  assert.equal((await request('native_patch_settings', { values: { verge_mixed_port: 0 } })).error?.code, 'INVALID_PARAMS')
  assert.equal((await result('native_patch_settings', { values: { default_latency_timeout: 7000 } })).saved, true)
  assert.equal((await result('native_get_settings')).values.default_latency_timeout, 7000)
  assert.equal((await result('native_get_dns')).enabled, false)
  assert.equal((await result('native_save_dns', { content: 'dns:\n  enable: false\n' })).applied, false)
  assert.equal((await request('native_save_dns', { content: 'not: [valid' })).error?.code, 'INVALID_PARAMS')
  const fixtureRuntime = await result('native_get_runtime')
  runtime(fixtureRuntime, false)
  assert.match(fixtureRuntime.fixtureSubscriptionURL, /^http:\/\/127\.0\.0\.1:\d+\/subscription$/)
  const importParams = { url: fixtureRuntime.fixtureSubscriptionURL, name: 'Fixture subscription', interval: 1440, auto_update: false, with_proxy: false }
  assert.equal((await request('native_import_subscription', { ...importParams, url: 'http://example.com/subscription' })).error?.code, 'ISOLATED_NETWORK_FORBIDDEN')
  assert.equal((await request('native_import_subscription', { ...importParams, with_proxy: true })).error?.code, 'ISOLATED_NETWORK_FORBIDDEN')
  const imported = await result('native_import_subscription', importParams)
  assert.match(imported.uid, /^[A-Za-z0-9_-]+$/)
  const detail = await result('native_subscription_details', { uid: imported.uid })
  assert.equal(detail.url, fixtureRuntime.fixtureSubscriptionURL)
  assert.equal(detail.autoUpdate, false)
  assert.equal(detail.withProxy, false)
  assert.equal(detail.nextUpdate, null, 'Isolated adapter must not claim a running scheduler')
  assert.equal(detail.usage.download, 2)
  const patch = { uid: imported.uid, name: 'Changed fixture', interval: 2880, auto_update: true, with_proxy: false }
  assert.equal((await result('native_patch_subscription', patch)).saved, true)
  assert.equal((await result('native_subscription_details', { uid: imported.uid })).interval, 2880)
  assert.equal((await request('native_patch_subscription', { ...patch, with_proxy: true })).error?.code, 'ISOLATED_NETWORK_FORBIDDEN')
  const fixtureFile = path.join(root, 'profiles', `${imported.uid}.yaml`)
  const downloaded = await fs.readFile(fixtureFile, 'utf8')
  assert.match(downloaded, /log-level: info/)
  await fs.writeFile(path.join(root, 'subscription-source.yaml'), downloaded.replace('log-level: info', 'log-level: warning'))
  assert.equal((await result('native_update_subscription', { uid: imported.uid })).updated, true)
  assert.match(await fs.readFile(fixtureFile, 'utf8'), /log-level: warning/)
  const initial = await result('native_read_profile', { uid: 'fixture' })
  assert.equal(initial.uid, 'fixture')
  assert.match(initial.revision, /^[a-f0-9]{64}$/)
  assert.equal(initial.revision, digest(initial.content))
  assert.equal(await fs.readFile(profilePath, 'utf8'), initial.content)
  assert.match(initial.content, /log-level: info/)
  const edited = initial.content.replace('log-level: info', 'log-level: warning')
  assert.notEqual(edited, initial.content)
  const saved = await result('native_save_profile', {
    uid: 'fixture', content: edited, expectedRevision: initial.revision,
  })
  assert.equal(saved.saved, true)
  assert.equal(saved.revision, digest(edited))
  assert.equal(await fs.readFile(profilePath, 'utf8'), edited)
  const conflict = await request('native_save_profile', {
    uid: 'fixture', content: initial.content, expectedRevision: initial.revision,
  })
  assert.equal(conflict.error?.code, 'PROFILE_REVISION_CONFLICT')
  assert.equal(await fs.readFile(profilePath, 'utf8'), edited)
  for (const unsafe of [
    'not: [valid',
    edited.replace('log-level: warning', 'log-level: not-a-level'),
    `${edited}\nmixed-port: 7890\n`,
    `${edited}\ntun:\n  enable: true\n`,
  ]) {
    const rejected = await request('native_save_profile', {
      uid: 'fixture', content: unsafe, expectedRevision: saved.revision,
    })
    assert.ok(rejected.error || rejected.result?.saved === false, 'Unsafe configuration was accepted')
    assert.equal(await fs.readFile(profilePath, 'utf8'), edited)
  }
  const firstPid = runtime(await result('native_core_start'), true)
  assert.equal(runtime(await result('native_core_start'), true), firstPid)
  assert.equal((await assertNetworkDisabled(firstPid))['log-level'], 'warning')
  const logs = await result('native_get_logs', { limit: 100, level: 'all', query: '' })
  assert.ok(Array.isArray(logs.lines) && logs.lines.length > 0, 'No real isolated Core logs were read')
  assert.equal(logs.streaming, true, 'Real Core log stream was not connected')
  if (process.env.TEZ_SKIP_LATENCY !== '1') {
    const latencyUrl = fixtureRuntime.fixtureSubscriptionURL.replace('/subscription', '/generate_204')
    assert.equal((await request('native_test_latency', { names: ['DIRECT'], url: 'https://example.com', timeout: 1000 })).error?.code, 'ISOLATED_NETWORK_FORBIDDEN')
    assert.equal((await request('native_test_latency', { names: ['REJECT'], url: latencyUrl, timeout: 1000 })).error?.code, 'ISOLATED_NETWORK_FORBIDDEN')
    const latency = await result('native_test_latency', { names: ['DIRECT'], url: latencyUrl, timeout: 1000 })
    assert.equal(latency.results[0].name, 'DIRECT')
    assert.equal(latency.results[0].error, undefined)
    assert.ok(Number.isInteger(latency.results[0].delay))
    assert.equal((await controller('/proxies')).proxies.Fixture.now, 'DIRECT')
  }
  logStream = new WebSocket(`ws+unix://${path.join(root, 'controller.sock')}:/logs?level=debug`)
  const streamedLogs = []
  logStream.on('message', data => {
    try { const item = JSON.parse(data.toString()); if (typeof item.payload === 'string') streamedLogs.push(item.payload) } catch {}
  })
  await Promise.race([once(logStream, 'open'), new Promise((_, reject) => setTimeout(() => reject(new Error('Fixture log stream connection timed out')), 5000))])
  const activeContent = edited.replace('log-level: warning', 'log-level: debug')
  const activeSave = await result('native_save_profile', {
    uid: 'fixture', content: activeContent, expectedRevision: saved.revision,
  })
  assert.equal(activeSave.saved, true)
  assert.equal(activeSave.revision, digest(activeContent))
  assert.equal(await fs.readFile(profilePath, 'utf8'), activeContent)
  assert.equal((await assertNetworkDisabled(firstPid))['log-level'], 'debug')
  for (let i = 0; i < 30 && streamedLogs.length === 0; i++) await new Promise(resolve => setTimeout(resolve, 100))
  assert.ok(streamedLogs.length > 0, 'Fixture WebSocket did not emit logs during reload')
  const polled = await result('native_get_logs', { limit: 1000, level: 'all', query: '' })
  assert.equal(polled.streaming, true, 'Core log stream stopped during reload')
  const matched = streamedLogs.filter(message => polled.lines.some(line => line.includes(message))).length
  assert.equal(matched, streamedLogs.length, 'Fixture WebSocket contains messages missing from polled Core stdout')
  logStream.terminate()
  logStream = undefined
  const invalidSelection = await request('native_select_route', { group: 'Fixture', name: 'UNKNOWN' })
  assert.ok(invalidSelection.error, 'Unknown route member was accepted')
  assert.equal((await controller('/proxies')).proxies.Fixture.now, 'DIRECT')
  const selected = await result('native_select_route', { group: 'Fixture', name: 'REJECT' })
  assert.equal(selected.applied, true)
  assert.equal(selected.persisted, true)
  assert.equal(selected.selected, 'REJECT')
  assert.equal((await controller('/proxies')).proxies.Fixture.now, 'REJECT')
  const persisted = await fs.readFile(selectionPath, 'utf8')
  assert.equal(JSON.parse(persisted), 'REJECT', 'Selection was not written to isolated storage')
  const selectedContent = activeContent.replace('log-level: debug', 'log-level: warning')
  const selectedSave = await result('native_save_profile', {
    uid: 'fixture', content: selectedContent, expectedRevision: activeSave.revision,
  })
  assert.equal(selectedSave.saved, true)
  assert.equal(selectedSave.revision, digest(selectedContent))
  assert.equal((await assertNetworkDisabled(firstPid))['log-level'], 'warning')
  assert.equal((await controller('/proxies')).proxies.Fixture.now, 'REJECT', 'Live reload lost the selected route')
  assert.equal(await fs.readFile(selectionPath, 'utf8'), persisted)
  const safeSubscription = await fs.readFile(fixtureFile, 'utf8')
  await fs.writeFile(fixtureFile, `${safeSubscription}\nmixed-port: 7890\n`)
  assert.equal((await request('native_activate_profile', { uid: imported.uid })).error?.code, 'ISOLATED_CONFIG_REJECTED')
  await fs.writeFile(fixtureFile, safeSubscription)
  assert.equal((await result('native_activate_profile', { uid: imported.uid })).applied, true)
  assert.equal((await result('native_get_snapshot')).profiles.current, imported.uid)
  assert.equal((await controller('/configs'))['log-level'], 'warning')
  assert.equal((await controller('/proxies')).proxies.Fixture.now, 'REJECT')
  assert.equal((await result('native_set_mode', { mode: 'global' })).applied, true)
  assert.equal((await controller('/configs')).mode, 'global')
  assert.equal((await result('native_set_mode', { mode: 'rule' })).applied, true)
  assert.equal((await controller('/configs')).mode, 'rule')
  assert.equal((await controller('/proxies')).proxies.Fixture.now, 'REJECT')
  const restartedPid = runtime(await result('native_core_restart'), true)
  assert.notEqual(restartedPid, firstPid)
  assertExited(firstPid)
  const snapshot = await result('native_get_snapshot')
  const group = snapshot.proxyView?.groups?.find((item) => item.name === 'Fixture')
  assert.equal(group?.now, 'REJECT', 'Restart did not restore the isolated selection')
  assert.equal((await controller('/proxies')).proxies.Fixture.now, 'REJECT')
  assert.equal((await assertNetworkDisabled(restartedPid))['log-level'], 'warning')
  assert.equal(await fs.readFile(selectionPath, 'utf8'), persisted)
  runtime(await result('native_core_stop'), false)
  assertExited(restartedPid)
  runtime(await result('native_core_stop'), false)
  const eofPid = runtime(await result('native_core_start'), true)
  await assertNetworkDisabled(eofPid)
  if (preparedShutdown) {
    assert.ok(hello.capabilities.includes('native_prepare_shutdown'))
    const invalid = await request('native_prepare_shutdown', { unexpected: true })
    assert.equal(invalid.error?.code, 'INVALID_PARAMS')
    assert.equal(runtime(await result('native_get_runtime'), true), eofPid)
    assert.equal((await result('native_prepare_shutdown')).safeToExit, true)
    assertExited(eofPid)
    runtime(await result('native_get_runtime'), false)
    assert.equal((await request('native_core_start')).error?.code, 'NATIVE_SHUTDOWN_IN_PROGRESS')
    assert.equal((await result('native_prepare_shutdown')).safeToExit, true)
  }
  const [code, terminationSignal] = await endSession()
  assert.equal(code, 0, 'Isolated helper failed EOF shutdown')
  assert.equal(terminationSignal, null)
  assertExited(eofPid)
  for (const pid of seenPids) assertExited(pid)
  assert.equal(buffered, '')
  await unchangedProtectedState()
  accepted = true
  if (preparedShutdown) console.log('PASS: real isolated core stopped before EOF; shutdown preparation was repeatable and rejected new work.')
  console.log('PASS: isolated real-core profile CAS, rejected writes, route persistence, restart, stop and EOF cleanup; existing config hashes, proxy/DNS digests and optional protected core identity unchanged. Production CoreManager takeover is not covered.')
  console.log('PASS: isolated safe settings persistence, rejected network settings, DNS draft validation, real Core mode changes and Core log reads. These use an isolated adapter, not managed network effects.')
  console.log('PASS: isolated subscription import, edit, update and safe activation through an owned loopback HTTP source; unsafe configurations, external sources and proxy downloads were rejected.')
  if (process.env.TEZ_SKIP_LATENCY !== '1') console.log('PASS: real isolated Mihomo latency probe to an owned loopback endpoint; external destinations were rejected and selection was unchanged. This fixture probes DIRECT, which production UI excludes.')
  console.log('PASS: isolated WebSocket log messages during a configuration reload matched the polled Core log lines; this does not cover sustained traffic or service-mode retention.')
} finally {
  if (logStream) logStream.terminate()
  if (!exitResult) {
    try { await endSession() } catch {
      // An unresolved owner must not be force-killed or have its files removed.
      console.error(`Unresolved isolated shutdown; preserve ${root} for inspection.`)
      child.unref()
      child.stdout.destroy()
      child.stderr.destroy()
    }
  }
  await unchangedProtectedState()
  if (exitResult) {
    for (const pid of seenPids) assertExited(pid)
    await fs.rm(root, { recursive: true, force: true })
  }
  if (!accepted) console.error('Isolated acceptance did not pass.')
}
