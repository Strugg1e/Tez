import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import { execFileSync } from 'node:child_process'

const [socket, protectedPid, mode] = process.argv.slice(2)
assert.ok(socket?.startsWith('/var/run/clash-verge-service/users/'), 'Expected the owned service controller socket')
assert.match(protectedPid ?? '', /^[1-9][0-9]*$/)
assert.ok(mode === '--plan' || mode === '--one-probe', 'Use --plan or --one-probe')
assert.ok(fs.lstatSync(socket).isSocket(), 'Controller path is not a socket')
const identity = () => execFileSync('/bin/ps', ['-p', protectedPid, '-o', 'lstart=', '-o', 'comm='], { encoding: 'utf8' }).trim()
const initialIdentity = identity()
assert.ok(initialIdentity.includes('verge-mihomo'), 'Protected Core identity is unavailable')

function get(route) {
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath: socket, path: route, method: 'GET', timeout: 10000 }, response => {
      let text = ''
      response.setEncoding('utf8')
      response.on('data', chunk => { text += chunk; if (Buffer.byteLength(text) > 4 * 1024 * 1024) request.destroy(new Error('Response too large')) })
      response.on('end', () => {
        try { resolve({ status: response.statusCode, value: JSON.parse(text) }) }
        catch { reject(new Error('Controller returned invalid JSON')) }
      })
    })
    request.on('timeout', () => request.destroy(new Error('Controller request timed out')))
    request.on('error', reject)
    request.end()
  })
}

const snapshot = await get('/proxies')
assert.equal(snapshot.status, 200, 'Cannot read controller nodes')
const proxies = snapshot.value.proxies
assert.ok(proxies && typeof proxies === 'object')
const usable = value => value && !Array.isArray(value.all)
  && !['direct', 'reject', 'rejectdrop', 'pass', 'compatible'].includes(String(value.type).toLowerCase())
let name = 'GLOBAL'
const visited = new Set()
while (proxies[name]?.now && !visited.has(name)) {
  visited.add(name)
  name = proxies[name].now
}
if (!usable(proxies[name])) {
  const active = Object.values(proxies).filter(proxy => Array.isArray(proxy.all) && proxy.now)
    .map(proxy => proxy.now).find(candidate => usable(proxies[candidate]))
  name = active ?? Object.keys(proxies).find(candidate => usable(proxies[candidate])
    && proxies[candidate].history?.some(sample => sample.delay > 0))
}
assert.ok(name && usable(proxies[name]), 'No usable named Core node found')
assert.equal(identity(), initialIdentity, 'Protected Core changed before probing')
if (mode === '--plan') {
  console.log('PASS: one existing Core node can be selected; no delay request was sent.')
} else {
  const query = new URLSearchParams({ timeout: '5000', url: 'https://www.gstatic.com/generate_204' })
  console.error('Sending exactly one latency request; no automatic retry.')
  const result = await get(`/proxies/${encodeURIComponent(name)}/delay?${query}`)
  assert.equal(identity(), initialIdentity, 'Protected Core changed during probing')
  if (result.status !== 200 || !Number.isInteger(result.value.delay) || result.value.delay <= 0) {
    console.log(JSON.stringify({ result: 'FAIL', httpStatus: result.status, delay: result.value.delay ?? null, attempts: 1 }))
    process.exitCode = 1
  } else {
    console.log(JSON.stringify({ result: 'PASS', delayMs: result.value.delay, attempts: 1 }))
  }
}
