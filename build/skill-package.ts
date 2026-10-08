import MarkdownIt from 'markdown-it'

const markdown = new MarkdownIt()

export function parseSkillDocument(raw: string): {
  frontmatter: Record<string, unknown>
  content: string
  title: string
} {
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)
  if (!match) throw new Error('SKILL.md must start with a complete JSON frontmatter block')
  const value: unknown = JSON.parse(match[1])
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Frontmatter must be a JSON object')
  }

  const content = raw.slice(match[0].length)
  // Parse headings so fenced examples do not count as document titles.
  const tokens = markdown.parse(content, {})
  const headings = tokens.filter((token) => token.type === 'heading_open' && token.tag === 'h1')
  if (headings.length !== 1) throw new Error('SKILL.md must contain exactly one H1 heading')
  const headingIndex = tokens.indexOf(headings[0])
  return {
    frontmatter: value as Record<string, unknown>,
    content,
    title: tokens[headingIndex + 1].content.trim(),
  }
}
