import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const root = path.resolve(import.meta.dirname, '..')
const swift = path.join(root, 'native/.build/backend-wire-check')
const rust = path.join(
  root,
  'native/backend-wire/target/debug/tez-backend-wire',
)
const fixtures = fs.readFileSync(
  path.join(root, 'native/migration/wire-fixtures.ndjson'),
  'utf8',
)
function run(binary, input, args = ['--roundtrip']) {
  const result = spawnSync(binary, args, {
    input,
    encoding: 'utf8',
    timeout: 20_000,
    maxBuffer: 24 * 1024 * 1024,
  })
  if (result.error) throw result.error
  return result
}
function values(text) {
  assert.ok(text.endsWith('\n'), 'Every frame must end with a newline')
  return text
    .trimEnd()
    .split('\n')
    .map((line) =>
      JSON.parse(line, (_key, value, context) => {
        if (typeof value !== 'number') return value
        const spelling = context.source
        if (!/[.eE]/.test(spelling)) return BigInt(spelling)
        return Number.isSafeInteger(value) ? BigInt(value) : value
      }),
    )
}
for (const [first, second] of [
  [swift, rust],
  [rust, swift],
]) {
  const encoded = run(first, fixtures)
  assert.equal(encoded.status, 0, encoded.stderr)
  assert.deepEqual(values(encoded.stdout), values(fixtures))
  const decoded = run(second, encoded.stdout)
  assert.equal(decoded.status, 0, decoded.stderr)
  assert.deepEqual(values(decoded.stdout), values(fixtures))
}
const invalid = [
  '\n',
  '{"version":1,"kind":"request","id":"a","command":"x","params":{}}',
  '{"version":2,"kind":"request","id":"a","command":"x","params":{}}\n',
  '{"version":1.0,"kind":"request","id":"a","command":"x","params":{}}\n',
  '{"version":1,"version":1,"kind":"request","id":"a","command":"x","params":{}}\n',
  '{"version":1,"\\u0076ersion":1,"kind":"request","id":"a","command":"x","params":{}}\n',
  '{"version":1,"kind":"request","id":"a","command":"x","params":[]}\n',
  '{"version":1,"kind":"response","id":"a","result":null,"error":{"detail":"x"}}\n',
  '{"version":1,"kind":"event","sequence":"01","name":"x","payload":null}\n',
  '{"version":1,"kind":"response","id":"a","result":18446744073709551616}\n',
  '{"version":1,"kind":"response","id":"a","result":-9223372036854775809}\n',
  '{"version":1,"kind":"response","id":"a","result":1e400}\n',
]
for (const binary of [swift, rust]) {
  for (const input of invalid)
    assert.notEqual(
      run(binary, input).status,
      0,
      `${path.basename(binary)} accepted malformed input`,
    )
}
console.log(
  `PASS: 6 fixtures roundtrip in both directions; ${invalid.length} invalid frames rejected by both codecs.`,
)

if (process.argv[2]) {
  const requests =
    [
      {
        version: 1,
        kind: 'request',
        id: 'dir',
        command: 'get_app_dir',
        params: {},
      },
      {
        version: 1,
        kind: 'request',
        id: 'host',
        command: 'get_system_hostname',
        params: {},
      },
      {
        version: 1,
        kind: 'request',
        id: 'denied',
        command: 'restart_core',
        params: {},
      },
      {
        version: 1,
        kind: 'request',
        id: 'params',
        command: 'get_app_dir',
        params: { unexpected: true },
      },
    ]
      .map((request) => JSON.stringify(request))
      .join('\n') + '\n'
  const encodedRequests = run(swift, requests)
  assert.equal(encodedRequests.status, 0, encodedRequests.stderr)
  // Node uses socketpairs for stdio on macOS; the host deliberately requires pipes.
  const output = run('/bin/bash', encodedRequests.stdout, [
    '-o',
    'pipefail',
    '-c',
    'cat | "$1" --stdio | cat',
    'tez-host-check',
    path.resolve(process.argv[2]),
  ])
  assert.equal(output.status, 0, output.stderr)
  const messages = output.stdout
    .trimEnd()
    .split('\n')
    .map((line) => JSON.parse(line))
  assert.equal(messages.length, 5)
  assert.equal(messages[0].kind, 'hello')
  assert.deepEqual([...messages[0].capabilities].sort(), [
    'get_app_dir',
    'get_system_hostname',
  ])
  const responses = new Map(
    messages.slice(1).map((message) => [message.id, message]),
  )
  assert.equal(typeof responses.get('dir').result, 'string')
  assert.ok(responses.get('dir').result.length > 0)
  assert.equal(typeof responses.get('host').result, 'string')
  assert.equal(responses.get('denied').error.code, 'NATIVE_COMMAND_UNAVAILABLE')
  assert.ok(responses.get('params').error)
  assert.equal(
    run(swift, output.stdout).status,
    0,
    'Swift must decode actual backend responses',
  )
  console.log(
    'PASS: Read-only host reused two existing commands; writes/unsupported params rejected; Swift decoded actual responses.',
  )
}
