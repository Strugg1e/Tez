import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), 'package-core.mjs')
const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'tez-packaging-')))
const app = path.join(temporary, 'Fixture.app')
const contents = path.join(app, 'Contents')
const target = { arm64: 'aarch64-apple-darwin', x64: 'x86_64-apple-darwin' }[os.arch()]
const run = (args, env = {}) => spawnSync(process.execPath, [script, ...args], {
  encoding: 'utf8', env: { ...process.env, ...env },
})

try {
  fs.mkdirSync(path.join(contents, 'Helpers'), { recursive: true })
  fs.mkdirSync(path.join(contents, 'Resources/resources'), { recursive: true })
  const names = ['Helpers/mihomo', 'Helpers/mihomo-alpha',
    ...['Country.mmdb', 'ASN.mmdb', 'geoip.dat', 'geosite.dat', 'set_dns.sh', 'unset_dns.sh'].map(name => `Resources/resources/${name}`),
    'Resources/native-core-manifest.json']
  for (const name of names) fs.writeFileSync(path.join(contents, name), 'fixture')
  const retained = path.join(contents, 'Resources/retained.txt')
  fs.writeFileSync(retained, 'keep')
  assert.equal(run(['--remove', app]).status, 0)
  assert(names.every(name => !fs.existsSync(path.join(contents, name))))
  assert.equal(fs.readFileSync(retained, 'utf8'), 'keep')

  const manifest = {
    version: 1, target,
    files: names.filter(name => !name.endsWith('.json')).map(name => ({
      path: name, sourceSHA256: '0'.repeat(64), bundledSHA256: '0'.repeat(64),
    })),
  }
  fs.writeFileSync(path.join(contents, 'Resources/native-core-manifest.json'), JSON.stringify(manifest))
  const missing = run(['--verify', app])
  assert.notEqual(missing.status, 0)
  assert.match(missing.stderr, /ENOENT/)
  const firstCore = path.join(contents, 'Helpers/mihomo')
  fs.writeFileSync(firstCore, 'tampered', { mode: 0o755 })
  const tampered = run(['--verify', app])
  assert.notEqual(tampered.status, 0)
  assert.match(tampered.stderr, /checksum mismatch/)
  fs.unlinkSync(firstCore)

  const external = path.join(temporary, 'external')
  fs.mkdirSync(external)
  const sentinel = path.join(external, 'verge-mihomo')
  fs.writeFileSync(sentinel, 'untouched')
  fs.rmdirSync(path.join(contents, 'Helpers'))
  fs.symlinkSync(external, path.join(contents, 'Helpers'))
  assert.notEqual(run(['--remove', app]).status, 0)
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'untouched')

  const sources = path.join(temporary, 'sources')
  fs.mkdirSync(sources)
  fs.chmodSync(sentinel, 0o755)
  fs.symlinkSync(sentinel, path.join(sources, `verge-mihomo-${target}`))
  const sourceResult = run(['--source-check'], { TEZ_NATIVE_SIDECAR_DIR: sources })
  assert.notEqual(sourceResult.status, 0)
  assert.match(sourceResult.stderr, /ordinary file without symlinks/)

  const dnsResources = path.join(temporary, 'dns-resources')
  fs.mkdirSync(dnsResources)
  for (const name of ['Country.mmdb', 'ASN.mmdb', 'geoip.dat', 'geosite.dat', 'set_dns.sh', 'unset_dns.sh']) {
    fs.writeFileSync(path.join(dnsResources, name), 'fixture', { mode: 0o644 })
  }
  const resourceEnv = { TEZ_NATIVE_RESOURCE_DIR: dnsResources }
  assert.equal(run(['--source-check'], resourceEnv).status, 0)
  const unset = path.join(dnsResources, 'unset_dns.sh')
  fs.unlinkSync(unset)
  const missingScript = run(['--source-check'], resourceEnv)
  assert.notEqual(missingScript.status, 0)
  assert.match(missingScript.stderr, /unset_dns\.sh/)
  fs.symlinkSync(path.join(dnsResources, 'set_dns.sh'), unset)
  const linkedScript = run(['--source-check'], resourceEnv)
  assert.notEqual(linkedScript.status, 0)
  assert.match(linkedScript.stderr, /ordinary file without symlinks/)
  fs.unlinkSync(unset)
  fs.writeFileSync(unset, 'fixture', { mode: 0o666 })
  fs.chmodSync(unset, 0o666)
  const writableScript = run(['--source-check'], resourceEnv)
  assert.notEqual(writableScript.status, 0)
  assert.match(writableScript.stderr, /not group\/world-writable/)
  console.log('PASS: missing files, tampered hashes and unsafe DNS scripts rejected; cleanup preserves unrelated files and rejects linked output/source paths')
} finally {
  fs.rmSync(temporary, { recursive: true, force: true })
}
