// Tests for scripts/dependabot-changeset.mjs. Run after `npm ci`:
// node --test tests/scripts/dependabot-changeset.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { getChangedPackagesSinceRef } from '@changesets/git'
import {
  changedDirs,
  changedPackageDirs,
  changesetPath,
  ignoreMatcher,
  matchesSome,
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
  assert.match(result.reason, /No versioned package has a changed file/)
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
  assert.throws(() => readConfig({ changedFilePatterns: 'src/**' }), /must be a list of patterns/)
  assert.throws(() => readConfig({ changedFilePatterns: ['src/**', 1] }), /must be a list of patterns/)
  assert.throws(() => readConfig({ changedFilePatterns: [''] }), /must be a list of patterns/)
  assert.throws(() => ignoreMatcher(['@sysvena/{a,b}']), /Unsupported ignore pattern/)
})

test('changedFilePatterns are read from the config, with the default of Changesets', () => {
  assert.deepEqual(readConfig({}).changedFilePatterns, ['**'])
  assert.deepEqual(readConfig({ changedFilePatterns: ['src/**', 'package.json'] }).changedFilePatterns, [
    'src/**',
    'package.json',
  ])
})

test('patterns match as in Changesets: no dot names, negation in list order', () => {
  assert.equal(matchesSome(['src/a.ts'], ['src/**']), true)
  assert.equal(matchesSome(['test/a.ts'], ['src/**']), false)
  assert.equal(matchesSome(['.github/dependabot.yml'], ['**']), false)
  assert.equal(matchesSome(['src/.cache/a'], ['src/**']), false)
  assert.equal(matchesSome(['.yarnrc.yml'], ['.yarnrc.yml']), true)
  assert.equal(matchesSome(['README.md'], ['**', '!**/*.md']), false)
  assert.equal(matchesSome(['README.md', 'src/a.ts'], ['**', '!**/*.md']), true)
  assert.equal(matchesSome(['README.md'], ['!**/*.md', '**']), true)
  assert.equal(matchesSome(['src/a.ts'], ['!**/*.md']), false)
  assert.equal(matchesSome([], ['**']), false)
})

// The patterns of sysvena/sysvena (.changeset/config.json): a changeset only
// for a change that reaches the image.
const appPatterns = [
  'src/**',
  'public/**',
  'types/**',
  'scripts/**',
  'package.json',
  'yarn.lock',
  '.yarnrc.yml',
  'next.config.ts',
  'postcss.config.mjs',
  'components.json',
  'tsconfig.json',
  'docker/scripts/init-or-migrate.sh',
  'docker/scripts/mcp-entrypoint.sh',
  'Dockerfile',
  '.dockerignore',
]
const singleBase = (patterns) => ({
  '.changeset/config.json': json({ ...config, privatePackages: { version: true }, changedFilePatterns: patterns }),
  'package.json': json({ name: 'canary', version: '0.0.0', private: true, devDependencies: { x: '1.0.0' } }),
  'yarn.lock': 'v1\n',
})
const single = [{ location: '.', name: 'canary' }]

test('an app with patterns: a lockfile update that the patterns match releases it', () => {
  const r = repo(singleBase(appPatterns), { 'yarn.lock': 'v2\n' })
  const result = run({ ...r, branch, listWorkspaces: () => single })
  assert.equal(result.content, '---\n"canary": patch\n---\n\nUpdate locked dependency versions.\n')
})

test('an app with patterns: an update of files the patterns do not match needs no changeset', () => {
  const r = repo(singleBase(appPatterns), {
    '.github/workflows/ci.yml': 'name: CI\n',
    'deploy/compose.yaml': 'services: {}\n',
  })
  const result = run({ ...r, branch, listWorkspaces: () => single })
  assert.equal(result.content, null)
  assert.match(result.reason, /No versioned package has a changed file that matches changedFilePatterns/)
})

test('the default patterns do not match a path that starts with a dot', () => {
  const base = singleBase(undefined)
  const r = repo(base, { '.github/workflows/ci.yml': 'name: CI\n' })
  assert.equal(run({ ...r, branch, listWorkspaces: () => single }).content, null)
})

// The script against Changesets itself (@changesets/git, a development
// dependency): for each case both must name the same changed packages, and
// the expected ones. Each case adds files on top of a base commit.
const monoFiles = {
  'package.json': json({ name: 'root', private: true, workspaces: ['packages/*'] }),
  'yarn.lock': 'v1\n',
  'packages/lib/package.json': lib(),
  'packages/app/package.json': app(),
}
const singleFiles = {
  'package.json': json({ name: 'canary', version: '0.0.0', private: true }),
  'yarn.lock': 'v1\n',
}
const cases = [
  ['app patterns: the lockfile', 'single', appPatterns, ['yarn.lock'], ['.']],
  ['app patterns: a source file', 'single', appPatterns, ['src/a.ts'], ['.']],
  ['app patterns: a dot directory under a matched directory', 'single', appPatterns, ['src/.cache/a.ts'], []],
  ['app patterns: a dot file under a matched directory', 'single', appPatterns, ['public/.well-known'], []],
  ['app patterns: dot files named literally', 'single', appPatterns, ['.dockerignore', '.yarnrc.yml'], ['.']],
  ['app patterns: a workflow', 'single', appPatterns, ['.github/workflows/ci.yml'], []],
  ['app patterns: a file outside the patterns', 'single', appPatterns, ['README.md', 'deploy/compose.yaml'], []],
  ['app patterns: a script named literally', 'single', appPatterns, ['docker/scripts/init-or-migrate.sh'], ['.']],
  ['app patterns: another file of that directory', 'single', appPatterns, ['docker/scripts/other.sh'], []],
  ['default: a plain file', 'single', ['**'], ['README.md'], ['.']],
  ['default: a dot directory', 'single', ['**'], ['.github/dependabot.yml'], []],
  ['default: a dot file', 'single', ['**'], ['.yarnrc.yml'], []],
  ['default: a changeset file', 'single', ['**'], ['.changeset/dependabot-x.md'], []],
  ['a pattern that names the changeset directory', 'single', ['.changeset/**'], ['.changeset/dependabot-x.md'], ['.']],
  ['negation: the only change is negated', 'single', ['**', '!**/*.md'], ['docs/a.md'], []],
  ['negation: another file still matches', 'single', ['**', '!**/*.md'], ['docs/a.md', 'src/a.ts'], ['.']],
  ['negation before the match does not take it back', 'single', ['!**/*.md', '**'], ['docs/a.md'], ['.']],
  ['only negated patterns never match', 'single', ['!**/*.md'], ['src/a.ts'], []],
  ['braces', 'single', ['{src,lib}/**'], ['lib/a.js'], ['.']],
  ['monorepo: paths are relative to the package', 'mono', ['src/**'], ['packages/lib/src/a.ts'], ['packages/lib']],
  ['monorepo: a file of the package outside the patterns', 'mono', ['src/**'], ['packages/lib/test/a.ts'], []],
  ['monorepo: a root file is no package', 'mono', ['src/**'], ['src/a.ts'], []],
  [
    'monorepo: two packages, one matches',
    'mono',
    ['src/**', 'package.json'],
    ['packages/lib/src/a.ts', 'packages/app/README.md', 'yarn.lock'],
    ['packages/lib'],
  ],
  ['monorepo: default patterns', 'mono', ['**'], ['packages/app/a.txt', 'yarn.lock'], ['packages/app']],
]

for (const [name, layout, patterns, files, expected] of cases) {
  test(`same changed packages as Changesets: ${name}`, async () => {
    const r = repo(layout === 'mono' ? monoFiles : singleFiles, Object.fromEntries(files.map((f) => [f, 'x\n'])))
    const ours = [
      ...changedPackageDirs({
        cwd: r.cwd,
        mergeBase: r.base,
        workspaces: layout === 'mono' ? monorepo : single,
        patterns,
      }),
    ].sort()
    const packages = await getChangedPackagesSinceRef({ cwd: r.cwd, ref: r.base, changedFilePatterns: patterns })
    const theirs = packages.map((pkg) => path.relative(r.cwd, pkg.dir) || '.').sort()
    assert.deepEqual(theirs, expected, 'Changesets itself')
    assert.deepEqual(ours, expected, 'the script')
  })
}

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
