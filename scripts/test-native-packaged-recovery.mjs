import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { once } from 'node:events'

const [app, root] = process.argv.slice(2)
assert.ok(path.isAbsolute(app) && root?.startsWith('/private/tmp/tez-package-acceptance-'))
const helper = path.join(app, 'Contents/Helpers/tez-native-host')
const expected = JSON.parse(fs.readFileSync(path.join(root, 'seed.json'), 'utf8'))

function session(number) {
  const pidFile = path.join(root, `helper-${number}.pid`)
  const child = spawn('/bin/bash', ['-o', 'pipefail', '-c',
    'cat | /bin/bash -c \'echo "$$" > "$2"; exec "$1" --stdio --automatic\' tez-helper "$1" "$2" | cat',
    'tez-package-recovery', helper, pidFile], {
    env: { ...process.env, HOME: path.join(root, 'home') }, stdio: ['pipe', 'pipe', 'pipe'],
  })
  const exit = once(child, 'exit')
  let buffer = '', diagnostics = '', closed = false
  const queue = []
  let wake = () => {}
  child.stderr.setEncoding('utf8').on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-4000) })
  child.stdout.setEncoding('utf8').on('data', chunk => {
    buffer += chunk
    let end
    while ((end = buffer.indexOf('\n')) >= 0) {
      queue.push(JSON.parse(buffer.slice(0, end)))
      buffer = buffer.slice(end + 1)
    }
    wake()
  })
  child.on('exit', () => { closed = true; wake() })
  async function next() {
    const deadline = Date.now() + 20_000
    while (!queue.length) {
      assert.ok(!closed, `Packaged helper exited: ${diagnostics}`)
      assert.ok(Date.now() < deadline, `Packaged helper deadline: ${diagnostics}`)
      await new Promise(resolve => {
        const timer = setTimeout(resolve, 200)
        wake = () => { clearTimeout(timer); resolve() }
      })
    }
    return queue.shift()
  }
  let sequence = 0
  async function request(command) {
    const id = `check-${++sequence}`
    child.stdin.write(JSON.stringify({ version: 1, kind: 'request', id, command, params: {} }) + '\n')
    let reply
    do { reply = await next() } while (reply.kind === 'event')
    assert.equal(reply.id, id)
    assert.ok(!reply.error, `${command}: ${JSON.stringify(reply.error)}`)
    return reply.result
  }
  async function close(crash) {
    if (crash && !closed) {
      const pid = Number(fs.readFileSync(pidFile, 'utf8').trim())
      assert.ok(Number.isInteger(pid) && pid > 1)
      process.kill(pid, 'SIGKILL')
    }
    child.stdin.end()
    const [code] = await exit
    if (!crash) assert.equal(code, 0, diagnostics)
  }
  return { next, request, close }
}

for (const number of [1, 2]) {
  const connection = session(number)
  let crash = true
  try {
    const hello = await connection.next()
    assert.equal(hello.kind, 'hello')
    for (const command of ['native_prepare_shutdown', 'native_get_core_control']) {
      assert.ok(hello.capabilities.includes(command), 'Helper fell back to an observer instead of restoring ownership')
    }
    const control = await connection.request('native_get_core_control')
    assert.equal(control.pid, expected.pid)
    assert.equal(control.generation, expected.generation)
    const snapshot = await connection.request('native_get_snapshot')
    assert.equal(snapshot.core.state, 'ready')
    assert.equal(snapshot.profiles.items.length, 1)
    assert.ok(snapshot.proxyView.groups.some(group => group.name === 'Fixture'))
    const runtime = await connection.request('native_get_runtime')
    assert.equal(runtime.mode, 'Service')
    await connection.request('native_core_start')
    assert.equal((await connection.request('native_get_core_control')).pid, expected.pid)
    if (number === 2) {
      assert.equal((await connection.request('native_prepare_shutdown')).safeToExit, true)
      crash = false
    }
  } catch (error) {
    console.error(error.message)
    throw error
  } finally {
    await connection.close(crash)
  }
}
console.log(JSON.stringify({ result: 'PASS', packagedRecovery: true, crashRecovery: true,
  sameCorePID: expected.pid, sameGeneration: expected.generation, idempotentStart: true, controlledShutdown: true,
  scope: 'real packaged native host and acceptance service; system proxy writes excluded' }))
