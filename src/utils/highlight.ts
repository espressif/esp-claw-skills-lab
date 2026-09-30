import hljs from 'highlight.js/lib/core'
import markdown from 'highlight.js/lib/languages/markdown'
import lua from 'highlight.js/lib/languages/lua'
import json from 'highlight.js/lib/languages/json'
import python from 'highlight.js/lib/languages/python'

hljs.registerLanguage('markdown', markdown)
hljs.registerLanguage('lua', lua)
hljs.registerLanguage('json', json)
hljs.registerLanguage('python', python)

export type SupportedHighlightLanguage = 'markdown' | 'lua' | 'python' | 'json'

export const FILE_EXTENSION_LANGUAGE_MAP: Record<string, SupportedHighlightLanguage> = {
  '.md': 'markdown',
  '.markdown': 'markdown',
  '.lua': 'lua',
  '.json': 'json',
  '.py': 'python',
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

export function normalizeHighlightLanguage(value?: string): SupportedHighlightLanguage | null {
  if (!value) return null

  const normalized = value.trim().toLowerCase()
  if (normalized === 'md') return 'markdown'
  if (normalized === 'markdown') return 'markdown'
  if (normalized === 'lua') return 'lua'
  if (normalized === 'json') return 'json'
  if (normalized === 'py' || normalized === 'python') return 'python'

  return null
}

export function highlightCode(code: string, language?: string): string {
  const normalized = normalizeHighlightLanguage(language)
  if (!normalized) return escapeHtml(code)

  return hljs.highlight(code, { language: normalized }).value
}
