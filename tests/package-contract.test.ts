import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { canSimulateApp, buildAppSimulatorUrl } from '../src/utils/simulator'
import { readAppPackage } from '../build/app-package'
import { SkillSearchEngine } from '../src/composables/searchEngine'
import type { SkillData } from '../src/types/skill'

function fixture() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'app-package-test-'))
  const dir = path.join(temp, 'demo')
  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'scripts/main.lua'), 'return true\n')
  fs.writeFileSync(path.join(dir, 'README.md'), '# Demo\n')
  const manifest = {
    schema_version: 1,
    id: 'demo',
    entry: 'scripts/main.lua',
    args: {},
    catalog: { description: 'Demo', category: ['utility'] },
  }
  function write(overrides: Record<string, unknown> = {}) {
    fs.writeFileSync(path.join(dir, 'launcher.json'), JSON.stringify({ ...manifest, ...overrides }))
  }
  write()
  return { dir, temp, write }
}

test('App manifest accepts an independent package and rejects invalid publication', () => {
  const { dir, temp, write } = fixture()
  try {
    assert.equal(readAppPackage(dir).entry, 'scripts/main.lua')
    const catalog = {
      description: 'Demo',
      category: ['utility'],
      tags: ['clock'],
      peripherals: ['display'],
    }
    assert.equal(fs.existsSync(path.join(dir, 'catalog.json')), false)
    write({ catalog: { ...catalog, simulator: 'true' } })
    assert.throws(() => readAppPackage(dir), /simulator must be a boolean/)
    write({ catalog: { ...catalog, simulator: true } })
    assert.equal(readAppPackage(dir).catalog.simulator, true)
    assert.deepEqual(readAppPackage(dir).metadata, {
      category: ['utility'],
      tags: ['clock'],
      peripherals: ['display'],
    })
    for (const overrides of [
      { id: 'different' },
      { schema_version: 2 },
      { entry: '../other.lua' },
      { entry: '/tmp/main.lua' },
      { entry: 'scripts\\main.lua' },
      { entry: 'missing.lua' },
      { entry: 'scripts/main.LUA' },
      { entry: 'README.md' },
      { args: [] },
      { args: null },
      { visible: 'true' },
      { order: 1.5 },
      { icon: 'missing.jpg' },
      { simulator: {} },
      { catalog: null },
      { catalog: [] },
      { catalog: { ...catalog, description: '' } },
      { catalog: { ...catalog, author: 1 } },
      { catalog: { ...catalog, category: [] } },
      { catalog: { ...catalog, category: ['invalid'] } },
      { catalog: { ...catalog, peripherals: ['invalid'] } },
      { catalog: { ...catalog, tags: [1] } },
      { catalog: { ...catalog, tags: ['display'] } },
      { catalog: { ...catalog, description: '时'.repeat(1400) } },
      { extra: 'x'.repeat(4096) },
    ]) {
      write(overrides)
      assert.throws(() => readAppPackage(dir), JSON.stringify(overrides))
    }
    write()
    fs.writeFileSync(path.join(dir, 'SKILL.md'), '# Conflicting identity\n')
    assert.throws(() => readAppPackage(dir), /also be published as a Skill/)
    fs.unlinkSync(path.join(dir, 'SKILL.md'))
    fs.writeFileSync(path.join(temp, 'outside.lua'), 'return true')
    fs.symlinkSync(path.join(temp, 'outside.lua'), path.join(dir, 'scripts/escape.lua'))
    write({ entry: 'scripts/escape.lua' })
    assert.throws(() => readAppPackage(dir), /escapes package/)
  } finally {
    fs.rmSync(temp, { recursive: true, force: true })
  }
})

test('search keeps App and Skill namespaces separate even when ids match', () => {
  const entries = (['app', 'skill'] as const).map(
    (kind): SkillData => ({
      id: 'demo',
      key: `${kind}:demo`,
      kind,
      name: 'demo',
      title: 'Demo',
      description: 'demo',
      packagePath: `${kind}s/demo`,
      rawPath: kind === 'app' ? '/raw/apps/demo' : '/raw/demo',
      readme: kind === 'app' ? 'README.md' : 'SKILL.md',
      author: '',
      metadata: { category: ['utility'] },
      extra_files: { references: [], scripts: [], assets: [] },
      files: [],
      totalSize: 0,
      lastModified: 0,
    }),
  )
  for (const entry of entries) {
    assert.equal(canSimulateApp(entry), false)
    assert.equal(canSimulateApp({ ...entry, simulator: true }), entry.kind === 'app')
  }
  const url = new URL(buildAppSimulatorUrl(entries[0]!))
  assert.equal(url.searchParams.get('app'), 'apps/demo/launcher.json')
  assert.equal(url.searchParams.has('skill'), false)
  const engine = new SkillSearchEngine(entries)
  assert.deepEqual(
    engine
      .search('demo')
      .map((entry) => entry.key)
      .sort(),
    ['app:demo', 'skill:demo'],
  )
})
