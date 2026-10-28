import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { runParity } from './check-native-parity.mjs'

const quiet = { log() {}, error() {} }
const bindings = `
export const command = () => __TAURI_INVOKE('test_command')
export type VergeEventPayloads = { 'verge://test-event': string }
`
const mihomo = `import { getConfig as config, type Config } from 'tauri-plugin-mihomo-api'
export const load = () => config()
`

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tez-parity-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const write = (file, text) => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true })
    fs.writeFileSync(path.join(root, file), text)
  }
  const json = (file, value) => write(file, JSON.stringify(value))
  write('src/services/bindings.ts', bindings)
  write('src/client.ts', mihomo)
  write('src/workflow.ts', 'export const start = () => true\n')
  write('evidence.md', 'Manual acceptance evidence fixture.\n')
  json('native/migration/workflows.json', [
    { id: 'test-workflow', source: 'src/workflow.ts' },
  ])
  const manifest = () =>
    JSON.parse(
      fs.readFileSync(path.join(root, 'native/migration/parity.json'), 'utf8'),
    )
  const save = (value) => json('native/migration/parity.json', value)
  const run = (mode = '--check') => runParity(root, mode, quiet)
  const accept = () => {
    const value = manifest()
    for (const entry of Object.values(value.entries)) {
      entry.status = 'verified'
      entry.evidence = ['evidence.md']
    }
    save(value)
  }
  return { root, write, json, manifest, save, run, accept }
}

test('sync inventories AST imports, defaults to pending, and never accepts obligations', (t) => {
  const f = fixture(t)
  assert.throws(() => f.run(), /missing or stale/)
  assert.equal(f.run('--sync'), 0)
  assert.deepEqual(Object.keys(f.manifest().entries), [
    'command:test_command',
    'event:verge://test-event',
    'mihomo:getConfig',
    'workflow:test-workflow',
  ])
  assert.ok(
    Object.values(f.manifest().entries).every(
      (entry) => entry.status === 'pending' && !entry.evidence.length,
    ),
  )
  assert.equal(f.run(), 0)
  assert.equal(f.run('--release'), 1)
  f.accept()
  assert.equal(f.run('--release'), 0)
  f.run('--sync')
  assert.equal(f.run('--release'), 0)
})

for (const [name, change] of [
  [
    'Mihomo usage',
    (f) =>
      f.write(
        'src/client.ts',
        mihomo.replace('config()', 'config({ force: true })'),
      ),
  ],
  [
    'Mihomo source move',
    (f) => {
      fs.renameSync(
        path.join(f.root, 'src/client.ts'),
        path.join(f.root, 'src/moved.ts'),
      )
    },
  ],
  [
    'Mihomo import',
    (f) => f.write('src/client.ts', mihomo.replace('getConfig', 'getVersion')),
  ],
  [
    'workflow definition',
    (f) =>
      f.json('native/migration/workflows.json', [
        {
          id: 'test-workflow',
          source: 'src/workflow.ts',
          acceptance: 'New requirement',
        },
      ]),
  ],
  [
    'workflow source',
    (f) => f.write('src/workflow.ts', 'export const start = () => false\n'),
  ],
  [
    'bindings',
    (f) =>
      f.write('src/services/bindings.ts', `${bindings}\n// changed contract\n`),
  ],
]) {
  test(`${name} drift invalidates acceptance without changing binding names`, (t) => {
    const f = fixture(t)
    f.run('--sync')
    f.accept()
    change(f)
    assert.throws(() => f.run(), /missing or stale/)
    assert.throws(() => f.run('--release'), /missing or stale/)
    f.run('--sync')
    assert.ok(
      Object.values(f.manifest().entries).every(
        (entry) => entry.status === 'pending' && !entry.evidence.length,
      ),
    )
    assert.equal(f.run('--release'), 1)
  })
}

test('legacy bindings-only digest cannot preserve acceptance', (t) => {
  const f = fixture(t)
  f.run('--sync')
  f.accept()
  const value = f.manifest()
  value.version = 1
  f.save(value)
  assert.throws(() => f.run(), /missing or stale/)
  f.run('--sync')
  assert.equal(f.run('--release'), 1)
})

test('sync cannot carry acceptance across mismatched source metadata', (t) => {
  const f = fixture(t)
  f.run('--sync')
  f.accept()
  const value = f.manifest()
  value.entries['mihomo:getConfig'].sources = ['src/workflow.ts']
  f.save(value)
  assert.throws(() => f.run(), /Parity source drift/)
  f.run('--sync')
  assert.equal(f.manifest().entries['mihomo:getConfig'].status, 'pending')
  assert.deepEqual(f.manifest().entries['mihomo:getConfig'].evidence, [])
  assert.equal(f.run('--release'), 1)
})

test('unrelated and test-only sources do not change accepted inventory', (t) => {
  const f = fixture(t)
  f.run('--sync')
  f.accept()
  f.write('src/unrelated.ts', 'export const unrelated = true')
  f.write(
    'src/client.test.ts',
    "import * as api from 'tauri-plugin-mihomo-api'",
  )
  assert.equal(f.run('--release'), 0)
})

for (const [name, change] of [
  [
    'empty commands',
    (f) =>
      f.write(
        'src/services/bindings.ts',
        "export type VergeEventPayloads = { 'event': string }",
      ),
  ],
  [
    'empty events',
    (f) =>
      f.write(
        'src/services/bindings.ts',
        "__TAURI_INVOKE('test_command'); export type VergeEventPayloads = {}",
      ),
  ],
  [
    'empty Mihomo',
    (f) =>
      f.write(
        'src/client.ts',
        "import type { Config } from 'tauri-plugin-mihomo-api'",
      ),
  ],
  ['empty workflows', (f) => f.json('native/migration/workflows.json', [])],
  ['malformed workflows', (f) => f.json('native/migration/workflows.json', {})],
  ['null workflow', (f) => f.json('native/migration/workflows.json', [null])],
  [
    'duplicate workflows',
    (f) =>
      f.json(
        'native/migration/workflows.json',
        Array(2).fill({ id: 'same', source: 'src/workflow.ts' }),
      ),
  ],
  [
    'invalid TypeScript',
    (f) => f.write('src/client.ts', 'export const broken = ;'),
  ],
]) {
  test(`rejects ${name} even during sync`, (t) => {
    const f = fixture(t)
    change(f)
    assert.throws(() => f.run('--sync'))
    assert.throws(() => f.run('--release'))
  })
}

for (const source of [
  "import api from 'tauri-plugin-mihomo-api'",
  "import * as api from 'tauri-plugin-mihomo-api'",
  "import 'tauri-plugin-mihomo-api'",
  "export { getConfig } from 'tauri-plugin-mihomo-api'",
  "const api = import('tauri-plugin-mihomo-api')",
  "const api = require('tauri-plugin-mihomo-api')",
  "import api = require('tauri-plugin-mihomo-api')",
]) {
  test(`fails closed for unsupported import: ${source}`, (t) => {
    const f = fixture(t)
    f.write('src/unsupported.ts', source)
    assert.throws(() => f.run('--sync'), /Unsupported Mihomo import/)
  })
}

for (const value of [
  null,
  [],
  {},
  { version: 2, contractDigest: 'a'.repeat(64), entries: {} },
]) {
  test(`rejects malformed manifest ${JSON.stringify(value)}`, (t) => {
    const f = fixture(t)
    f.save(value)
    assert.throws(() => f.run('--sync'), /Invalid parity manifest/)
    assert.throws(() => f.run('--release'), /Invalid parity manifest/)
  })
}

test('rejects entry drift, malformed entries, and missing evidence', (t) => {
  const f = fixture(t)
  f.run('--sync')
  const baseline = f.manifest()
  for (const change of [
    (value) => {
      delete value.entries['command:test_command']
    },
    (value) => {
      value.entries['command:stale'] = value.entries['command:test_command']
    },
    (value) => {
      value.entries['command:test_command'].sources = ['src/client.ts']
    },
    (value) => {
      value.entries['command:test_command'].sources = []
    },
    (value) => {
      value.entries['command:test_command'].status = 'complete'
    },
    (value) => {
      value.entries['command:test_command'].evidence = null
    },
    (value) => {
      value.entries['command:test_command'].status = 'verified'
    },
  ]) {
    const value = structuredClone(baseline)
    change(value)
    f.save(value)
    assert.throws(() => f.run('--release'))
  }
})

test('rejects outside, malformed, missing, directory, and symlink-escaped evidence', (t) => {
  const f = fixture(t)
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'tez-evidence-'))
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }))
  fs.writeFileSync(path.join(outside, 'proof.md'), 'outside')
  fs.symlinkSync(outside, path.join(f.root, 'escaped'))
  f.run('--sync')
  const baseline = f.manifest()
  for (const evidence of [
    null,
    '',
    1,
    '../proof.md',
    path.join(outside, 'proof.md'),
    'missing.md',
    'src',
    'escaped/proof.md',
  ]) {
    const value = structuredClone(baseline)
    value.entries['command:test_command'].status = 'verified'
    value.entries['command:test_command'].evidence = [evidence]
    f.save(value)
    assert.throws(() => f.run('--release'), /Invalid repository path/)
    assert.throws(() => f.run('--sync'), /Invalid repository path/)
  }
})
