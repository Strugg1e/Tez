import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const isObject = (value) =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
const isName = (value) => typeof value === 'string' && /^[\w-]+$/.test(value)
const isEventName = (value) =>
  typeof value === 'string' && /^[\w:/.-]+$/.test(value)
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

export function runParity(root, mode = '--check', output = console) {
  if (!['--sync', '--check', '--release'].includes(mode)) {
    throw new Error('Usage: check-native-parity.mjs [--sync|--check|--release]')
  }
  root = fs.realpathSync(root)
  const inside = (file) => file.startsWith(`${root}${path.sep}`)
  const repositoryFile = (relative, mustExist = true) => {
    if (
      typeof relative !== 'string' ||
      !relative.trim() ||
      path.isAbsolute(relative)
    ) {
      throw new Error(`Invalid repository path: ${relative}`)
    }
    const file = path.resolve(root, relative)
    if (
      !inside(file) ||
      (mustExist && !fs.existsSync(file)) ||
      (fs.existsSync(file) &&
        (!inside(fs.realpathSync(file)) || !fs.statSync(file).isFile()))
    ) {
      throw new Error(`Invalid repository path: ${relative}`)
    }
    return file
  }
  const manifestPath = path.join(root, 'native/migration/parity.json')
  const inventory = new Map()
  const inputs = new Map()
  const read = (file) => {
    const text = fs.readFileSync(repositoryFile(file), 'utf8')
    inputs.set(file, text)
    return text
  }
  const add = (id, source) => {
    const sources = inventory.get(id) ?? new Set()
    sources.add(source)
    inventory.set(id, sources)
  }
  const parse = (name, text) => {
    const source = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true)
    if (source.parseDiagnostics.length)
      throw new Error(`Invalid TypeScript source: ${name}`)
    return source
  }
  const visit = (node, action) => {
    action(node)
    ts.forEachChild(node, (child) => visit(child, action))
  }
  const bindingsPath = 'src/services/bindings.ts'
  visit(parse(bindingsPath, read(bindingsPath)), (node) => {
    if (
      ts.isCallExpression(node) &&
      node.expression.getText() === '__TAURI_INVOKE'
    ) {
      const name = node.arguments[0]
      if (!name || !ts.isStringLiteral(name) || !isName(name.text))
        throw new Error('Unrecognized command binding')
      add(`command:${name.text}`, bindingsPath)
    }
    if (
      ts.isTypeAliasDeclaration(node) &&
      node.name.text === 'VergeEventPayloads'
    ) {
      if (!ts.isTypeLiteralNode(node.type))
        throw new Error('Unrecognized event contract')
      for (const member of node.type.members) {
        if (
          !member.name ||
          !ts.isStringLiteral(member.name) ||
          !isEventName(member.name.text)
        )
          throw new Error('Unrecognized event name')
        add(`event:${member.name.text}`, bindingsPath)
      }
    }
  })
  const scan = (directory) => {
    for (const entry of fs.readdirSync(path.join(root, directory), {
      withFileTypes: true,
    })) {
      const file = `${directory}/${entry.name}`
      if (entry.isSymbolicLink())
        throw new Error(`Unsupported source symlink: ${file}`)
      if (entry.isDirectory()) scan(file)
      else if (/\.tsx?$/.test(file) && !/\.(test|spec)\.tsx?$/.test(file)) {
        const text = fs.readFileSync(repositoryFile(file), 'utf8')
        visit(parse(file, text), (node) => {
          if (
            ts.isCallExpression(node) &&
            (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
              node.expression.getText() === 'require') &&
            node.arguments[0] &&
            ts.isStringLiteral(node.arguments[0]) &&
            node.arguments[0].text === 'tauri-plugin-mihomo-api'
          ) {
            throw new Error(`Unsupported Mihomo import: ${file}`)
          }
          if (
            ts.isExportDeclaration(node) &&
            node.moduleSpecifier &&
            ts.isStringLiteral(node.moduleSpecifier) &&
            node.moduleSpecifier.text === 'tauri-plugin-mihomo-api'
          )
            throw new Error(`Unsupported Mihomo import: ${file}`)
          if (
            ts.isImportEqualsDeclaration(node) &&
            ts.isExternalModuleReference(node.moduleReference) &&
            node.moduleReference.expression?.text === 'tauri-plugin-mihomo-api'
          )
            throw new Error(`Unsupported Mihomo import: ${file}`)
          if (
            !ts.isImportDeclaration(node) ||
            node.moduleSpecifier.text !== 'tauri-plugin-mihomo-api'
          )
            return
          if (node.importClause?.isTypeOnly) return
          const imports = node.importClause?.namedBindings
          if (
            node.importClause?.name ||
            !imports ||
            !ts.isNamedImports(imports)
          )
            throw new Error(`Unsupported Mihomo import: ${file}`)
          for (const item of imports.elements) {
            if (!item.isTypeOnly) {
              const name = (item.propertyName ?? item.name).text
              if (!isName(name))
                throw new Error(`Unsupported Mihomo import: ${file}`)
              add(`mihomo:${name}`, file)
              inputs.set(file, text)
            }
          }
        })
      }
    }
  }
  scan('src')
  const workflows = JSON.parse(read('native/migration/workflows.json'))
  if (!Array.isArray(workflows) || workflows.length === 0)
    throw new Error('Invalid workflow inventory')
  for (const item of workflows) {
    if (
      !isObject(item) ||
      !isName(item.id) ||
      inventory.has(`workflow:${item.id}`)
    )
      throw new Error('Invalid workflow inventory')
    read(item.source)
    add(`workflow:${item.id}`, item.source)
  }
  for (const kind of ['command', 'event', 'mihomo', 'workflow']) {
    if (![...inventory.keys()].some((id) => id.startsWith(`${kind}:`)))
      throw new Error(`Empty ${kind} inventory`)
  }
  // Acceptance covers source behavior and workflow definitions, not only binding names.
  const digest = crypto
    .createHash('sha256')
    .update(JSON.stringify([...inputs].sort(([a], [b]) => a.localeCompare(b))))
    .digest('hex')
  const hasPrevious =
    fs.existsSync(manifestPath) ||
    Boolean(fs.lstatSync(manifestPath, { throwIfNoEntry: false }))
  const previous = hasPrevious
    ? JSON.parse(
        fs.readFileSync(repositoryFile('native/migration/parity.json'), 'utf8'),
      )
    : null
  if (hasPrevious) {
    if (
      !isObject(previous) ||
      ![1, 2].includes(previous.version) ||
      !/^[a-f0-9]{64}$/.test(previous.contractDigest) ||
      !isObject(previous.entries) ||
      Object.keys(previous.entries).length === 0
    )
      throw new Error('Invalid parity manifest')
    for (const [id, entry] of Object.entries(previous.entries)) {
      if (
        !/^(command|event|mihomo|workflow):[\w:/.-]+$/.test(id) ||
        !isObject(entry) ||
        !['pending', 'verified'].includes(entry.status) ||
        !Array.isArray(entry.evidence) ||
        !Array.isArray(entry.sources) ||
        !entry.sources.length ||
        new Set(entry.sources).size !== entry.sources.length
      ) {
        throw new Error(`Invalid parity entry: ${id}`)
      }
      for (const source of entry.sources) repositoryFile(source, false)
      if (entry.status === 'verified' && !entry.evidence.length)
        throw new Error(`Missing evidence: ${id}`)
      for (const evidence of entry.evidence) repositoryFile(evidence)
    }
  }
  const sameContract =
    previous?.version === 2 && previous.contractDigest === digest
  if (mode === '--sync') {
    const entries = Object.fromEntries(
      [...inventory]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([id, sources]) => {
          const sorted = [...sources].sort()
          const unchanged =
            sameContract && same(previous.entries[id]?.sources, sorted)
          return [
            id,
            {
              status: unchanged ? previous.entries[id].status : 'pending',
              evidence: unchanged ? previous.entries[id].evidence : [],
              sources: sorted,
            },
          ]
        }),
    )
    fs.writeFileSync(
      manifestPath,
      `${JSON.stringify({ version: 2, contractDigest: digest, entries }, null, 2)}\n`,
    )
    output.log(
      `Native migration baseline: ${inventory.size} obligations. Nothing was marked verified automatically.`,
    )
    return 0
  }
  if (!sameContract)
    throw new Error(
      'Native parity baseline is missing or stale. Run --sync and review the changed contract.',
    )
  const stale = Object.keys(previous.entries).filter((id) => !inventory.has(id))
  const missing = [...inventory.keys()].filter(
    (id) => !Object.hasOwn(previous.entries, id),
  )
  if (stale.length || missing.length)
    throw new Error(
      `Parity inventory drift: ${missing.length} missing, ${stale.length} stale. Run --sync.`,
    )
  let pending = 0
  for (const [id, entry] of Object.entries(previous.entries)) {
    if (!same(entry.sources, [...inventory.get(id)].sort()))
      throw new Error(`Parity source drift: ${id}. Run --sync.`)
    if (entry.status !== 'verified') pending++
  }
  output.log(
    `Inventory covered: ${inventory.size}; verified: ${inventory.size - pending}; pending: ${pending}.`,
  )
  if (mode === '--release' && pending) {
    output.error(
      'RELEASE BLOCKED: Keep the existing Tez application. Native migration is incomplete.',
    )
    return 1
  }
  return 0
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  process.exitCode = runParity(
    path.resolve(import.meta.dirname, '..'),
    process.argv[2],
  )
}
