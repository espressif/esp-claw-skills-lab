import MiniSearch from 'minisearch'
import type { SkillData } from '../types/skill'
// Intentionally using relative paths ('..') instead of '@' aliases
// so that this file can be easily included and reused as a submodule in other projects.

export interface ParsedSearchQuery {
  text: string
  categories: string[]
  tags: string[]
  peripherals: string[]
}

export const VALID_FILTER_PREFIXES = new Set(['t', 'tag', 'c', 'category', 'p', 'peripheral'])

const FILTER_PATTERN = /\b(category|c|tag|t|peripheral|p):(?:"([^"]+)"|([^\s]+))/gi

function normalizeFilterValue(value: string): string {
  return value.trim().toLocaleLowerCase()
}

export function parseSearchQuery(query: string): ParsedSearchQuery {
  const categories: string[] = []
  const tags: string[] = []
  const peripherals: string[] = []

  const text = query
    .replace(
      FILTER_PATTERN,
      (_, filterType: string, quoted: string | undefined, bare: string | undefined) => {
        const rawValue = (quoted ?? bare ?? '').trim()
        if (!rawValue) return ' '

        const normalizedFilterType = filterType.toLocaleLowerCase()

        if (['category', 'c'].includes(normalizedFilterType)) {
          categories.push(rawValue)
        } else if (['tag', 't'].includes(normalizedFilterType)) {
          tags.push(rawValue)
        } else {
          peripherals.push(rawValue)
        }
        return ' '
      },
    )
    .replace(/\s+/g, ' ')
    .trim()

  return { text, categories, tags, peripherals }
}

function getCategoryValues(skill: SkillData): Set<string> {
  return new Set((skill.metadata.category ?? []).map(normalizeFilterValue))
}

function getTagValues(skill: SkillData): Set<string> {
  return new Set(
    [
      ...(skill.metadata.tags ?? []),
      ...(skill.metadata.category ?? []),
      ...(skill.metadata.peripherals ?? []),
    ].map(normalizeFilterValue),
  )
}

function getPeripheralValues(skill: SkillData): Set<string> {
  return new Set((skill.metadata.peripherals ?? []).map(normalizeFilterValue))
}

function matchesFilters(skill: SkillData, parsedQuery: ParsedSearchQuery): boolean {
  const categoryValues = getCategoryValues(skill)
  const tagValues = getTagValues(skill)
  const peripheralValues = getPeripheralValues(skill)

  return (
    parsedQuery.categories.every((category) =>
      categoryValues.has(normalizeFilterValue(category)),
    ) &&
    parsedQuery.tags.every((tag) => tagValues.has(normalizeFilterValue(tag))) &&
    parsedQuery.peripherals.every((peripheral) =>
      peripheralValues.has(normalizeFilterValue(peripheral)),
    )
  )
}

export class SkillSearchEngine {
  private miniSearch: MiniSearch<SkillData>
  private skills: SkillData[]

  constructor(skills: SkillData[]) {
    this.skills = skills
    this.miniSearch = new MiniSearch<SkillData>({
      fields: ['name', 'description', 'title'],
      storeFields: ['id'],
      idField: 'id',
      searchOptions: {
        boost: { name: 2, title: 1.5 },
        fuzzy: 0.2,
        prefix: true,
      },
    })
    this.miniSearch.addAll(skills)
  }

  search(query: string): SkillData[] {
    if (!query.trim()) return []

    const parsedQuery = parseSearchQuery(query)
    const searchBase = parsedQuery.text
      ? this.miniSearch
          .search(parsedQuery.text)
          .map((hit) => this.skills.find((s) => s.id === hit.id))
          .filter((s): s is SkillData => s !== undefined)
      : this.skills

    return searchBase.filter((skill) => matchesFilters(skill, parsedQuery))
  }
}
