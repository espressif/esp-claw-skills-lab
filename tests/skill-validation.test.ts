import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

const repository = path.resolve(import.meta.dirname, '..')

test('Skill CLI rejects invalid packages without skipping links or later errors', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'skill-validation-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const collection = path.join(root, 'skills')
  const dir = path.join(collection, 'demo')
  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'scripts/main.lua'), 'return true\n')
  function write(overrides: Record<string, unknown> = {}, body = '# Demo\n') {
    const metadata = { name: 'demo', description: 'Demo skill', ...overrides }
    fs.writeFileSync(path.join(dir, 'SKILL.md'), `---\n${JSON.stringify(metadata)}\n---\n${body}`)
  }
  function run(directory = collection) {
    return spawnSync(
      process.execPath,
      ['--import', 'tsx', path.join(repository, 'scripts/validate-skills.ts'), directory],
      { cwd: repository, encoding: 'utf-8' },
    )
  }
  write({}, '# Demo\nRun `{CUR_SKILL_DIR}/scripts/main.lua`.\n')
  let result = run()
  assert.equal(result.status, 0, result.stderr)
  for (const target of ['scripts/main.lua', 'missing.lua', '.']) {
    fs.symlinkSync(target, path.join(dir, 'asset'))
    result = run()
    assert.equal(result.status, 1)
    assert.match(result.stderr, /symbolic links are not allowed/)
    fs.unlinkSync(path.join(dir, 'asset'))
  }
  fs.writeFileSync(path.join(dir, 'launcher.json'), '{}')
  result = run()
  assert.equal(result.status, 1)
  assert.match(result.stderr, /also be published as an App/)
  fs.unlinkSync(path.join(dir, 'launcher.json'))

  // Report errors across the whole collection instead of stopping at the first package.
  fs.symlinkSync(dir, path.join(collection, 'alias'))
  fs.mkdirSync(path.join(collection, 'missing_document'))
  write({ metadata: { category: ['unknown'] } }, '# Demo\n`{CUR_SKILL_DIR}/missing.lua`\n')
  result = run()
  assert.equal(result.status, 1)
  for (const error of [
    '[alias]',
    '[demo]',
    '[missing_document]',
    'Unknown category',
    'Package reference does not exist',
  ])
    assert.ok(result.stderr.includes(error), result.stderr)
  result = run(path.join(root, 'missing'))
  assert.equal(result.status, 1)
  assert.match(result.stderr, /collection directory does not exist/)
})
