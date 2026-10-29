import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'

const names = ['clash-verge-service', 'clash-verge-service-install', 'clash-verge-service-uninstall']
const manifestName = 'native-service-manifest.json'
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const [mode, source, destination] = process.argv.slice(2)

function executable(file) {
  const metadata = fs.lstatSync(file)
  if (!metadata.isFile() || !metadata.size || !(metadata.mode & 0o111)) throw new Error(`Missing service executable: ${file}`)
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', file], { stdio: 'pipe' })
  execFileSync('/usr/bin/lipo', [file, '-verify_arch', process.arch === 'arm64' ? 'arm64' : 'x86_64'])
}

function verify(directory, manifestDirectory = directory) {
  const manifest = JSON.parse(fs.readFileSync(path.join(manifestDirectory, manifestName), 'utf8'))
  if (manifest.version !== 1 || !['production', 'acceptance'].includes(manifest.channel) || manifest.protocol !== '2.6') {
    throw new Error('Unexpected native service manifest')
  }
  for (const name of names) {
    const file = path.join(directory, name)
    executable(file)
    if (hash(file) !== manifest.files[name]) throw new Error(`Service checksum mismatch: ${name}`)
  }
  return manifest
}

if (mode === '--prepare') {
  const channel = process.env.TEZ_NATIVE_SERVICE_CHANNEL
  if (!source || !destination || !['production', 'acceptance'].includes(channel) || fs.existsSync(destination)) {
    throw new Error('New output directory and TEZ_NATIVE_SERVICE_CHANNEL required')
  }
  fs.mkdirSync(destination, { recursive: true })
  const files = {}
  for (const name of names) {
    const file = path.join(destination, name)
    fs.copyFileSync(path.join(source, name), file, fs.constants.COPYFILE_EXCL)
    fs.chmodSync(file, 0o755)
    execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', file], { stdio: 'pipe' })
    executable(file)
    files[name] = hash(file)
  }
  fs.writeFileSync(path.join(destination, manifestName), JSON.stringify({ version: 1, channel, protocol: '2.6', files }, null, 2) + '\n')
} else if (mode === '--source-check') {
  verify(process.env.TEZ_NATIVE_SERVICE_DIR ?? '')
} else if (mode === '--copy') {
  const directory = process.env.TEZ_NATIVE_SERVICE_DIR ?? ''
  verify(directory)
  const helpers = path.join(source, 'Contents/Helpers')
  fs.mkdirSync(helpers, { recursive: true })
  for (const name of names) fs.copyFileSync(path.join(directory, name), path.join(helpers, name))
  fs.copyFileSync(path.join(directory, manifestName), path.join(source, 'Contents/Resources', manifestName))
} else if (mode === '--verify') {
  const manifest = verify(path.join(source, 'Contents/Helpers'), path.join(source, 'Contents/Resources'))
  const helper = path.join(source, 'Contents/Helpers/tez-native-host')
  const build = JSON.parse(execFileSync(helper, ['--build-info'], { encoding: 'utf8' }))
  const plist = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(source, 'Contents/Info.plist')], { encoding: 'utf8' }).trim()
  if (build.channel !== manifest.channel || (manifest.channel === 'acceptance' && (!build.lifecycleAcceptance || plist !== 'app.tez.acceptance'))) {
    throw new Error('Native helper, application identity and service channel differ')
  }
  console.log(`PASS: 3 signed native service tools, protocol ${manifest.protocol}, channel ${manifest.channel}`)
} else if (mode === '--remove') {
  for (const name of names) fs.rmSync(path.join(source, 'Contents/Helpers', name), { force: true })
  fs.rmSync(path.join(source, 'Contents/Resources', manifestName), { force: true })
} else {
  throw new Error('Usage: package-service.mjs --prepare SOURCE NEW_OUTPUT | --source-check | (--copy|--verify|--remove) APP')
}
