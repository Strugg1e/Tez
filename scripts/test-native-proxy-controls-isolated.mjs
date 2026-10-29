import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { once } from 'node:events'
import { randomBytes, createHash } from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import * as yaml from 'js-yaml'

const [helper] = process.argv.slice(2)
assert.ok(helper && path.isAbsolute(helper) && helper.endsWith('.app/Contents/Helpers/tez-native-host'))
const root = `/private/tmp/tez-native-isolated-${randomBytes(12).toString('hex')}`
const hash = value => createHash('sha256').update(value).digest('hex')
const system = () => ['--proxy', '--dns'].map(flag => hash(execFileSync('/usr/sbin/scutil', [flag])))
const protectedPID = process.env.TEZ_PROTECTED_PID
assert.match(protectedPID ?? '', /^[1-9]\d*$/, 'Set TEZ_PROTECTED_PID to the current core PID')
const identity = () => execFileSync('/bin/ps', ['-p', protectedPID, '-o', 'lstart=', '-o', 'comm='], { encoding: 'utf8' }).trim()
const before = { system: system(), identity: identity() }
const child = spawn('/bin/bash', ['-o', 'pipefail', '-c', 'cat | "$1" --stdio --isolated "$2" | cat', 'tez-proxy-isolation', helper, root], { stdio: ['pipe', 'pipe', 'pipe'] })
child.stderr.resume()
const exited = once(child, 'exit')
const queue = []; let buffered = ''; let wake = () => {}; let sequence = 0
child.stdout.setEncoding('utf8').on('data', chunk => {
  buffered += chunk; let end
  while ((end = buffered.indexOf('\n')) >= 0) { queue.push(JSON.parse(buffered.slice(0, end))); buffered = buffered.slice(end + 1) }
  wake()
})
async function next() {
  const deadline = Date.now() + 30_000
  while (!queue.length) {
    assert.ok(Date.now() < deadline, 'Isolated protocol timeout')
    await new Promise(resolve => { const timer = setTimeout(resolve, Math.max(1, deadline - Date.now())); wake = () => { clearTimeout(timer); resolve() } })
  }
  return queue.shift()
}
async function request(command, params = {}, code) {
  const id = `seq:${++sequence}`
  child.stdin.write(JSON.stringify({ version: 1, kind: 'request', id, command, params }) + '\n')
  const response = await next()
  assert.equal(response.id, id)
  if (code) { assert.equal(response.error?.code, code); return }
  assert.ok(!response.error, `${command}: ${response.error?.code}`)
  return response.result
}
function controller(route) {
  return new Promise((resolve, reject) => {
    http.get({ socketPath: path.join(root, 'controller.sock'), path: route }, response => {
      let text = ''; response.on('data', chunk => { text += chunk }); response.on('end', () => resolve(JSON.parse(text)))
    }).on('error', reject)
  })
}
let prepared = false
let accepted = false
try {
  const hello = await next(); assert.equal(hello.kind, 'hello')
  assert.ok(hello.capabilities.includes('native_patch_proxy_config') && hello.capabilities.includes('native_activate_proxy_chain'))
  await request('native_core_start')
  const profile = await request('native_read_profile', { uid: 'fixture' })
  const config = yaml.load(profile.content)
  config.proxies = ['Entry', 'Exit'].map(name => ({ name, type: 'socks5', server: '127.0.0.1', port: 1 }))
  config['proxy-groups'][0].proxies = ['DIRECT', 'REJECT', 'Entry', 'Exit']
  assert.equal((await request('native_save_profile', { uid: 'fixture', content: yaml.dump(config), expectedRevision: profile.revision })).saved, true)
  await request('native_patch_proxy_config', { values: { tun: { stack: 'mixed', device: 'utun1024', mtu: 1400, 'auto-route': false, 'auto-detect-interface': false, 'strict-route': false, 'dns-hijack': ['any:53'], 'dns-mode': '', 'route-exclude-address': ['10.0.0.0/8'] } } })
  const observed = await controller('/configs')
  assert.equal(observed.tun.enable, false)
  assert.equal(observed.tun.mtu, 1400)
  assert.equal(observed['mixed-port'], 0)
  const saved = fs.readFileSync(path.join(root, 'profile.yaml'))
  await request('native_patch_proxy_config', { values: { tun: { 'route-exclude-address': ['10.0.0.0/33'] } } }, 'INVALID_PROXY_CONFIG')
  assert.equal(hash(fs.readFileSync(path.join(root, 'profile.yaml'))), hash(saved))
  await request('native_patch_settings', { values: { enable_system_proxy: true } }, 'ISOLATED_NETWORK_FORBIDDEN')
  await request('native_patch_settings', { values: { enable_tun_mode: true } }, 'ISOLATED_NETWORK_FORBIDDEN')
  for (const mode of ['global', 'direct', 'rule']) { await request('native_set_mode', { mode }); assert.equal((await controller('/configs')).mode, mode) }
  let chain = { id: 'fixture-chain', name: 'Loopback fixture chain', group: 'Fixture', nodes: ['Entry', 'Exit'] }
  for (let iteration = 0; iteration < 2; iteration++) {
    await request('native_save_proxy_chain', { chain })
    await request('native_activate_proxy_chain', { id: chain.id })
    assert.equal((await request('native_get_proxy_chains')).applied, true)
    assert.equal((await controller('/proxies')).proxies.Fixture.now, chain.nodes.at(-1))
    const runtime = yaml.load(fs.readFileSync(path.join(root, 'runtime.yaml'), 'utf8'))
    assert.equal(runtime.proxies.find(node => node.name === chain.nodes[1])['dialer-proxy'], chain.nodes[0])
    await request('native_save_proxy_chain', { chain }, 'CHAIN_ACTIVE')
    await request('native_deactivate_proxy_chain')
    assert.equal((await request('native_get_proxy_chains')).applied, false)
    assert.equal((await controller('/proxies')).proxies.Fixture.now, 'DIRECT')
    chain = { ...chain, nodes: [...chain.nodes].reverse() }
  }
  await request('native_delete_proxy_chain', { id: chain.id })
  assert.deepEqual((await request('native_get_proxy_chains')).chains, [])
  assert.equal(((await controller('/connections')).connections ?? []).length, 0)
  assert.equal((await request('native_prepare_shutdown')).safeToExit, true); prepared = true; accepted = true
} finally {
  if (!prepared) { try { await request('native_prepare_shutdown') } catch {} }
  child.stdin.end(); const [code] = await exited
  assert.equal(code, 0)
  assert.deepEqual(system(), before.system, 'System proxy or DNS changed')
  assert.equal(identity(), before.identity, 'Protected core identity changed')
  if (accepted && fs.existsSync(root)) fs.rmSync(root, { recursive: true, force: true })
  else console.error(`Isolated diagnostic fixture retained: ${root}`)
}
console.log('PASS: private core TUN configuration writes, CIDR refusal, all routing modes, chain save/reorder/enable/disable/delete and selection restoration; production core, OS proxy and DNS unchanged; no latency test or real connection close')
