import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import path from 'node:path'

const [binary, confirmation, mode = '--attach'] = process.argv.slice(2)
assert.ok(binary && path.isAbsolute(binary) && confirmation === '--read-only' && ['--attach', '--inspect'].includes(mode),
  'Usage: test-native-live-read.mjs <absolute helper> --read-only [--attach|--inspect]')

// Attach owns no Core and has no write commands. Never log returned private data.
const child = spawn('/bin/bash', ['-o', 'pipefail', '-c', 'cat | "$1" --stdio "$2" | cat',
  'tez-live-read', binary, mode], { stdio: ['pipe', 'pipe', 'pipe'] })
child.stderr.resume()
let buffer = ''
const queue = []
let wake = () => {}
let failure
child.stdout.setEncoding('utf8').on('data', chunk => {
  buffer += chunk
  if (Buffer.byteLength(buffer) > 8 * 1024 * 1024) failure = new Error('Frame exceeds size limit')
  let end
  while (!failure && (end = buffer.indexOf('\n')) >= 0) {
    try { queue.push(JSON.parse(buffer.slice(0, end))) }
    catch { failure = new Error('Invalid frame') }
    buffer = buffer.slice(end + 1)
  }
  wake()
})
child.on('error', () => { failure = new Error('Attach helper failed to launch'); wake() })
child.on('exit', () => { if (!queue.length) failure ??= new Error('Attach helper exited before response'); wake() })
const exited = once(child, 'exit')
async function next() {
  const deadline = Date.now() + 15_000
  while (!queue.length && !failure) {
    const left = deadline - Date.now()
    if (left <= 0) throw new Error('Attach response deadline exceeded')
    await new Promise(resolve => {
      const timer = setTimeout(resolve, left)
      wake = () => { clearTimeout(timer); resolve() }
    })
  }
  if (failure) throw failure
  return queue.shift()
}
async function request(id, command) {
  child.stdin.write(`${JSON.stringify({ version: 1, kind: 'request', id, command, params: {} })}\n`)
  const reply = await next()
  assert.equal(reply.kind, 'response')
  assert.equal(reply.id, id)
  assert.ok(!reply.error, `${command}: request failed`)
  return reply.result
}
let accepted = false
let summary
try {
  const hello = await next()
  assert.equal(hello.kind, 'hello')
  for (const required of ['native_get_snapshot', 'native_get_activity']) assert.ok(hello.capabilities.includes(required))
  for (const forbidden of ['native_core_stop', 'native_patch_settings', 'native_select_route', 'native_update_subscription']) {
    assert.ok(!hello.capabilities.includes(forbidden), 'Attach advertised a write capability')
  }
  const snapshot = await request('read-snapshot', 'native_get_snapshot')
  assert.equal(snapshot.profiles.state, 'ready')
  assert.equal(snapshot.core.state, 'ready')
  assert.ok(snapshot.proxyView && Array.isArray(snapshot.proxyView.groups))
  let detection
  if (mode === '--inspect') {
    assert.ok(hello.capabilities.includes('native_inspect_core'))
    assert.ok(hello.capabilities.includes('native_continuous_session'))
    assert.ok(!hello.capabilities.includes('native_prepare_shutdown'))
    assert.equal(snapshot.core.lifecycle.state, 'runningReadOnly', `Discovery reason: ${snapshot.core.lifecycle.reason}`)
    assert.equal(snapshot.core.lifecycle.canStart, false)
    const inspection = await request('read-inspection', 'native_inspect_core')
    assert.equal(inspection.corePid, snapshot.core.lifecycle.corePid)
    assert.equal(inspection.serviceGeneration, snapshot.core.lifecycle.serviceGeneration)
    assert.ok(inspection.processes.some(process => process.pid === inspection.corePid))
    assert.ok(!JSON.stringify(inspection).includes('token'))
    detection = { state: inspection.state, source: inspection.source, pid: inspection.corePid,
      serviceGeneration: inspection.serviceGeneration, processes: inspection.processes.length }
  }
  const activity = await request('read-activity', 'native_get_activity')
  assert.equal(activity.connections.state, 'ready')
  let network
  if (snapshot.network) {
    for (const key of ['systemProxy', 'pac', 'tun']) {
      const state = snapshot.network[key]
      assert.ok(['ready', 'unavailable'].includes(state.state))
      assert.equal(state.state === 'ready', typeof state.enabled === 'boolean')
    }
    const routing = snapshot.network.mode
    assert.ok(['ready', 'unavailable'].includes(routing.state))
    if (routing.state === 'ready') assert.ok(['rule', 'global', 'direct'].includes(routing.value))
    else assert.equal(routing.value, null)
    network = snapshot.network
  }
  summary = { result: 'PASS', profiles: snapshot.profiles.items.length,
    groups: snapshot.proxyView.groups.length, nodes: Object.keys(snapshot.proxyView.records).length,
    activeConnections: activity.connections.total,
    rulesState: activity.rules.state, providersState: activity.providers.state, detection, network }
  accepted = true
} finally {
  child.stdin.end()
  const [code, signal] = await exited
  if (accepted) {
    assert.equal(code, 0, 'Attach helper did not exit cleanly')
    assert.equal(signal, null)
  }
}
console.log(JSON.stringify(summary))
