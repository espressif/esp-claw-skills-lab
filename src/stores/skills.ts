import { ref, computed } from 'vue'
import { defineStore } from 'pinia'
import type { SkillData } from '@/types/skill'

export const useSkillsStore = defineStore('skills', () => {
  const skills = ref<SkillData[]>([])
  const loaded = ref(false)
  const activeCategory = ref<string>('featured')
  const searchQuery = ref('')

  async function load() {
    if (loaded.value) return
    try {
      const data = await import('@/generated/skills-data.json')
      skills.value = data.default as SkillData[]
      loaded.value = true
    } catch {
      skills.value = []
      loaded.value = true
    }
  }

  const featuredSkills = computed(() =>
    skills.value.filter((s) => (s as SkillData & { featured?: boolean }).featured),
  )

  const categories = computed(() => {
    const cats = new Set<string>()
    for (const skill of skills.value) {
      if (skill.metadata.category) {
        for (const c of skill.metadata.category) cats.add(c)
      }
    }
    return Array.from(cats).sort()
  })

  const allTags = computed(() => {
    const set = new Set<string>()
    for (const skill of skills.value) {
      if (skill.metadata.tags) {
        for (const t of skill.metadata.tags) set.add(t)
      }
    }
    return Array.from(set).sort()
  })

  const allPeripherals = computed(() => {
    const set = new Set<string>()
    for (const skill of skills.value) {
      if (skill.metadata.peripherals) {
        for (const p of skill.metadata.peripherals) set.add(p)
      }
    }
    return Array.from(set).sort()
  })

  const filteredSkills = computed(() => {
    if (searchQuery.value) return skills.value
    if (activeCategory.value === 'featured') return featuredSkills.value
    if (activeCategory.value === 'all') return skills.value
    return skills.value.filter((s) => s.metadata.category?.includes(activeCategory.value))
  })

  function setCategory(cat: string) {
    activeCategory.value = cat
    searchQuery.value = ''
  }

  function getSkillById(id: string): SkillData | undefined {
    return skills.value.find((s) => s.id === id)
  }

  return {
    skills,
    loaded,
    activeCategory,
    searchQuery,
    featuredSkills,
    categories,
    allTags,
    allPeripherals,
    filteredSkills,
    load,
    setCategory,
    getSkillById,
  }
})
