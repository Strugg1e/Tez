import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'

const [helper] = process.argv.slice(2)
assert.ok(helper && path.isAbsolute(helper), 'Expected an absolute native helper path')
const root = fs.mkdtempSync('/private/tmp/tez-network-')
const socket = path.join(root, 'controller.sock')
const profiles = 'current: null\nitems: []\n'
fs.writeFileSync(path.join(root, 'profiles.yaml'), profiles)
fs.writeFileSync(path.join(root, 'mihomo.yaml'), 'mode: rule\ntun:\n  enable: false\n')
let mode = 'global'
let tun = true
let unavailable = false
let samples = 0
const requests = []
const server = http.createServer((request, response) => {
  requests.push(`${request.method} ${request.url}`)
  if (request.method !== 'GET') { response.writeHead(405).end(); return }
  let value
  switch (request.url) {
    case '/configs':
      if (unavailable) { response.writeHead(503).end(); return }
      value = { mode, tun: { enable: tun }, secret: 'fixture-private-value' }
      break
    case '/proxies': value = { proxies: {} }; break
    case '/providers/proxies': value = { providers: {} }; break
    case '/connections':
      samples += 1
      value = { uploadTotal: samples * 1024, downloadTotal: samples * 4096, memory: 1024,
        connections: ['connection-1', 'connection-2'].map(id => ({ id,
          metadata: { host: `${id}.example.test`, network: 'tcp', type: 'HTTP' },
          upload: samples * 512, download: samples * 2048, chains: ['DIRECT'], rule: 'MATCH' })) }
      break
    default: response.writeHead(404).end(); return
  }
  response.setHeader('Content-Type', 'application/json')
  response.end(JSON.stringify(value))
})
server.listen(socket)
await once(server, 'listening')
const child = spawn('/bin/bash', ['-o', 'pipefail', '-c',
  'cat | "$1" --stdio --attach --data-dir "$2" --socket-path "$3" | cat',
  'tez-isolated-observation', helper, root, socket], { stdio: ['pipe', 'pipe', 'pipe'] })
child.stderr.resume()
const exited = once(child, 'exit')
const queue = []
let buffer = ''
let wake = () => {}
child.stdout.setEncoding('utf8').on('data', chunk => {
  buffer += chunk
  let end
  while ((end = buffer.indexOf('\n')) >= 0) {
    queue.push(JSON.parse(buffer.slice(0, end)))
    buffer = buffer.slice(end + 1)
  }
  wake()
})
async function next() {
  const deadline = Date.now() + 15_000
  while (!queue.length) {
    assert.ok(Date.now() < deadline, 'Isolated helper response timed out')
    await new Promise(resolve => {
      const timer = setTimeout(resolve, Math.max(1, deadline - Date.now()))
      wake = () => { clearTimeout(timer); resolve() }
    })
  }
  return queue.shift()
}
let sequence = 0
async function request(command, params = {}) {
  const id = String(++sequence)
  child.stdin.write(JSON.stringify({ version: 1, kind: 'request', id, command, params }) + '\n')
  const reply = await next()
  assert.equal(reply.kind, 'response')
  assert.equal(reply.id, id)
  return reply
}
try {
  const hello = await next()
  assert.equal(hello.kind, 'hello')
  assert.ok(hello.capabilities.includes('native_get_activity'))
  assert.ok(!hello.capabilities.includes('native_close_connection'))
  assert.ok(!hello.capabilities.includes('native_core_restart'))
  for (const routing of ['rule', 'global', 'direct']) {
    for (const enabled of [true, false]) {
      mode = routing; tun = enabled
      const { result, error } = await request('native_get_snapshot')
      assert.ok(!error)
      assert.equal(result.core.state, 'ready')
      assert.equal(result.network.mode.value, routing)
      assert.equal(result.network.tun.enabled, enabled)
      assert.ok(!JSON.stringify(result).includes('fixture-private-value'))
    }
  }
  const params = { section: 'connections', query: '', offset: 0, limit: 128 }
  const first = (await request('native_get_activity', params)).result
  const second = (await request('native_get_activity', params)).result
  assert.equal(first.connections.total, 2)
  assert.equal(first.connections.items[0].closeable, true)
  assert.equal(second.connections.items[0].id, first.connections.items[0].id)
  assert.ok(second.connections.uploadTotal > first.connections.uploadTotal)
  assert.ok(!requests.includes('GET /rules') && !requests.includes('GET /providers/rules'))
  const refused = await request('native_close_connection', { id: 'connection-1' })
  assert.equal(refused.error.code, 'NATIVE_COMMAND_UNAVAILABLE')
  unavailable = true
  const failed = (await request('native_get_snapshot')).result.network
  assert.equal(failed.tun.state, 'unavailable')
  assert.equal(failed.tun.enabled, null)
  assert.equal(failed.mode.value, null)
  assert.equal(fs.readFileSync(path.join(root, 'profiles.yaml'), 'utf8'), profiles)
  assert.ok(requests.every(value => value.startsWith('GET ')))
  console.log('PASS: packaged helper observes 6 runtime mode/TUN combinations, changing connection counters, unknown-state fallback, scoped activity reads and read-only close refusal; no real controller or core was used')
} finally {
  child.stdin.end()
  const [code] = await exited
  server.closeAllConnections()
  await new Promise(resolve => server.close(resolve))
  fs.rmSync(root, { recursive: true, force: true })
  assert.equal(code, 0)
}
