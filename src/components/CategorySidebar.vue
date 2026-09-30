<script setup lang="ts">
import { useI18n } from 'vue-i18n'
import { useSkillsStore } from '@/stores/skills'
import type { PackageKind } from '@/types/skill'
import { ALLOWED_CATEGORIES } from '@/config/allowlist'

const { t } = useI18n()
const store = useSkillsStore()
const kinds: (PackageKind | 'all')[] = ['all', 'app', 'skill']
</script>

<template>
  <aside class="sidebar">
    <button
      v-for="kind in kinds"
      :key="kind"
      class="sidebar-item"
      :class="{ active: store.activeKind === kind }"
      @click="store.activeKind = kind"
    >
      {{ t(`package.${kind}`) }}
    </button>
    <div class="sidebar-divider" />
    <button
      class="sidebar-item"
      :class="{ active: store.activeCategory === 'featured' }"
      @click="store.setCategory('featured')"
    >
      {{ t('category.featured') }}
    </button>
    <div class="sidebar-divider" />
    <button
      v-for="cat in ALLOWED_CATEGORIES"
      :key="cat"
      class="sidebar-item"
      :class="{ active: store.activeCategory === cat }"
      @click="store.setCategory(cat)"
    >
      {{ t(`category.${cat}`) }}
    </button>
    <div class="sidebar-divider" />
    <button
      class="sidebar-item"
      :class="{ active: store.activeCategory === 'all' }"
      @click="store.setCategory('all')"
    >
      {{ t('category.all') }}
    </button>
  </aside>
</template>

<style scoped>
.sidebar {
  display: flex;
  flex-direction: column;
  min-width: 160px;
  padding: 1rem 0;
  border-right: 1px solid var(--border);
  position: sticky;
  top: 56px;
  align-self: flex-start;
  max-height: calc(100vh - 56px);
  overflow-y: auto;
}

.sidebar-divider {
  height: 1px;
  background: var(--border);
  margin: 0.25rem 0;
}

.sidebar-item {
  display: block;
  width: 100%;
  text-align: left;
  padding: 0.6rem 1.5rem;
  font-size: 0.875rem;
  color: var(--text-secondary);
  background: none;
  border: none;
  border-left: 2px solid transparent;
  cursor: pointer;
  transition:
    color 0.15s,
    background 0.15s,
    border-color 0.15s;
  font-family: inherit;
}

.sidebar-item:hover {
  color: var(--text-primary);
  background: rgba(255, 255, 255, 0.03);
}

.sidebar-item.active {
  color: var(--accent-soft);
  border-left-color: var(--accent);
  background: var(--accent-dim);
  font-weight: 600;
}

@media (max-width: 900px) {
  .sidebar {
    flex-direction: row;
    align-self: stretch;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    box-sizing: border-box;
    border-right: none;
    border-bottom: 1px solid var(--border);
    position: static;
    max-height: none;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    padding: 0.5rem 1rem;
    gap: 0.25rem;
  }

  .sidebar-divider {
    width: 1px;
    height: auto;
    margin: 0 0.25rem;
  }

  .sidebar-item {
    width: auto;
    flex-shrink: 0;
    white-space: nowrap;
    padding: 0.4rem 0.8rem;
    border-left: none;
    border-bottom: 2px solid transparent;
    border-radius: 0;
    font-size: 0.8rem;
  }

  .sidebar-item.active {
    border-left-color: transparent;
    border-bottom-color: var(--accent);
  }
}
</style>
