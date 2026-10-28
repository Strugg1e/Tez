import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { EventEmitter, once } from 'node:events'
import fs from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

const binary = process.argv[2]
if (!binary) throw new Error('Usage: test-native-attach.mjs <tez-native-host>')
const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'tez-attach-check-'))
const socket = path.join(directory, 'controller.sock')
const profilePath = path.join(directory, 'profiles.yaml')
const yaml = (name) =>
  `current: local-check\nitems:\n  - uid: local-check\n    name: ${name}\n    type: remote\n    updated: 1700000000\n    url: https://secret.invalid/private-token\n`
await fs.writeFile(profilePath, yaml('Initial profile'))
let chosen = 'Hong Kong test'
let reads = 0
let writes = 0
let rulesFail = false
const proxy = (name, type, other = {}) => ({
  name,
  type,
  alive: true,
  udp: true,
  uot: false,
  xudp: false,
  tfo: false,
  mptcp: false,
  smux: false,
  interface: '',
  'dialer-proxy': '',
  'routing-mark': 0,
  'provider-name': '',
  extra: {},
  history: [{ time: '2026-10-27T00:00:00Z', delay: 28 }],
  ...other,
})
const server = http.createServer((request, response) => {
  if (request.method !== 'GET') {
    writes++
    response.writeHead(405).end()
    return
  }
  reads++
  if (request.url === '/rules' && rulesFail) {
    response.writeHead(503).end('private-controller-token')
    return
  }
  const data =
    request.url === '/connections'
      ? {
          uploadTotal: 100,
          downloadTotal: 200,
          memory: 300,
          connections: [{
            id: 'connection-1',
            metadata: {
              host: 'example.test', destinationIP: '127.0.0.1', destinationPort: '443',
              process: '/private/application/Test.app', processPath: '/private/application/secret',
              sourceIP: 'private-source', inboundUser: 'private-user',
            },
            upload: 10, download: 20, chains: ['Daily', chosen], rule: 'Domain',
            rulePayload: 'private-rule-payload',
          }],
        }
      : request.url === '/rules'
      ? { rules: [
          { index: 0, type: 'ProcessPath', payload: '/private/application/secret', proxy: 'DIRECT' },
          ...Array.from({ length: 310 }, (_, offset) => ({
            index: offset + 1, type: 'DomainSuffix', payload: `rule-${offset + 1}.test`, proxy: 'DIRECT',
          })),
        ] }
      : request.url === '/providers/rules'
      ? { providers: { safe: { name: 'safe', ruleCount: 42, url: 'https://secret.invalid/private-token', path: '/private/rules' } } }
      : request.url === '/providers/proxies'
      ? { providers: {} }
      : {
          proxies: {
            GLOBAL: proxy('GLOBAL', 'Selector', {
              all: ['Daily'],
              now: 'Daily',
            }),
            Daily: proxy('Daily', 'Selector', {
              all: ['Hong Kong test', 'Tokyo test'],
              now: chosen,
            }),
            'Hong Kong test': proxy('Hong Kong test', 'Shadowsocks'),
            'Tokyo test': proxy('Tokyo test', 'Trojan'),
          },
        }
  response
    .writeHead(200, { 'content-type': 'application/json' })
    .end(JSON.stringify(data))
})
try {
  server.listen(socket)
  await once(server, 'listening')
} catch (error) {
  await fs.rm(directory, { recursive: true, force: true })
  throw error
}
const child = spawn(
  '/bin/bash',
  [
    '-o',
    'pipefail',
    '-c',
    'cat | "$1" --stdio --attach --data-dir "$2" --socket-path "$3" | cat',
    'tez-attach-check',
    path.resolve(binary),
    directory,
    socket,
  ],
  { stdio: ['pipe', 'pipe', 'pipe'] },
)
const frames = []
const signal = new EventEmitter()
let buffered = ''
let diagnostics = ''
let parseError
const exited = once(child, 'exit')
child.stdout.setEncoding('utf8').on('data', (chunk) => {
  buffered += chunk
  let end
  while ((end = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, end)
    buffered = buffered.slice(end + 1)
    try {
      frames.push(JSON.parse(line))
    } catch (error) {
      parseError = error
    }
    signal.emit('frame')
  }
})
child.stderr.setEncoding('utf8').on('data', (chunk) => {
  diagnostics = (diagnostics + chunk).slice(-1000)
})
function waitFor(predicate) {
  const existing = frames.find(predicate)
  if (existing) return Promise.resolve(existing)
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup()
      reject(new Error(`Attach deadline exceeded. ${diagnostics}`))
    }, 10_000)
    const inspect = () => {
      if (parseError) {
        cleanup()
        reject(parseError)
        return
      }
      const frame = frames.find(predicate)
      if (frame) {
        cleanup()
        resolve(frame)
      }
    }
    const cleanup = () => {
      clearTimeout(timer)
      signal.off('frame', inspect)
    }
    signal.on('frame', inspect)
  })
}
async function request(id, command, params = {}) {
  child.stdin.write(
    `${JSON.stringify({ version: 1, kind: 'request', id, command, params })}\n`,
  )
  return waitFor((frame) => frame.kind === 'response' && frame.id === id)
}
try {
  const hello = await waitFor((frame) => frame.kind === 'hello')
  assert.ok(hello.capabilities.includes('native_subscribe'))
  assert.ok(hello.capabilities.includes('native_get_activity'))
  const activity = (await request('activity-1', 'native_get_activity')).result
  assert.equal(activity.schemaVersion, 1)
  assert.equal(activity.connections.state, 'ready')
  assert.equal(activity.connections.total, 1)
  assert.equal(activity.connections.uploadTotal, 100)
  assert.equal(activity.connections.items[0].process, 'Test.app')
  assert.equal(activity.connections.items[0].destination, '127.0.0.1:443')
  assert.equal(activity.rules.items[0].payload, '[hidden]')
  assert.equal(activity.rules.total, 311)
  assert.equal(activity.rules.matched, 311)
  assert.equal(activity.rules.offset, 0)
  assert.equal(activity.rules.nextOffset, 256)
  assert.equal(activity.providers.items[0].ruleCount, 42)
  assert.ok(!JSON.stringify(activity).includes('private'))
  const nextPage = (await request('activity-rules-next', 'native_get_activity', {
    section: 'rules', offset: 256, limit: 55,
  })).result.rules
  assert.equal(nextPage.items.length, 55)
  assert.equal(nextPage.items[0].index, 256)
  assert.equal(nextPage.nextOffset, null)
  const found = (await request('activity-rules-search', 'native_get_activity', {
    section: 'rules', query: 'RULE-309.TEST', offset: 0, limit: 256,
  })).result
  assert.equal(found.rules.total, 311)
  assert.equal(found.rules.matched, 1)
  assert.equal(found.rules.items[0].index, 309)
  assert.equal(found.connections.matched, 1)
  assert.equal(found.connections.offset, 0)
  const pastEnd = (await request('activity-rules-past-end', 'native_get_activity', {
    section: 'rules', offset: 1000000,
  })).result.rules
  assert.deepEqual(pastEnd.items, [])
  assert.equal(pastEnd.nextOffset, null)
  const hiddenSearch = (await request('activity-hidden-search', 'native_get_activity', {
    section: 'rules', query: '/private/application',
  })).result.rules
  assert.equal(hiddenSearch.matched, 0)
  const beforeInvalid = reads
  for (const [index, params] of [
    { section: 'rules', offset: -1 }, { section: 'rules', limit: 257 },
    { section: 'rules', query: '测'.repeat(86) }, { query: 'rule' }, { section: 'rules', url: '/configs' },
  ].entries()) {
    assert.equal((await request(`activity-invalid-${index}`, 'native_get_activity', params)).error.code, 'INVALID_PARAMS')
  }
  assert.equal(reads, beforeInvalid, 'Invalid queries must fail before controller reads')
  rulesFail = true
  const partial = (await request('activity-partial', 'native_get_activity')).result
  assert.equal(partial.rules.state, 'error')
  assert.equal(partial.connections.state, 'ready')
  assert.equal(partial.providers.state, 'ready')
  assert.ok(!JSON.stringify(partial).includes('private-controller-token'))
  rulesFail = false
  const first = await request('subscribe-1', 'native_subscribe')
  assert.equal(first.result.profiles.items[0].name, 'Initial profile')
  assert.equal(first.result.core.state, 'ready')
  assert.equal(
    first.result.proxyView.groups.find((group) => group.name === 'Daily').now,
    chosen,
  )
  assert.equal(first.result.proxyView.orderSource, 'fallback')
  assert.equal(await fs.readFile(profilePath, 'utf8'), yaml('Initial profile'))
  assert.equal(
    (await request('write-denied', 'restart_core')).error.code,
    'NATIVE_COMMAND_UNAVAILABLE',
  )
  chosen = 'Tokyo test'
  await fs.writeFile(profilePath, yaml('Revised profile'))
  const change = await waitFor(
    (frame) =>
      frame.kind === 'event' &&
      frame.payload.profiles.items[0]?.name === 'Revised profile',
  )
  assert.equal(change.name, 'tez://snapshot-changed')
  assert.equal(change.sequence, '1')
  assert.ok(BigInt(change.payload.revision) > BigInt(first.result.revision))
  assert.equal(
    change.payload.proxyView.groups.find((group) => group.name === 'Daily').now,
    'Tokyo test',
  )
  assert.ok(frames.indexOf(first) < frames.indexOf(change))
  await request('unsubscribe', 'native_unsubscribe')
  const eventCount = frames.filter((frame) => frame.kind === 'event').length
  await fs.writeFile(profilePath, yaml('After unsubscribe'))
  await new Promise((resolve) => setTimeout(resolve, 2300))
  assert.equal(
    frames.filter((frame) => frame.kind === 'event').length,
    eventCount,
  )
  const resumed = await request('subscribe-2', 'native_subscribe')
  assert.equal(resumed.result.profiles.items[0].name, 'After unsubscribe')
  await fs.writeFile(profilePath, 'items: [invalid')
  const invalid = await waitFor(
    (frame) =>
      frame.kind === 'event' && frame.payload.profiles.state === 'error',
  )
  assert.equal(invalid.sequence, '2')
  assert.equal(invalid.payload.core.state, 'ready')
  assert.equal(await fs.readFile(profilePath, 'utf8'), 'items: [invalid')
  assert.equal(writes, 0)
  assert.ok(reads >= 2)
  assert.ok(!JSON.stringify(frames).includes('private-token'))
  assert.ok(!diagnostics.includes('private-token'))
  child.stdin.end()
  const [code] = await Promise.race([
    exited,
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error('Host did not exit at EOF')),
        8000,
      ).unref(),
    ),
  ])
  assert.equal(code, 0, diagnostics)
  assert.equal(buffered, '')
  console.log(
    'PASS: real host read isolated profiles/routes/activity, searched beyond the first page, bounded pagination and rejected query parameters, preserved partial reads, synchronized changes, rejected writes, protected secrets and exited at EOF.',
  )
} finally {
  child.stdin.end()
  server.closeAllConnections()
  await new Promise((resolve) => server.close(resolve))
  await fs.rm(directory, { recursive: true, force: true })
}
