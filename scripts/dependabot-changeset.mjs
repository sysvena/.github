#!/usr/bin/env node
// Plans the changeset that a Dependabot PR needs, so the changeset gate of
// the sysvena gates passes (sysvena/mercato-platform#15, 1.13b). Run by the
// reusable workflow .github/workflows/dependabot-changeset.yml in the
// repository of the PR.
//
// Usage: node dependabot-changeset.mjs <base commit> <PR branch>
// Prints one line of JSON: {"path": ".changeset/dependabot-<branch>.md",
// "content": "<changeset>" | null, "reason": "..."}. `content` null means the
// PR needs no changeset of its own (the file is removed if it exists).
//
// It decides which packages changed the way Changesets 3 does
// (@changesets/git getChangedPackagesSinceRef, @changesets/should-skip-package):
// a package changed when any file in its directory changed since the merge
// base; a package is versioned unless it is in `ignore`, has no `version`, or
// is private without `privatePackages.version`. Packages come from
// `yarn workspaces list` (the root only in a single-package repository), the
// config from `.changeset/config.json` of the base commit, as in the gate.
// Then:
//   - a versioned package that ships its lockfile (the lockfile is in its own
//     directory: the app of a single-package repository, whose image is built
//     from that lockfile) gets a patch release for any dependency change,
//     the lockfile alone included: what it ships changes;
//   - a versioned package whose `dependencies`, `peerDependencies` or
//     `optionalDependencies` changed gets a patch release: its consumers
//     install the new versions;
//   - otherwise (only `devDependencies` or the lockfile of a library
//     changed) the changeset is empty: the change releases nothing, which is
//     what `changeset --empty` records.
// It runs no code from the repository's dependencies and needs no install:
// only node, git and yarn (the version in packageManager, through corepack).
import { execFileSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

export const RELEASE_FIELDS = ['dependencies', 'peerDependencies', 'optionalDependencies']
export const DEV_FIELDS = ['devDependencies']
// Lockfiles of the package managers Changesets supports.
export const LOCKFILES = ['yarn.lock', 'package-lock.json', 'pnpm-lock.yaml']

// Characters a package name or a version range may contain here. Anything
// else is refused, so the changeset text stays plain.
const NAME = /^(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/
const RANGE = /^[A-Za-z0-9 @/._~^<>=*|+:-]{1,100}$/

export function changesetPath(branch) {
  const slug = branch
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) throw new Error(`Cannot name a changeset after branch '${branch}'.`)
  return `.changeset/${slug.startsWith('dependabot-') ? slug : `dependabot-${slug}`}.md`
}

// Changesets matches `ignore` with globs on package names. Only literal names
// and `*` are supported here; anything else fails, so a config this script
// does not understand cannot produce a wrong plan.
export function ignoreMatcher(patterns) {
  const regexes = patterns.map((pattern) => {
    if (typeof pattern !== 'string' || /[?[\]{}()!+@,]/.test(pattern.replace(/^@/, ''))) {
      throw new Error(`Unsupported ignore pattern in .changeset/config.json: ${JSON.stringify(pattern)}`)
    }
    const body = pattern
      .split('*')
      .map((part) => part.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&'))
      .join('[^/]*')
    return new RegExp(`^${body}$`)
  })
  return (name) => regexes.some((regex) => regex.test(name))
}

export function readConfig(config) {
  if (config.changedFilePatterns !== undefined) {
    const patterns = config.changedFilePatterns
    if (!(Array.isArray(patterns) && patterns.length === 1 && patterns[0] === '**')) {
      throw new Error('changedFilePatterns other than ["**"] is not supported; add the changeset by hand.')
    }
  }
  const privatePackages = config.privatePackages
  const versionPrivate =
    typeof privatePackages === 'object' && privatePackages !== null
      ? privatePackages.version === true
      : privatePackages === true
  return { isIgnored: ignoreMatcher(config.ignore ?? []), versionPrivate }
}

export function isVersioned(packageJson, config) {
  if (config.isIgnored(packageJson.name)) return false
  if (packageJson.private && !config.versionPrivate) return false
  return Boolean(packageJson.version)
}

// workspaces: [{location, name}] as `yarn workspaces list --json` prints them.
// Changesets (manypkg) treats the root as the package only when it is the only
// workspace.
export function packageDirs(workspaces) {
  const dirs = workspaces.length === 1 ? workspaces : workspaces.filter((w) => w.location !== '.')
  return dirs.map((w) => w.location)
}

// Assigns each changed file to the deepest package directory that contains it,
// as Changesets does. Changeset files themselves are left out.
export function changedDirs(dirs, files) {
  const remaining = files.filter((file) => !file.startsWith('.changeset/'))
  const changed = new Set()
  for (const dir of [...dirs].sort((a, b) => b.length - a.length)) {
    for (let i = remaining.length - 1; i >= 0; i--) {
      if (dir === '.' || remaining[i].startsWith(`${dir}/`)) {
        remaining.splice(i, 1)
        changed.add(dir)
      }
    }
  }
  return changed
}

export function dependencyChanges(base, head, fields) {
  const changes = []
  for (const field of fields) {
    const before = base?.[field] ?? {}
    const after = head?.[field] ?? {}
    for (const name of [...new Set([...Object.keys(before), ...Object.keys(after)])].sort()) {
      if (before[name] === after[name]) continue
      for (const value of [name, before[name], after[name]]) {
        if (value !== undefined && !(value === name ? NAME : RANGE).test(value)) {
          throw new Error(`Refusing an unexpected dependency entry in ${field}: ${JSON.stringify(value)}`)
        }
      }
      changes.push({ field, name, from: before[name], to: after[name] })
    }
  }
  return changes
}

function describe(change) {
  if (change.from === undefined) return `add \`${change.name}\` ${change.to}`
  if (change.to === undefined) return `remove \`${change.name}\``
  return `\`${change.name}\` ${change.from} → ${change.to}`
}

// packages: [{name, base, head, shipsLockfile}] for the changed versioned
// packages, with their package.json at the base and at the head, and whether
// their own directory holds the lockfile.
export function plan(branch, packages) {
  const path = changesetPath(branch)
  if (packages.length === 0) {
    return { path, content: null, reason: 'No versioned package changed: no changeset needed.' }
  }
  const release = []
  const devChanges = []
  for (const pkg of packages) {
    const changes = dependencyChanges(pkg.base, pkg.head, RELEASE_FIELDS)
    const dev = dependencyChanges(pkg.base, pkg.head, DEV_FIELDS)
    if (pkg.shipsLockfile) release.push({ name: pkg.name, changes: [...changes, ...dev] })
    else if (changes.length > 0) release.push({ name: pkg.name, changes })
    if (!pkg.shipsLockfile) devChanges.push(...dev)
  }
  if (release.length > 0) {
    const names = release.map((r) => r.name).sort()
    const listed = [...new Map(release.flatMap((r) => r.changes).map((c) => [describe(c), c])).keys()]
    const summary = listed.length > 0 ? `Update dependencies: ${listed.join(', ')}.` : 'Update locked dependency versions.'
    const content = `---\n${names.map((n) => `"${n}": patch`).join('\n')}\n---\n\n${summary}\n`
    return { path, content, reason: `Patch release of ${names.join(', ')}: what they ship changed.` }
  }
  const listed = [...new Set(devChanges.map(describe))]
  const summary =
    listed.length > 0
      ? `Update development dependencies (no release): ${listed.join(', ')}.`
      : 'Update locked dependency versions (no release).'
  return {
    path,
    content: `---\n---\n\n${summary}\n`,
    reason: 'Only development dependencies or the lockfile changed: empty changeset.',
  }
}

function git(cwd, args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
}

function showJson(cwd, rev, file) {
  try {
    return JSON.parse(git(cwd, ['show', `${rev}:${file}`]))
  } catch {
    return undefined
  }
}

function exists(cwd, rev, file) {
  try {
    git(cwd, ['cat-file', '-e', `${rev}:${file}`])
    return true
  } catch {
    return false
  }
}

// listWorkspaces: () => [{location, name}]; replaced in tests.
export function run({ cwd, base, branch, listWorkspaces }) {
  const mergeBase = git(cwd, ['merge-base', base, 'HEAD']).trim()
  const config = showJson(cwd, mergeBase, '.changeset/config.json')
  if (config === undefined) {
    return { path: changesetPath(branch), content: null, reason: 'The base commit does not use Changesets.' }
  }
  const settings = readConfig(config)
  const files = git(cwd, ['diff', '--name-only', '--no-relative', mergeBase, 'HEAD']).split('\n').filter(Boolean)
  const dirs = packageDirs(listWorkspaces())
  const changed = changedDirs(dirs, files)
  const packages = []
  for (const dir of [...changed].sort()) {
    const file = dir === '.' ? 'package.json' : `${dir}/package.json`
    const head = showJson(cwd, 'HEAD', file)
    if (head === undefined) throw new Error(`Cannot read ${file} at HEAD.`)
    if (!isVersioned(head, settings)) continue
    const shipsLockfile = LOCKFILES.some((lockfile) => exists(cwd, 'HEAD', dir === '.' ? lockfile : `${dir}/${lockfile}`))
    packages.push({ name: head.name, base: showJson(cwd, mergeBase, file), head, shipsLockfile })
  }
  return plan(branch, packages)
}

function yarnWorkspaces(cwd) {
  return execFileSync('yarn', ['workspaces', 'list', '--json'], { cwd, encoding: 'utf8' })
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line))
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const [base, branch] = process.argv.slice(2)
  if (!base || !branch) {
    console.error('Usage: node dependabot-changeset.mjs <base commit> <PR branch>')
    process.exit(2)
  }
  const cwd = process.cwd()
  console.log(JSON.stringify(run({ cwd, base, branch, listWorkspaces: () => yarnWorkspaces(cwd) })))
}
