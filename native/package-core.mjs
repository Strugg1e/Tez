import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = path.dirname(fileURLToPath(import.meta.url))
const cores = ['mihomo', 'mihomo-alpha']
const databases = ['Country.mmdb', 'ASN.mmdb', 'geoip.dat', 'geosite.dat']
const dnsScripts = ['set_dns.sh', 'unset_dns.sh']
const architecture = { arm64: 'arm64', x64: 'x86_64' }[os.arch()]
const target = { arm64: 'aarch64-apple-darwin', x64: 'x86_64-apple-darwin' }[os.arch()]
const manifestName = 'native-core-manifest.json'

function requireFile(file, executable = false) {
  const metadata = fs.lstatSync(file)
  if (!path.isAbsolute(file) || fs.realpathSync(file) !== file || !metadata.isFile() || metadata.size === 0) {
    throw new Error(`Expected a nonempty ordinary file without symlinks: ${file}`)
  }
  if (executable && !(metadata.mode & 0o111)) throw new Error(`Expected an executable: ${file}`)
  return metadata
}

function inspectCore(file) {
  requireFile(file, true)
  execFileSync('/usr/bin/lipo', [file, '-verify_arch', architecture], { stdio: 'pipe' })
}

function digest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

function sources() {
  if (os.platform() !== 'darwin' || !target) throw new Error('Core packaging requires a supported macOS host')
  const sidecars = path.resolve(process.env.TEZ_NATIVE_SIDECAR_DIR ?? path.join(root, '../src-tauri/sidecar'))
  const resources = path.resolve(process.env.TEZ_NATIVE_RESOURCE_DIR ?? path.join(root, '../src-tauri/resources'))
  const files = [
    ...cores.map(name => ({ name, executable: true, source: path.join(sidecars, `verge-${name}-${target}`), destination: `Helpers/${name}` })),
    ...databases.map(name => ({ name, executable: false, source: path.join(resources, name), destination: `Resources/resources/${name}` })),
    ...dnsScripts.map(name => ({ name, executable: false, script: true, source: path.join(resources, name), destination: `Resources/resources/${name}` })),
  ]
  for (const item of files) {
    if (item.executable) inspectCore(item.source)
    else {
      const metadata = requireFile(item.source)
      if (item.script && (!(metadata.mode & 0o400) || (metadata.mode & 0o022))) {
        throw new Error(`DNS script must be owner-readable and not group/world-writable: ${item.source}`)
      }
    }
  }
  return files
}

function contents(app) {
  if (!app || !path.isAbsolute(app) || path.extname(app) !== '.app' || fs.realpathSync(app) !== app) {
    throw new Error('Expected an existing absolute application bundle without symlinks')
  }
  const directory = path.join(app, 'Contents')
  if (!fs.lstatSync(directory).isDirectory() || fs.realpathSync(directory) !== directory) {
    throw new Error('Expected ordinary application Contents directory')
  }
  return directory
}

function checkParents(destinationRoot, relative, create = false) {
  let directory = destinationRoot
  for (const component of path.dirname(relative).split('/')) {
    directory = path.join(directory, component)
    if (!fs.existsSync(directory)) {
      if (!create) return
      fs.mkdirSync(directory)
    }
    if (!fs.lstatSync(directory).isDirectory() || fs.realpathSync(directory) !== directory) {
      throw new Error('Refusing a symlink or non-directory in the output bundle')
    }
  }
}

function copy(app) {
  const files = sources()
  const destinationRoot = contents(app)
  const entries = []
  for (const item of files) {
    const destination = path.join(destinationRoot, item.destination)
    checkParents(destinationRoot, item.destination, true)
    const staged = `${destination}.package-${process.pid}`
    fs.copyFileSync(item.source, staged, fs.constants.COPYFILE_EXCL)
    fs.renameSync(staged, destination)
    const copied = requireFile(destination, item.executable)
    const original = fs.statSync(item.source)
    if ((copied.dev === original.dev && copied.ino === original.ino) || digest(destination) !== digest(item.source)) {
      throw new Error('Core resource must be an independent, identical copy')
    }
    if (item.executable) {
      fs.chmodSync(destination, 0o755)
      execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', destination], { stdio: 'inherit' })
    } else if (item.script) {
      // DNS helpers run through bash and are sealed resources, not executables.
      fs.chmodSync(destination, 0o644)
    }
    entries.push({ path: item.destination, sourceSHA256: digest(item.source), bundledSHA256: digest(destination) })
  }
  const relativeManifest = `Resources/${manifestName}`
  checkParents(destinationRoot, relativeManifest, true)
  const manifestFile = path.join(destinationRoot, relativeManifest)
  const stagedManifest = `${manifestFile}.package-${process.pid}`
  fs.writeFileSync(stagedManifest, `${JSON.stringify({ version: 1, target, files: entries }, null, 2)}\n`, { flag: 'wx' })
  fs.renameSync(stagedManifest, manifestFile)
}

function verify(app) {
  const destinationRoot = contents(app)
  const manifestFile = path.join(destinationRoot, 'Resources', manifestName)
  requireFile(manifestFile)
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
  const expected = [...cores.map(name => `Helpers/${name}`), ...[...databases, ...dnsScripts].map(name => `Resources/resources/${name}`)]
  if (manifest.version !== 1 || manifest.target !== target || !Array.isArray(manifest.files) ||
      manifest.files.length !== expected.length || new Set(manifest.files.map(entry => entry.path)).size !== expected.length) {
    throw new Error('Invalid bundled core manifest')
  }
  for (const relative of expected) {
    const entry = manifest.files.find(item => item.path === relative)
    if (!entry || !/^[a-f0-9]{64}$/.test(entry.sourceSHA256) || !/^[a-f0-9]{64}$/.test(entry.bundledSHA256)) {
      throw new Error('Incomplete bundled core manifest')
    }
    const file = path.join(destinationRoot, relative)
    checkParents(destinationRoot, relative)
    if (requireFile(file, relative.startsWith('Helpers/')).nlink !== 1) {
      throw new Error(`Bundled resource must not share a hard link: ${relative}`)
    }
    if (digest(file) !== entry.bundledSHA256) throw new Error(`Bundled resource checksum mismatch: ${relative}`)
    if (dnsScripts.includes(path.basename(relative)) && (fs.statSync(file).mode & 0o777) !== 0o644) {
      throw new Error(`Bundled DNS script permissions must be 0644: ${relative}`)
    }
    if (relative.startsWith('Helpers/')) {
      inspectCore(file)
      execFileSync('/usr/bin/codesign', ['--verify', '--strict', file], { stdio: 'pipe' })
    }
  }
  const helper = path.join(destinationRoot, 'Helpers/tez-native-host')
  requireFile(helper, true)
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', helper], { stdio: 'pipe' })
  console.log(`PASS: ${cores.length} signed ${architecture} cores, ${databases.length} independent databases and ${dnsScripts.length} DNS scripts`)
}

function remove(app) {
  const destinationRoot = contents(app)
  for (const relative of [...cores.map(name => `Helpers/${name}`), ...[...databases, ...dnsScripts].map(name => `Resources/resources/${name}`), `Resources/${manifestName}`]) {
    checkParents(destinationRoot, relative)
    fs.rmSync(path.join(destinationRoot, relative), { force: true })
  }
}

const [mode, app, ...extra] = process.argv.slice(2)
if (extra.length || !['--source-check', '--copy', '--verify', '--remove'].includes(mode) || (mode === '--source-check' ? app : !app)) {
  throw new Error('Usage: node package-core.mjs --source-check | (--copy|--verify|--remove) ABSOLUTE_APP_PATH')
}
if (mode === '--source-check') {
  sources()
  console.log('PASS: local core, database and DNS script sources are complete; no download or process startup')
} else if (mode === '--copy') copy(app)
else if (mode === '--verify') verify(app)
else remove(app)
