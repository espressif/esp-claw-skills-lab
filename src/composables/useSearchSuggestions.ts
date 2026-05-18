import { computed, ref, type Ref } from 'vue'
import { useSkillsStore } from '@/stores/skills'
import { VALID_FILTER_PREFIXES } from './searchEngine'

export interface SuggestionItem {
  label: string
  /** The text to insert (may include surrounding quotes) */
  insertText: string
}

export interface SuggestionContext {
  /** The filter prefix (e.g. "t", "c", "p") */
  prefix: string
  /** What the user has typed after the colon so far */
  partial: string
  /** Whether the value is quoted */
  quoted: boolean
  /** Start index of the value portion (after colon or opening quote) in the query string */
  valueStart: number
  /** End index (cursor position) */
  valueEnd: number
}

/**
 * Resolve a filter prefix to its canonical type: 'tag' | 'category' | 'peripheral'.
 */
function canonicalType(prefix: string): 'tag' | 'category' | 'peripheral' {
  const p = prefix.toLowerCase()
  if (p === 't' || p === 'tag') return 'tag'
  if (p === 'c' || p === 'category') return 'category'
  return 'peripheral'
}

/**
 * Analyze the query string at the given cursor position and determine
 * whether we should show filter-value suggestions.
 */
export function parseSuggestionContext(query: string, cursorPos: number): SuggestionContext | null {
  const after = query.slice(cursorPos)
  if (after.length > 0 && after[0] !== ' ') return null

  let i = cursorPos - 1
  let quoted = false

  const colonSearch = () => {
    while (i >= 0) {
      const ch = query[i]
      if (ch === '"') {
        if (quoted) return null
        quoted = true
        i--
        continue
      }
      if (ch === ':') {
        const prefixStart = findPrefixStart(query, i)
        if (prefixStart === null) return null
        const prefix = query.slice(prefixStart, i)
        if (!VALID_FILTER_PREFIXES.has(prefix.toLowerCase())) return null
        const valueStart = quoted ? i + 2 : i + 1
        const partial = query.slice(valueStart, cursorPos)
        return { prefix, partial, quoted, valueStart, valueEnd: cursorPos }
      }
      if (ch === ' ') {
        if (quoted) {
          i--
          continue
        }
        return null
      }
      i--
    }
    return null
  }

  return colonSearch()
}

function findPrefixStart(query: string, colonIndex: number): number | null {
  let j = colonIndex - 1
  while (j >= 0 && /[a-zA-Z]/.test(query[j]!)) j--
  const start = j + 1
  if (start === colonIndex) return null
  if (start > 0 && query[start - 1] !== ' ') return null
  return start
}

export function useSearchSuggestions(
  query: Ref<string>,
  cursorPos: Ref<number>,
  isFocused: Ref<boolean>,
) {
  const store = useSkillsStore()
  const selectedIndex = ref(-1)

  const context = computed<SuggestionContext | null>(() => {
    if (!isFocused.value) return null
    if (!query.value) return null
    return parseSuggestionContext(query.value, cursorPos.value)
  })

  const candidates = computed<string[]>(() => {
    if (!context.value) return []
    const type = canonicalType(context.value.prefix)
    if (type === 'tag') return store.allTags
    if (type === 'category') return store.categories
    return store.allPeripherals
  })

  const suggestions = computed<SuggestionItem[]>(() => {
    const ctx = context.value
    if (!ctx) return []
    const partial = ctx.partial.toLowerCase()
    return candidates.value
      .filter((v) => v.toLowerCase().includes(partial))
      .map((v) => {
        const needsQuote = v.includes(' ')
        return {
          label: v,
          insertText: needsQuote ? `"${v}"` : v,
        }
      })
  })

  const showSyntaxHint = computed(() => isFocused.value && !query.value && !context.value)

  const showSuggestions = computed(() => suggestions.value.length > 0)

  function applySuggestion(item: SuggestionItem): { newQuery: string; newCursor: number } {
    const ctx = context.value
    if (!ctx) return { newQuery: query.value, newCursor: cursorPos.value }

    const replaceStart = ctx.quoted ? ctx.valueStart - 1 : ctx.valueStart
    const insertText = item.insertText
    const before = query.value.slice(0, replaceStart)
    const after = query.value.slice(ctx.valueEnd)
    const needsTrailingSpace = !after.startsWith(' ')
    const newQuery = before + insertText + (needsTrailingSpace ? ' ' : '') + after
    const newCursor = before.length + insertText.length + (needsTrailingSpace ? 1 : 0)

    return { newQuery, newCursor }
  }

  function resetSelection() {
    selectedIndex.value = -1
  }

  return {
    context,
    suggestions,
    showSyntaxHint,
    showSuggestions,
    selectedIndex,
    applySuggestion,
    resetSelection,
  }
}
