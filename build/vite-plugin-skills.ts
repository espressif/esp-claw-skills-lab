import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import type { Connect } from 'vite'
import { parseSkillDocument } from './skill-package'
import { readAppPackage } from './app-package'
import type { Plugin, ViteDevServer } from 'vite'
import { FEATURED_SKILLS } from '../src/config/allowlist'

const INDEX_FILES = ['skills-data.json', 'apps-data.json', 'catalog-data.json', 'tags.json']

interface SkillExtraFiles {
  references: string[]
  scripts: string[]
  assets: string[]
}

interface SkillEntry {
  icon?: string
  simulator?: boolean
  kind: 'skill' | 'app'
  key: string
  packagePath: string
  rawPath: string
  readme: string
  id: string
  name: string
  description: string
  author: string
  title: string
  metadata: Record<string, unknown>
  extra_files: SkillExtraFiles
  files: string[]
  totalSize: number
  lastModified: number
  featured: boolean
}

interface SkillTagsIndex {
  category: string[]
  tag: string[]
  peripheral: string[]
}

function collectFiles(
  dir: string,
  base: string = '',
): { relativePaths: string[]; totalSize: number } {
  const relativePaths: string[] = []
  let totalSize = 0

  if (!fs.existsSync(dir)) return { relativePaths, totalSize }

  const entries = fs.readdirSync(dir, { withFileTypes: true })
  for (const entry of entries) {
    const rel = base ? `${base}/${entry.name}` : entry.name
    const full = path.join(dir, entry.name)
    if (entry.name === '_metadata.json') continue
    if (entry.isDirectory()) {
      const sub = collectFiles(full, rel)
      relativePaths.push(...sub.relativePaths)
      totalSize += sub.totalSize
    } else {
      relativePaths.push(rel)
      totalSize += fs.statSync(full).size
    }
  }

  return { relativePaths, totalSize }
}

function collectSubdirFiles(skillDir: string, subdir: string): string[] {
  const full = path.join(skillDir, subdir)
  if (!fs.existsSync(full)) return []
  return fs
    .readdirSync(full, { withFileTypes: true })
    .filter((e) => e.isFile())
    .map((e) => e.name)
}

function toTimestamp(value: string | number): number {
  const date = new Date(value)
  const timestamp = date.getTime()
  return Number.isNaN(timestamp) ? 0 : timestamp
}

function getGitLastModified(dir: string): number {
  try {
    const gitDate = execFileSync('git', ['log', '-1', '--format=%cI', '--', dir], {
      cwd: process.cwd(),
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()

    return gitDate ? toTimestamp(gitDate) : 0
  } catch {
    return 0
  }
}

function getMtimeLastModified(dir: string): number {
  let latest = 0
  const walk = (d: string) => {
    for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, entry.name)
      if (entry.name === '_metadata.json') continue
      if (entry.isDirectory()) {
        walk(full)
      } else {
        const stat = fs.statSync(full)
        if (stat.mtimeMs > latest) latest = stat.mtimeMs
      }
    }
  }
  walk(dir)
  return latest ? Math.trunc(latest) : 0
}

function getLastModified(dir: string): number {
  return getGitLastModified(dir) || getMtimeLastModified(dir)
}

function addStringArrayValues(target: Set<string>, value: unknown) {
  if (!Array.isArray(value)) return

  for (const item of value) {
    if (typeof item === 'string' && item.trim()) {
      target.add(item)
    }
  }
}

function buildTagsIndex(skills: SkillEntry[]): SkillTagsIndex {
  const categories = new Set<string>()
  const tags = new Set<string>()
  const peripherals = new Set<string>()

  for (const skill of skills) {
    addStringArrayValues(categories, skill.metadata.category)
    addStringArrayValues(tags, skill.metadata.tags)
    addStringArrayValues(peripherals, skill.metadata.peripherals)
  }

  return {
    category: Array.from(categories).sort(),
    tag: Array.from(tags).sort(),
    peripheral: Array.from(peripherals).sort(),
  }
}

function copyDir(src: string, dest: string) {
  fs.mkdirSync(dest, { recursive: true })
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath = path.join(src, entry.name)
    const destPath = path.join(dest, entry.name)
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath)
    } else {
      fs.copyFileSync(srcPath, destPath)
    }
  }
}

const skillsRootResolved = (skillsDir: string) => path.resolve(skillsDir) + path.sep

function contentTypeFor(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase()
  const map: Record<string, string> = {
    '.md': 'text/markdown; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.yaml': 'text/yaml; charset=utf-8',
    '.yml': 'text/yaml; charset=utf-8',
    '.txt': 'text/plain; charset=utf-8',
    '.py': 'text/plain; charset=utf-8',
    '.sh': 'text/plain; charset=utf-8',
    '.ts': 'text/typescript; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.vue': 'text/plain; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.bin': 'application/octet-stream',
  }
  return map[ext] ?? 'application/octet-stream'
}

/** Dev-only: mirror production static `/raw/*` (see writeBundle → dist/raw). */
function rawSkillsMiddleware(skillsDir: string, prefix = '/raw/'): Connect.NextHandleFunction {
  const root = skillsRootResolved(skillsDir)

  return (req, res, next) => {
    const rawUrl = req.url
    if (!rawUrl?.startsWith(prefix)) {
      next()
      return
    }

    let pathname = rawUrl.split('?')[0]
    try {
      pathname = decodeURIComponent(pathname)
    } catch {
      res.statusCode = 400
      res.end('Bad Request')
      return
    }

    const rel = pathname.slice(prefix.length).replace(/^\/+/, '')
    if (!rel || rel.includes('\0')) {
      res.statusCode = 404
      res.end('Not Found')
      return
    }

    const abs = path.resolve(skillsDir, rel)
    if (!abs.startsWith(root)) {
      res.statusCode = 403
      res.end('Forbidden')
      return
    }

    let stat: fs.Stats
    try {
      stat = fs.statSync(abs)
    } catch {
      res.statusCode = 404
      res.end('Not Found')
      return
    }

    if (!stat.isFile()) {
      res.statusCode = 404
      res.end('Not Found')
      return
    }

    res.setHeader('Content-Type', contentTypeFor(abs))
    res.setHeader('Content-Length', stat.size)
    fs.createReadStream(abs).pipe(res)
  }
}

export default function skillsPlugin(): Plugin {
  const skillsDir = path.resolve(process.cwd(), 'skills')
  const appsDir = path.resolve(process.cwd(), 'apps')
  const generatedDir = path.resolve(process.cwd(), 'src/generated')

  return {
    name: 'vite-plugin-skills',
    enforce: 'pre',
    configureServer(server: ViteDevServer) {
      server.middlewares.use((req, res, next) => {
        const filename = req.url?.split('?')[0].replace(/^\/raw\//, '')
        if (req.url?.startsWith('/raw/') && filename && INDEX_FILES.includes(filename)) {
          return rawSkillsMiddleware(generatedDir)(req, res, next)
        }
        next()
      })
      server.middlewares.use(rawSkillsMiddleware(appsDir, '/raw/apps/'))
      server.middlewares.use(rawSkillsMiddleware(skillsDir))
    },
    buildStart() {
      fs.mkdirSync(generatedDir, { recursive: true })

      const skills: SkillEntry[] = []
      for (const kind of ['skill', 'app'] as const) {
        const root = kind === 'app' ? appsDir : skillsDir
        if (!fs.existsSync(root)) continue
        const entries = fs.readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory())
        for (const entry of entries) {
          const skillDir = path.join(root, entry.name)
          let fm: Record<string, unknown>
          let title: string
          let icon: string | undefined
          if (kind === 'app') {
            const app = readAppPackage(skillDir)
            fm = { ...app.catalog, metadata: app.metadata, name: entry.name }
            title = String(app.manifest.display_name || entry.name)
            icon = app.manifest.icon as string | undefined
          } else {
            const skillMdPath = path.join(skillDir, 'SKILL.md')
            if (!fs.existsSync(skillMdPath)) continue
            const parsed = parseSkillDocument(fs.readFileSync(skillMdPath, 'utf-8'))
            fm = parsed.frontmatter
            title = parsed.title
          }
          const meta = (fm.metadata ?? {}) as Record<string, unknown>

          const extraFiles: SkillExtraFiles = {
            references: collectSubdirFiles(skillDir, 'references'),
            scripts: collectSubdirFiles(skillDir, 'scripts'),
            assets: collectSubdirFiles(skillDir, 'assets'),
          }

          const { relativePaths, totalSize } = collectFiles(skillDir)
          const lastModified = getLastModified(skillDir)
          const isFeatured = FEATURED_SKILLS.includes(fm.name as string)

          const skillData: SkillEntry = {
            icon,
            simulator: kind === 'app' && fm.simulator === true,
            kind,
            key: `${kind}:${entry.name}`,
            packagePath: `${kind}s/${entry.name}`,
            rawPath: kind === 'app' ? `/raw/apps/${entry.name}` : `/raw/${entry.name}`,
            readme: kind === 'app' ? 'README.md' : 'SKILL.md',
            id: entry.name,
            name: (fm.name as string) || entry.name,
            description: (fm.description as string) || '',
            author: (fm.author as string) || '',
            title,
            metadata: meta,
            extra_files: extraFiles,
            files: relativePaths,
            totalSize,
            lastModified,
            featured: isFeatured,
          }

          skills.push(skillData)

          const metadataJson = {
            simulator: kind === 'app' && fm.simulator === true,
            kind,
            files: skillData.files,
            name: skillData.name,
            description: skillData.description,
            author: skillData.author,
            last_modified: skillData.lastModified,
            metadata: meta,
            extra_files: extraFiles,
          }
          fs.writeFileSync(
            path.join(skillDir, '_metadata.json'),
            JSON.stringify(metadataJson, null, 2),
            'utf-8',
          )
        }
      }
      for (const kind of ['skill', 'app'] as const) {
        fs.writeFileSync(
          path.join(generatedDir, `${kind}s-data.json`),
          JSON.stringify(skills.filter((entry) => entry.kind === kind)),
          'utf-8',
        )
      }
      fs.writeFileSync(
        path.join(generatedDir, 'catalog-data.json'),
        JSON.stringify(skills),
        'utf-8',
      )
      fs.writeFileSync(
        path.join(generatedDir, 'tags.json'),
        JSON.stringify(buildTagsIndex(skills)),
        'utf-8',
      )
    },

    writeBundle(options) {
      const outDir = options.dir || path.resolve(process.cwd(), 'dist')
      const rawDest = path.join(outDir, 'raw')
      if (fs.existsSync(skillsDir)) copyDir(skillsDir, rawDest)
      if (fs.existsSync(appsDir)) copyDir(appsDir, path.join(rawDest, 'apps'))
      fs.mkdirSync(rawDest, { recursive: true })
      for (const file of INDEX_FILES) {
        fs.copyFileSync(path.join(generatedDir, file), path.join(rawDest, file))
      }
    },
  }
}
