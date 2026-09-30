import fs from 'node:fs'
import path from 'node:path'
import { ALLOWED_CATEGORIES, ALLOWED_PERIPHERALS } from '../src/config/allowlist'

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function readAppPackage(dir: string) {
  const id = path.basename(dir)
  const fail = (message: string): never => {
    throw new Error(`[apps/${id}] ${message}`)
  }
  const raw = fs.readFileSync(path.join(dir, 'launcher.json'), 'utf-8')
  if (Buffer.byteLength(raw) > 4096) fail('launcher.json exceeds 4096 bytes')
  const manifest: unknown = JSON.parse(raw)
  if (!object(manifest)) return fail('launcher.json must be an object')
  if (manifest.schema_version !== 1) fail('schema_version must be 1')
  if (!/^[A-Za-z0-9_-]{1,63}$/.test(id) || manifest.id !== id)
    fail(
      'id must match the package directory and use 1–63 ASCII letters, digits, underscores or hyphens',
    )

  function checkFile(value: unknown, extensions: string[]) {
    if (
      typeof value !== 'string' ||
      !value ||
      path.isAbsolute(value) ||
      value.includes('..') ||
      /[\\\0:]/.test(value)
    )
      return fail('unsafe package-relative path')
    if (!extensions.includes(path.extname(value))) fail(`invalid file extension: ${value}`)
    const file = path.join(dir, value)
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) fail(`missing file: ${value}`)
    if (!fs.realpathSync(file).startsWith(fs.realpathSync(dir) + path.sep))
      fail(`file escapes package: ${value}`)
    return value
  }

  const entry = checkFile(manifest.entry, ['.lua'])
  if (manifest.icon !== undefined) checkFile(manifest.icon, ['.jpg', '.jpeg'])
  if (manifest.args !== undefined && !object(manifest.args)) fail('args must be an object')
  if (manifest.display_name !== undefined && typeof manifest.display_name !== 'string')
    fail('display_name must be a string')
  if (manifest.order !== undefined && !Number.isInteger(manifest.order))
    fail('order must be an integer')
  if (manifest.visible !== undefined && typeof manifest.visible !== 'boolean')
    fail('visible must be a boolean')
  if ('simulator' in manifest || 'peripherals' in manifest)
    fail('site fields must be nested under launcher.catalog')

  // Firmware ignores this site-only extension to the runtime manifest.
  const catalog = manifest.catalog
  if (!object(catalog) || typeof catalog.description !== 'string' || !catalog.description.trim())
    return fail('launcher.catalog requires a description')
  if (catalog.author !== undefined && typeof catalog.author !== 'string')
    fail('catalog author must be a string')
  if (catalog.simulator !== undefined && typeof catalog.simulator !== 'boolean')
    fail('catalog simulator must be a boolean')
  const metadata = {
    category: catalog.category,
    tags: catalog.tags,
    peripherals: catalog.peripherals,
  }
  for (const [key, allowed] of [
    ['category', ALLOWED_CATEGORIES],
    ['peripherals', ALLOWED_PERIPHERALS],
  ] as const) {
    const values = metadata[key]
    if (key === 'peripherals' && values === undefined) continue
    if (
      !Array.isArray(values) ||
      (key === 'category' && !values.length) ||
      values.some((v) => typeof v !== 'string' || !(allowed as readonly string[]).includes(v))
    )
      fail(`invalid launcher.catalog.${key}`)
  }
  if (
    metadata.tags !== undefined &&
    (!Array.isArray(metadata.tags) || metadata.tags.some((v) => typeof v !== 'string'))
  )
    fail('catalog tags must be strings')
  const reserved = [
    ...(metadata.category as string[]),
    ...((metadata.peripherals ?? []) as string[]),
  ]
  if (((metadata.tags ?? []) as string[]).some((v) => reserved.includes(v)))
    fail('catalog tags must not repeat categories or peripherals')
  checkFile('README.md', ['.md'])
  if (fs.existsSync(path.join(dir, 'SKILL.md')))
    fail('an App must not also be published as a Skill')
  return { manifest, entry, catalog, metadata }
}
