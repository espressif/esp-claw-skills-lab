<script setup lang="ts">
import { onMounted, computed, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import SearchBar from '@/components/SearchBar.vue'
import CategorySidebar from '@/components/CategorySidebar.vue'
import SkillGrid from '@/components/SkillGrid.vue'
import { useSkillsStore } from '@/stores/skills'
import { useSearch } from '@/composables/useSearch'

const { t } = useI18n()
const store = useSkillsStore()
const { results, search } = useSearch()

onMounted(() => {
  store.load()
})

watch(
  () => [store.loaded, store.searchQuery] as const,
  ([loaded, query]) => {
    if (!loaded) return
    search(query)
  },
  { immediate: true },
)

const displayedSkills = computed(() => {
  const entries = store.searchQuery ? results.value : store.filteredSkills
  return store.activeKind === 'all'
    ? entries
    : entries.filter((entry) => entry.kind === store.activeKind)
})
</script>

<template>
  <div class="home">
    <section class="hero">
      <div class="hero-content">
        <h1 class="hero-title">
          {{ t('hero.title') }}
          <span class="hero-highlight">{{ t('hero.titleHighlight') }}</span>
          <br />
          {{ t('hero.titleSuffix') }}
        </h1>
        <SearchBar @search="search" />
      </div>
    </section>

    <section class="main-content">
      <CategorySidebar />
      <SkillGrid :skills="displayedSkills" />
    </section>
  </div>
</template>

<style scoped>
.home {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.hero {
  display: flex;
  justify-content: center;
  border-bottom: 1px solid var(--border);
  background: radial-gradient(ellipse at 50% 80%, rgba(232, 54, 45, 0.04) 0%, transparent 60%);
}

.hero-content {
  display: flex;
  flex-direction: column;
  align-items: center;
  text-align: center;
  padding: 3.5rem 2rem 2.5rem;
  max-width: 680px;
  width: 100%;
  gap: 2rem;
}

.hero-title {
  font-size: clamp(1.5rem, 3vw, 2.2rem);
  font-weight: 700;
  letter-spacing: -0.025em;
  line-height: 1.3;
  color: var(--text-primary);
}

.hero-highlight {
  color: var(--accent-soft);
}

.main-content {
  display: flex;
  flex: 1;
  min-height: 0;
  min-width: 0;
}

@media (max-width: 900px) {
  .main-content {
    flex-direction: column;
    align-items: stretch;
  }

  .hero-content {
    padding: 2.5rem 1.5rem 2rem;
  }
}
</style>
