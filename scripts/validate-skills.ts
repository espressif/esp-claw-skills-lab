import fs from 'node:fs'
import path from 'node:path'
import matter from 'gray-matter'
import { ALLOWED_CATEGORIES, ALLOWED_PERIPHERALS } from '../src/config/allowlist'

const skillsDir = path.resolve(import.meta.dirname, '..', 'skills')

interface ValidationError {
  skill: string
  message: string
}

interface JsonMatterOptions extends matter.GrayMatterOption<string, JsonMatterOptions> {}

const errors: ValidationError[] = []

function addError(skill: string, msg: string) {
  errors.push({ skill, message: msg })
}

function validateAuthor(skill: string, author: unknown) {
  if (typeof author !== 'string' || !author.trim()) {
    addError(skill, '`author` must be a non-empty string')
    return
  }
  if (author.includes('<') || author.includes('>')) {
    const emailPattern = /^[^<>]+<[^@<>]+@[^@<>]+\.[^@<>]+>$/
    if (!emailPattern.test(author)) {
      addError(
        skill,
        '`author` with angle brackets must contain exactly one valid email: "Name <email>"',
      )
    }
  }
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === 'string')
}

function isSafeSkillRelativePath(value: string): boolean {
  const normalized = value.replaceAll('\\', '/')
  return Boolean(normalized) && !normalized.startsWith('/') && !normalized.includes('..')
}

if (!fs.existsSync(skillsDir)) {
  console.log('No skills/ directory found. Nothing to validate.')
  process.exit(0)
}

const entries = fs.readdirSync(skillsDir, { withFileTypes: true }).filter((e) => e.isDirectory())

if (entries.length === 0) {
  console.log('No skill subdirectories found.')
  process.exit(0)
}

const seenNames = new Set<string>()

for (const entry of entries) {
  const skillId = entry.name
  const skillDir = path.join(skillsDir, skillId)
  const skillMdPath = path.join(skillDir, 'SKILL.md')

  if (!fs.existsSync(skillMdPath)) {
    addError(skillId, 'SKILL.md does not exist')
    continue
  }

  let frontmatter: Record<string, unknown>
  let content: string

  try {
    const raw = fs.readFileSync(skillMdPath, 'utf-8')
    const matterOptions: JsonMatterOptions = {
      engines: {
        json: {
          parse: (s: string) => JSON.parse(s),
          stringify: (o: unknown) => JSON.stringify(o),
        },
      },
      language: 'json',
    }
    const parsed = matter(raw, matterOptions)
    frontmatter = parsed.data
    content = parsed.content
  } catch (e) {
    addError(skillId, `Failed to parse frontmatter: ${e instanceof Error ? e.message : String(e)}`)
    continue
  }

  if (!frontmatter.name || typeof frontmatter.name !== 'string') {
    addError(skillId, '`name` must be a non-empty string')
  } else {
    if (frontmatter.name !== skillId) {
      addError(skillId, `\`name\` ("${frontmatter.name}") must match directory name ("${skillId}")`)
    }
    if (seenNames.has(frontmatter.name)) {
      addError(skillId, `Duplicate skill name: "${frontmatter.name}"`)
    }
    seenNames.add(frontmatter.name)
  }

  if (!frontmatter.description || typeof frontmatter.description !== 'string') {
    addError(skillId, '`description` must be a non-empty string')
  }

  if (frontmatter.author !== undefined) {
    validateAuthor(skillId, frontmatter.author)
  }

  const metadata = frontmatter.metadata as Record<string, unknown> | undefined
  if (!metadata || typeof metadata !== 'object') {
    addError(skillId, '`metadata` must be an object')
  } else {
    const categories = metadata.category
    if (!Array.isArray(categories) || categories.length === 0) {
      addError(skillId, '`metadata.category` must be a non-empty array')
    } else {
      for (const cat of categories) {
        if (!(ALLOWED_CATEGORIES as readonly string[]).includes(cat as string)) {
          addError(skillId, `Unknown category: "${cat}". Allowed: ${ALLOWED_CATEGORIES.join(', ')}`)
        }
      }
    }

    if (isStringArray(categories) && categories.includes('ui')) {
      const simulator = frontmatter.simulator as Record<string, unknown> | undefined
      if (!simulator || typeof simulator !== 'object') {
        addError(skillId, '`simulator` must be defined for UI skills')
      } else {
        const entryPath = simulator.entry
        const files = simulator.files
        if (typeof entryPath !== 'string' || !isSafeSkillRelativePath(entryPath)) {
          addError(skillId, '`simulator.entry` must be a safe skill-relative path')
        }
        if (!isStringArray(files) || files.length === 0) {
          addError(skillId, '`simulator.files` must be a non-empty array of skill-relative paths')
        } else {
          const normalizedFiles = files.map((file) => file.replaceAll('\\', '/'))
          for (const file of files) {
            if (!isSafeSkillRelativePath(file)) {
              addError(skillId, `Invalid simulator file path: "${file}"`)
              continue
            }
            if (!fs.existsSync(path.join(skillDir, file))) {
              addError(skillId, `Simulator file does not exist: "${file}"`)
            }
          }
          if (typeof entryPath === 'string' && !normalizedFiles.includes(entryPath.replaceAll('\\', '/'))) {
            addError(skillId, '`simulator.files` must include `simulator.entry`')
          }
        }
      }
    }

    const peripherals = metadata.peripherals
    if (peripherals !== undefined) {
      if (!isStringArray(peripherals)) {
        addError(skillId, '`metadata.peripherals` must be an array')
      } else {
        for (const p of peripherals) {
          if (!(ALLOWED_PERIPHERALS as readonly string[]).includes(p as string)) {
            addError(
              skillId,
              `Unknown peripheral: "${p}". Allowed: ${ALLOWED_PERIPHERALS.join(', ')}`,
            )
          }
        }
      }
    }

    const tags = metadata.tags
    if (tags !== undefined) {
      if (!isStringArray(tags)) {
        addError(skillId, '`metadata.tags` must be an array of strings')
      } else {
        const reservedValues = new Set<string>([
          ...(isStringArray(categories) ? categories : []),
          ...(isStringArray(peripherals) ? peripherals : []),
        ])

        for (const tag of tags) {
          if (reservedValues.has(tag)) {
            addError(skillId, `Tag "${tag}" must not duplicate a category or peripheral value`)
          }
        }
      }
    }
  }

  const h1Matches = content.match(/^#\s+.+$/gm)
  if (!h1Matches) {
    addError(skillId, 'SKILL.md must contain exactly one H1 heading')
  } else if (h1Matches.length > 1) {
    addError(skillId, `SKILL.md has ${h1Matches.length} H1 headings, expected exactly 1`)
  }
}

if (errors.length === 0) {
  console.log(`\u2705 All ${entries.length} skill(s) passed validation.`)
  process.exit(0)
} else {
  console.error(`\u274c Validation failed with ${errors.length} error(s):\n`)
  for (const err of errors) {
    console.error(`  [${err.skill}] ${err.message}`)
  }
  process.exit(1)
}
