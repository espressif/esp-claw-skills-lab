import { ref, watch } from 'vue'
import { useSkillsStore } from '@/stores/skills'
import type { SkillData } from '@/types/skill'
import { SkillSearchEngine } from './searchEngine'

export function useSearch() {
  const store = useSkillsStore()
  const results = ref<SkillData[]>([])
  let engine: SkillSearchEngine | null = null

  function buildIndex() {
    engine = new SkillSearchEngine(store.skills)
  }

  watch(
    () => store.loaded,
    (loaded) => {
      if (loaded) buildIndex()
    },
    { immediate: true },
  )

  function search(query: string) {
    store.searchQuery = query
    if (!query.trim() || !engine) {
      results.value = []
      return
    }

    store.activeCategory = 'all'
    results.value = engine.search(query)
  }

  return { results, search }
}
