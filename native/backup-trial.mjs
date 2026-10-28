import fs from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { createHash, randomBytes } from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import path from 'node:path'
import assert from 'node:assert/strict'

const execute = promisify(execFile)
const [app, data, parent, ...extra] = process.argv.slice(2)
assert.ok(app && data && parent && !extra.length, 'Expected old app, data directory and backup parent')
assert.equal(process.platform, 'darwin')
for (const source of [app, data]) {
  assert.ok(path.isAbsolute(source))
  assert.equal(await fs.realpath(source), source, 'Source must not traverse symlinks')
  assert.ok((await fs.lstat(source)).isDirectory())
}
assert.equal(path.extname(app), '.app')
assert.ok(path.isAbsolute(parent) && parent.endsWith('.noindex'))
assert.ok(!parent.startsWith(`${app}/`) && !parent.startsWith(`${data}/`))
process.umask(0o077)
await fs.mkdir(parent, { mode: 0o700, recursive: true })
assert.equal(await fs.realpath(parent), parent)
assert.equal((await fs.stat(parent)).uid, process.getuid())
await fs.chmod(parent, 0o700)
await fs.writeFile(path.join(parent, '.gitignore'), '*\n', { flag: 'wx', mode: 0o600 }).catch(error => {
  if (error.code !== 'EEXIST') throw error
})
const directory = path.join(parent, `trial-${new Date().toISOString().replaceAll(':', '-')}-${randomBytes(4).toString('hex')}`)
await fs.mkdir(directory, { mode: 0o700 })
const excluded = new Set(['logs', 'service-logs', 'singleton-instance.json', 'singleton-instance.lock'])

async function hash(file) {
  const digest = createHash('sha256')
  for await (const chunk of createReadStream(file)) digest.update(chunk)
  return digest.digest('hex')
}

async function inventory(root, skip = new Set(), allowLinks = false) {
  const records = []
  async function walk(relative = '') {
    for (const name of (await fs.readdir(path.join(root, relative))).sort()) {
      if (!relative && skip.has(name)) continue
      const item = path.join(relative, name)
      const absolute = path.join(root, item)
      const stat = await fs.lstat(absolute)
      if (stat.isDirectory()) {
        records.push({ path: item, type: 'directory', mode: stat.mode & 0o777 })
        await walk(item)
      } else if (stat.isFile()) {
        records.push({ path: item, type: 'file', size: stat.size, mode: stat.mode & 0o777, sha256: await hash(absolute) })
      } else if (stat.isSymbolicLink() && allowLinks) {
        const target = await fs.readlink(absolute)
        const resolved = path.resolve(path.dirname(absolute), target)
        assert.ok(resolved.startsWith(`${root}/`), 'Application link escapes its bundle')
        records.push({ path: item, type: 'symlink', target })
      } else throw new Error('Unsupported source entry; refusing an incomplete backup')
    }
  }
  await walk()
  return records
}

async function capture(command, args) {
  try {
    const result = await execute(command, args, { timeout: 15000, maxBuffer: 4 * 1024 * 1024 })
    return { ok: !/AuthorizationCreate\(\) failed|Error:|not a recognized network service/.test(result.stdout + result.stderr), stdout: result.stdout }
  } catch { return { ok: false, stdout: '' } }
}

async function networkState() {
  const services = await capture('/usr/sbin/networksetup', ['-listallnetworkservices'])
  const settings = []
  if (services.ok) {
    for (const raw of services.stdout.trim().split('\n').slice(1)) {
      const name = raw.replace(/^\*/, '')
      const values = {}
      for (const option of ['-getdnsservers', '-getsearchdomains', '-getwebproxy', '-getsecurewebproxy', '-getsocksfirewallproxy', '-getautoproxyurl', '-getproxybypassdomains', '-getproxyautodiscovery']) {
        values[option] = await capture('/usr/sbin/networksetup', [option, name])
      }
      settings.push({ name, disabled: raw.startsWith('*'), values })
    }
  }
  return { proxy: await capture('/usr/sbin/scutil', ['--proxy']), dns: await capture('/usr/sbin/scutil', ['--dns']), services, settings }
}

try {
  const appBefore = await inventory(app, new Set(), true)
  const dataBefore = await inventory(data, excluded)
  for (const required of ['profiles.yaml', 'tez.yaml', 'config.yaml']) {
    assert.ok(dataBefore.some(item => item.path === required && item.type === 'file'))
  }
  const network = await networkState()
  const appCopy = path.join(directory, 'legacy-app', path.basename(app))
  const dataCopy = path.join(directory, 'app-data')
  await fs.mkdir(path.dirname(appCopy), { mode: 0o700 })
  await execute('/usr/bin/ditto', [app, appCopy], { timeout: 180000, maxBuffer: 1024 * 1024 })
  await fs.mkdir(dataCopy, { mode: 0o700 })
  for (const name of (await fs.readdir(data)).sort()) {
    if (!excluded.has(name)) await fs.cp(path.join(data, name), path.join(dataCopy, name), {
      recursive: true, force: false, errorOnExist: true, dereference: false, verbatimSymlinks: true, preserveTimestamps: true,
    })
  }
  assert.deepEqual(await inventory(app, new Set(), true), appBefore, 'Old application changed during backup')
  assert.deepEqual(await inventory(data, excluded), dataBefore, 'Configuration changed during backup')
  assert.deepEqual(await inventory(appCopy, new Set(), true), appBefore, 'Application backup differs')
  assert.deepEqual(await inventory(dataCopy), dataBefore, 'Data backup differs')
  const signature = await capture('/usr/bin/codesign', ['--verify', '--deep', '--strict', appCopy])
  const after = await networkState()
  assert.deepEqual(after, network, 'Network baseline changed during backup')
  await fs.writeFile(path.join(directory, 'network-baseline.json'), JSON.stringify(network, null, 2), { mode: 0o600, flag: 'wx' })
  const manifest = {
    version: 1, createdAt: new Date().toISOString(), sourceApp: app, sourceData: data,
    backupVerified: true, signatureVerified: signature.ok,
    networkBaselineComplete: network.proxy.ok && network.dns.ok && network.services.ok && network.settings.every(service => Object.values(service.values).every(value => value.ok)),
    trialStarted: false, rollbackReady: false,
    blockers: ['Managed UI activation is absent', 'Failed managed cleanup has no reliable recovery entry point'],
    excluded: [...excluded], application: appBefore, data: dataBefore,
  }
  await fs.writeFile(path.join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2), { mode: 0o600, flag: 'wx' })
  console.log(JSON.stringify({ directory, backupVerified: true, signatureVerified: signature.ok, networkBaselineComplete: manifest.networkBaselineComplete, dataFiles: dataBefore.filter(item => item.type === 'file').length, trialStarted: false, rollbackReady: false }))
} catch {
  await fs.writeFile(path.join(directory, 'INCOMPLETE.txt'), 'Backup did not pass verification. Do not use this directory for an automatic rollback. No proxy switch was attempted.\n', { mode: 0o600 })
  console.error(JSON.stringify({ directory, backupVerified: false, trialStarted: false }))
  process.exitCode = 1
}
