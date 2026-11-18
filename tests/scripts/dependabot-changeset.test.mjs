// Tests for scripts/dependabot-changeset.mjs. Run: node --test tests/scripts/
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  changedDirs,
  changesetPath,
  ignoreMatcher,
  packageDirs,
  plan,
  readConfig,
  run,
} from '../../scripts/dependabot-changeset.mjs'

const json = (value) => `${JSON.stringify(value, null, 2)}\n`

// repo(base files, head files): a git repository with a base commit and a
// commit on top, like a Dependabot branch. Files map path -> content, null
// removes. Returns {cwd, base}.
function repo(baseFiles, headFiles) {
  const cwd = mkdtempSync(path.join(tmpdir(), 'dependabot-changeset-'))
  const g = (...args) => execFileSync('git', args, { cwd, encoding: 'utf8' })
  const write = (files) => {
    for (const [file, content] of Object.entries(files)) {
      const full = path.join(cwd, file)
      if (content === null) {
        rmSync(full)
      } else {
        mkdirSync(path.dirname(full), { recursive: true })
        writeFileSync(full, content)
      }
    }
  }
  g('init', '-q', '-b', 'main')
  g('config', 'user.email', 'test@example.invalid')
  g('config', 'user.name', 'test')
  write(baseFiles)
  g('add', '-A')
  g('commit', '-qm', 'base')
  const base = g('rev-parse', 'HEAD').trim()
  write(headFiles)
  g('add', '-A')
  g('commit', '-qm', 'head')
  test.after(() => rmSync(cwd, { recursive: true, force: true }))
  return { cwd, base }
}

const config = { ignore: [] }
const branch = 'dependabot/npm_and_yarn/ms-2.1.3'
const monorepo = [
  { location: '.', name: 'root' },
  { location: 'packages/lib', name: '@sysvena/lib' },
  { location: 'packages/app', name: '@sysvena/app' },
]
const lib = (deps = {}, dev = {}, extra = {}) =>
  json({ name: '@sysvena/lib', version: '1.0.0', dependencies: deps, devDependencies: dev, ...extra })
const app = (dev = {}) => json({ name: '@sysvena/app', version: '1.0.0', private: true, devDependencies: dev })
const monorepoBase = {
  '.changeset/config.json': json(config),
  'package.json': json({
    name: 'root',
    private: true,
    workspaces: ['packages/*'],
    devDependencies: { typescript: '7.0.2' },
  }),
  'yarn.lock': 'v1\n',
  'packages/lib/package.json': lib({ ms: '2.1.2' }, { vitest: '4.0.0' }),
  'packages/app/package.json': app({ ms: '2.1.2' }),
}
const runMono = (head, base = monorepoBase) => {
  const r = repo(base, head)
  return run({ ...r, branch, listWorkspaces: () => monorepo })
}

test('a runtime dependency update releases the package as a patch', () => {
  const result = runMono({
    'packages/lib/package.json': lib({ ms: '2.1.3' }, { vitest: '4.0.0' }),
    'yarn.lock': 'v2\n',
  })
  assert.equal(result.path, '.changeset/dependabot-npm-and-yarn-ms-2-1-3.md')
  assert.equal(result.content, '---\n"@sysvena/lib": patch\n---\n\nUpdate dependencies: `ms` 2.1.2 → 2.1.3.\n')
})

test('peer and optional dependencies release too', () => {
  const result = runMono({
    'packages/lib/package.json': lib(
      { ms: '2.1.2' },
      { vitest: '4.0.0' },
      { peerDependencies: { react: '^19.0.0' }, optionalDependencies: { fsevents: '2.3.3' } },
    ),
  })
  assert.match(result.content, /^---\n"@sysvena\/lib": patch\n---\n/)
  // Listed field by field (dependencies, peer, optional), names sorted in each.
  assert.match(result.content, /: add `react` \^19\.0\.0, add `fsevents` 2\.3\.3\.\n$/)
})

test('a development dependency update gets an empty changeset', () => {
  const result = runMono({
    'packages/lib/package.json': lib({ ms: '2.1.2' }, { vitest: '4.0.1' }),
    'yarn.lock': 'v2\n',
  })
  assert.equal(result.content, '---\n---\n\nUpdate development dependencies (no release): `vitest` 4.0.0 → 4.0.1.\n')
})

test('a root-only update (not a package of a monorepo) needs no changeset', () => {
  const result = runMono({
    'package.json': json({
      name: 'root',
      private: true,
      workspaces: ['packages/*'],
      devDependencies: { typescript: '7.0.3' },
    }),
    'yarn.lock': 'v2\n',
  })
  assert.equal(result.content, null)
  assert.match(result.reason, /No versioned package changed/)
})

test('a private package is not versioned by default', () => {
  const result = runMono({ 'packages/app/package.json': app({ ms: '2.1.3' }) })
  assert.equal(result.content, null)
})

test('a private package is versioned with privatePackages.version', () => {
  const base = {
    ...monorepoBase,
    '.changeset/config.json': json({ ...config, privatePackages: { version: true, tag: false } }),
  }
  const result = runMono({ 'packages/app/package.json': app({ ms: '2.1.3' }) }, base)
  assert.equal(result.content, '---\n---\n\nUpdate development dependencies (no release): `ms` 2.1.2 → 2.1.3.\n')
})

test("the config of the base commit applies, not the PR's", () => {
  const result = runMono({
    '.changeset/config.json': json({ ...config, ignore: ['@sysvena/lib'] }),
    'packages/lib/package.json': lib({ ms: '2.1.3' }, { vitest: '4.0.0' }),
  })
  assert.match(result.content, /"@sysvena\/lib": patch/)
})

test('an ignored package (glob) is not versioned', () => {
  const base = { ...monorepoBase, '.changeset/config.json': json({ ignore: ['@sysvena/l*'] }) }
  const result = runMono({ 'packages/lib/package.json': lib({ ms: '2.1.3' }, { vitest: '4.0.0' }) }, base)
  assert.equal(result.content, null)
})

test('a package without a version is not versioned', () => {
  const base = {
    ...monorepoBase,
    'packages/lib/package.json': json({ name: '@sysvena/lib', dependencies: { ms: '2.1.2' } }),
  }
  const result = runMono(
    { 'packages/lib/package.json': json({ name: '@sysvena/lib', dependencies: { ms: '2.1.3' } }) },
    base,
  )
  assert.equal(result.content, null)
})

test('several packages: only those whose runtime dependencies changed are released', () => {
  const base = { ...monorepoBase, '.changeset/config.json': json({ ...config, privatePackages: true }) }
  const result = runMono(
    {
      'packages/lib/package.json': lib({ ms: '2.1.3' }, { vitest: '4.0.0' }),
      'packages/app/package.json': app({ ms: '2.1.3' }),
    },
    base,
  )
  assert.equal(result.content, '---\n"@sysvena/lib": patch\n---\n\nUpdate dependencies: `ms` 2.1.2 → 2.1.3.\n')
})

test('single-package repository: an app ships its lockfile, so a lockfile update releases it', () => {
  const single = {
    '.changeset/config.json': json({ ...config, privatePackages: { version: true } }),
    'package.json': json({ name: 'canary', version: '0.0.0', private: true, devDependencies: { x: '1.0.0' } }),
    'yarn.lock': 'v1\n',
  }
  const r = repo(single, { 'yarn.lock': 'v2\n' })
  const result = run({ ...r, branch, listWorkspaces: () => [{ location: '.', name: 'canary' }] })
  assert.equal(result.content, '---\n"canary": patch\n---\n\nUpdate locked dependency versions.\n')
})

test('single-package repository: a development dependency of an app releases it too', () => {
  const single = {
    '.changeset/config.json': json({ ...config, privatePackages: { version: true } }),
    'package.json': json({ name: 'canary', version: '0.0.0', private: true, devDependencies: { x: '1.0.0' } }),
    'yarn.lock': 'v1\n',
  }
  const r = repo(single, {
    'package.json': json({ name: 'canary', version: '0.0.0', private: true, devDependencies: { x: '1.0.1' } }),
    'yarn.lock': 'v2\n',
  })
  const result = run({ ...r, branch, listWorkspaces: () => [{ location: '.', name: 'canary' }] })
  assert.equal(result.content, '---\n"canary": patch\n---\n\nUpdate dependencies: `x` 1.0.0 → 1.0.1.\n')
})

test('monorepo: the root lockfile does not release the packages', () => {
  const result = runMono({ 'yarn.lock': 'v2\n', 'packages/lib/package.json': lib({ ms: '2.1.2' }, { vitest: '4.0.1' }) })
  assert.equal(result.content, '---\n---\n\nUpdate development dependencies (no release): `vitest` 4.0.0 → 4.0.1.\n')
})

test('single-package repository: a runtime dependency releases the root package', () => {
  const single = {
    '.changeset/config.json': json({ ...config, privatePackages: { version: true } }),
    'package.json': json({ name: 'canary', version: '0.0.0', private: true, dependencies: { ms: '2.1.2' } }),
  }
  const r = repo(single, {
    'package.json': json({ name: 'canary', version: '0.0.0', private: true, dependencies: { ms: '2.1.3' } }),
  })
  const result = run({ ...r, branch, listWorkspaces: () => [{ location: '.', name: 'canary' }] })
  assert.equal(result.content, '---\n"canary": patch\n---\n\nUpdate dependencies: `ms` 2.1.2 → 2.1.3.\n')
})

test('no Changesets on the base commit: no changeset', () => {
  const { ['.changeset/config.json']: _, ...base } = monorepoBase
  const result = runMono({ 'packages/lib/package.json': lib({ ms: '2.1.3' }, { vitest: '4.0.0' }) }, base)
  assert.equal(result.content, null)
  assert.match(result.reason, /does not use Changesets/)
})

test('its own changeset file does not count as a change', () => {
  const result = runMono({ '.changeset/dependabot-npm-and-yarn-ms-2-1-3.md': '---\n---\n\nx\n' })
  assert.equal(result.content, null)
})

test('a dependency entry with unexpected characters is refused', () => {
  assert.throws(
    () => runMono({ 'packages/lib/package.json': lib({ ms: '2.1.3`; echo' }, { vitest: '4.0.0' }) }),
    /unexpected dependency entry/,
  )
})

test('unsupported config is refused', () => {
  assert.throws(() => readConfig({ changedFilePatterns: ['src/**'] }), /not supported/)
  assert.doesNotThrow(() => readConfig({ changedFilePatterns: ['**'] }))
  assert.throws(() => ignoreMatcher(['@sysvena/{a,b}']), /Unsupported ignore pattern/)
})

test('ignore globs match names like Changesets', () => {
  const isIgnored = ignoreMatcher(['@sysvena/*', 'exact'])
  assert.equal(isIgnored('@sysvena/lib'), true)
  assert.equal(isIgnored('@other/lib'), false)
  assert.equal(isIgnored('exact'), true)
  assert.equal(isIgnored('exactly'), false)
})

test('files go to the deepest package directory', () => {
  const dirs = packageDirs(monorepo)
  assert.deepEqual(dirs, ['packages/lib', 'packages/app'])
  assert.deepEqual([...changedDirs(dirs, ['packages/lib/src/a.ts', 'README.md', 'packages/libx/a'])], ['packages/lib'])
  assert.deepEqual(packageDirs([{ location: '.', name: 'x' }]), ['.'])
})

test('changeset file names are stable per branch', () => {
  assert.equal(
    changesetPath('dependabot/npm_and_yarn/npm-dependencies-1a2b3c'),
    '.changeset/dependabot-npm-and-yarn-npm-dependencies-1a2b3c.md',
  )
  assert.equal(changesetPath('feature/x'), '.changeset/dependabot-feature-x.md')
  assert.throws(() => changesetPath('///'), /Cannot name/)
})

test('plan with no changed packages', () => {
  assert.equal(plan(branch, []).content, null)
})
