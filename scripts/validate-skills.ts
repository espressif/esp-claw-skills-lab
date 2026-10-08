import fs from 'node:fs'
import path from 'node:path'
import { parseSkillDocument } from '../build/skill-package'
import { ALLOWED_CATEGORIES, ALLOWED_PERIPHERALS } from '../src/config/allowlist'

const skillsDir = path.resolve(import.meta.dirname, '..', 'skills')

interface ValidationError {
  skill: string
  message: string
}

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
    const parsed = parseSkillDocument(raw)
    frontmatter = parsed.frontmatter
    content = parsed.content
  } catch (e) {
    addError(skillId, `Invalid Skill document: ${e instanceof Error ? e.message : String(e)}`)
    continue
  }

  if (typeof frontmatter.name !== 'string' || !frontmatter.name.trim()) {
    addError(skillId, '`name` must be a non-empty string')
  } else {
    if (!/^[A-Za-z0-9_-]{1,63}$/.test(frontmatter.name)) {
      addError(skillId, '`name` must contain 1–63 ASCII letters, digits, underscores, or hyphens')
    }
    if (frontmatter.name !== skillId) {
      addError(skillId, `\`name\` ("${frontmatter.name}") must match directory name ("${skillId}")`)
    }
    if (seenNames.has(frontmatter.name)) {
      addError(skillId, `Duplicate skill name: "${frontmatter.name}"`)
    }
    seenNames.add(frontmatter.name)
  }

  if (typeof frontmatter.description !== 'string' || !frontmatter.description.trim()) {
    addError(skillId, '`description` must be a non-empty string')
  }

  if (frontmatter.author !== undefined) {
    validateAuthor(skillId, frontmatter.author)
  }

  const metadata = frontmatter.metadata as Record<string, unknown> | undefined
  if (
    metadata !== undefined &&
    (!metadata || typeof metadata !== 'object' || Array.isArray(metadata))
  ) {
    addError(skillId, '`metadata` must be an object')
  } else if (metadata) {
    const groups = metadata.cap_groups
    if (
      groups !== undefined &&
      (!isStringArray(groups) ||
        groups.some((group) => !group.trim()) ||
        new Set(groups).size !== groups.length)
    ) {
      addError(skillId, '`metadata.cap_groups` must contain unique non-empty strings')
    }
    const categories = metadata.category
    if (categories !== undefined && (!isStringArray(categories) || categories.length === 0)) {
      addError(skillId, '`metadata.category` must be a non-empty array')
    } else if (isStringArray(categories)) {
      for (const cat of categories) {
        if (!(ALLOWED_CATEGORIES as readonly string[]).includes(cat as string)) {
          addError(skillId, `Unknown category: "${cat}". Allowed: ${ALLOWED_CATEGORIES.join(', ')}`)
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

  // Check literal package paths, including examples passed to file tools.
  const packageRoot = fs.realpathSync(skillDir)
  for (const match of content.matchAll(/\{CUR_SKILL_DIR\}\/([^\s`"'<>()[\]{}]+)/g)) {
    const relative = match[1]
    if (
      relative.includes('\\') ||
      relative.split('/').includes('..') ||
      path.isAbsolute(relative)
    ) {
      addError(skillId, `Package reference must stay inside its Skill: "${relative}"`)
      continue
    }
    const target = path.join(skillDir, relative)
    if (!fs.existsSync(target)) {
      addError(skillId, `Package reference does not exist: "${relative}"`)
      continue
    }
    const resolved = fs.realpathSync(target)
    if (resolved !== packageRoot && !resolved.startsWith(packageRoot + path.sep)) {
      addError(skillId, `Package reference resolves outside its Skill: "${relative}"`)
    }
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
