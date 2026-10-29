import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const [appArgument, ...options] = process.argv.slice(2)
if (!appArgument || (options.length && (options.length !== 2 || options[0] !== '--data-dir'))) {
  throw new Error('Usage: node native/preflight-managed.mjs ABSOLUTE_APP [--data-dir ABSOLUTE_EXISTING_DATA_DIR]')
}
if (process.platform !== 'darwin' || !path.isAbsolute(appArgument) ||
    (options.length && !path.isAbsolute(options[1]))) {
  throw new Error('Preflight requires macOS and absolute paths')
}

const root = path.dirname(fileURLToPath(import.meta.url))
const app = path.normalize(appArgument)
const data = options[1] ?? path.join(os.homedir(), 'Library/Application Support/app.tez.client')
const report = {
  version: 1,
  readOnly: true,
  takeoverAuthorized: false,
  readyForTakeover: false,
  checks: {},
  blockers: [],
}
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const blocked = (code, description) => report.blockers.push({ code, description })

function command(executable, args) {
  try {
    return { ok: true, bytes: execFileSync(executable, args, { timeout: 10_000, maxBuffer: 2 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }) }
  } catch {
    // Tool stderr can contain paths or network state. Only the check status is public.
    return { ok: false }
  }
}

function metadata(file, { directory = false, hash = false } = {}) {
  try {
    const stat = fs.lstatSync(file)
    if ((directory ? !stat.isDirectory() : !stat.isFile()) || fs.realpathSync(file) !== file) {
      return { state: 'unsupported' }
    }
    const result = { state: 'present', bytes: stat.size, uid: stat.uid, mode: (stat.mode & 0o777).toString(8), modifiedAt: stat.mtime.toISOString() }
    if (hash) {
      if (stat.size > 4 * 1024 * 1024) return { ...result, digestState: 'size-limit' }
      result.sha256 = digest(fs.readFileSync(file))
    }
    return result
  } catch (error) {
    return { state: error.code === 'ENOENT' ? 'missing' : 'unavailable' }
  }
}

report.checks.bundle = metadata(app, { directory: true })
if (report.checks.bundle.state !== 'present' || path.extname(app) !== '.app') {
  blocked('BUNDLE_UNAVAILABLE', 'An ordinary application bundle without symlinks is required.')
} else {
  const signature = command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app])
  report.checks.bundleSignature = signature.ok ? 'valid' : 'invalid-or-unavailable'
  if (!signature.ok) blocked('BUNDLE_SIGNATURE', 'The complete application signature must verify.')
  const packaged = command(process.execPath, [path.join(root, 'package-core.mjs'), '--verify', app])
  report.checks.coreManifest = packaged.ok ? 'valid' : 'invalid-or-unavailable'
  if (!packaged.ok) blocked('CORE_PACKAGE', 'The independent core/database package must verify.')

  const helper = path.join(app, 'Contents/Helpers/tez-native-host')
  const expectedResources = path.join(app, 'Contents/Resources')
  const resolvedResources = path.resolve(path.dirname(helper), '../Resources')
  report.checks.resourceLayout = resolvedResources === expectedResources ? 'matches-tauri-source-layout' : 'mismatch'
  report.checks.resourceRuntime = 'not-executed'
  report.checks.dnsScripts = Object.fromEntries(['set_dns.sh', 'unset_dns.sh'].map(name =>
    [name, metadata(path.join(expectedResources, 'resources', name), { hash: true })]))
  if (Object.values(report.checks.dnsScripts).some(item => item.state !== 'present')) {
    blocked('DNS_SCRIPTS', 'Production DNS setup and restoration require both packaged scripts.')
  }
}

report.checks.dataDirectory = metadata(data, { directory: true })
report.checks.configFiles = Object.fromEntries(['profiles.yaml', 'tez.yaml', 'config.yaml'].map(name =>
  [name, metadata(path.join(data, name), { hash: true })]))
if (report.checks.dataDirectory.state !== 'present' || Object.values(report.checks.configFiles).some(item =>
  item.state !== 'present' || item.uid !== process.getuid() || item.digestState === 'size-limit')) {
  blocked('CONFIG_SOURCE', 'Existing owned ordinary configuration files must be readable before backup planning.')
}
report.checks.singletonFile = metadata(path.join(data, 'singleton-instance.lock'))
report.checks.singletonOwnership = 'not-probed-no-lock-acquired'
report.checks.serviceOwnership = 'not-probed-no-service-request'
report.checks.backup = 'not-created'

for (const [name, args] of [['systemProxy', ['--proxy']], ['systemDNS', ['--dns']]]) {
  const value = command('/usr/sbin/scutil', args)
  report.checks[name] = value.ok ? { state: 'captured', sha256: digest(value.bytes), bytes: value.bytes.length } : { state: 'unavailable' }
  if (!value.ok) blocked('NETWORK_BASELINE', `Read-only ${name} inspection was unavailable.`)
}

const processes = command('/bin/ps', ['-axo', 'pid=,comm='])
if (processes.ok) {
  const names = new Set(['mihomo', 'mihomo-alpha', 'tez-service', 'verge-mihomo', 'verge-mihomo-alpha', 'clash-verge-service', 'tez-native-host', 'TezNativePreview', 'Tez', 'tez'])
  report.checks.relatedProcesses = processes.bytes.toString('utf8').split('\n').flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(.+)$/)
    if (!match) return []
    const name = path.basename(match[2])
    return names.has(name) ? [{ pid: Number(match[1]), name }] : []
  })
  if (report.checks.relatedProcesses.some(item => ['mihomo', 'mihomo-alpha', 'verge-mihomo', 'verge-mihomo-alpha'].includes(item.name))) {
    blocked('ACTIVE_CORE', 'A core is present; do not stop it or acquire its service without user confirmation.')
  }
} else {
  report.checks.relatedProcesses = { state: 'unavailable' }
  blocked('PROCESS_BASELINE', 'Read-only process inspection was unavailable.')
}

blocked('OWNERSHIP_UNCONFIRMED', 'This preflight does not prove an idle service or an available singleton lock.')
blocked('RECOVERY_NOT_ACCEPTED', 'Confirmed backup, production rollback and system-network restoration acceptance remain pending.')
blocked('FULL_PARITY_PENDING', 'Remaining native functionality must pass acceptance before replacement.')
blocked('USER_SWITCH_CONFIRMATION', 'Ask the user before stopping the old core, enabling a new core, or changing system networking.')
console.log(JSON.stringify(report, null, 2))
process.exitCode = 2
