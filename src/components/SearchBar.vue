<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useI18n } from 'vue-i18n'
import { Search } from '@lucide/vue'
import { useSkillsStore } from '@/stores/skills'
import { useSearchSuggestions, type SuggestionItem } from '@/composables/useSearchSuggestions'

const { t } = useI18n()
const emit = defineEmits<{ search: [query: string] }>()
const store = useSkillsStore()
const query = ref('')
const cursorPos = ref(0)
const isFocused = ref(false)
const inputRef = ref<HTMLInputElement | null>(null)
const dropdownRef = ref<HTMLDivElement | null>(null)

const {
  context,
  suggestions,
  showSyntaxHint,
  showSuggestions,
  selectedIndex,
  applySuggestion,
  resetSelection,
} = useSearchSuggestions(query, cursorPos, isFocused)

const syntaxHints = [
  { prefix: 't:', example: 'info', descKey: 'hero.syntaxTagDesc' },
  { prefix: 'p:', example: 'display', descKey: 'hero.syntaxPeripheralDesc' },
  { prefix: 'c:', example: 'media', descKey: 'hero.syntaxCategoryDesc' },
]

function onClickSyntaxHint(prefix: string) {
  const pos = cursorPos.value
  const before = query.value.slice(0, pos)
  const after = query.value.slice(pos)
  const needLeadingSpace = before.length > 0 && !before.endsWith(' ')
  const insert = (needLeadingSpace ? ' ' : '') + prefix
  query.value = before + insert + after
  const newCursor = pos + insert.length
  cursorPos.value = newCursor
  nextTick(() => {
    inputRef.value?.focus()
    inputRef.value?.setSelectionRange(newCursor, newCursor)
  })
}

function updateCursorPos() {
  cursorPos.value = inputRef.value?.selectionStart ?? query.value.length
}

function onInput() {
  updateCursorPos()
  resetSelection()
  emit('search', query.value)
}

let blurTimer: ReturnType<typeof setTimeout> | null = null

function clearBlurTimer() {
  if (blurTimer !== null) {
    clearTimeout(blurTimer)
    blurTimer = null
  }
}

function onFocus() {
  clearBlurTimer()
  isFocused.value = true
  updateCursorPos()
}

function onBlur() {
  clearBlurTimer()
  blurTimer = setTimeout(() => {
    blurTimer = null
    isFocused.value = false
    resetSelection()
  }, 150)
}

function onClickSuggestion(item: SuggestionItem) {
  const { newQuery, newCursor } = applySuggestion(item)
  query.value = newQuery
  cursorPos.value = newCursor
  emit('search', query.value)
  resetSelection()
  nextTick(() => {
    inputRef.value?.focus()
    inputRef.value?.setSelectionRange(newCursor, newCursor)
  })
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === '/' && document.activeElement !== inputRef.value) {
    e.preventDefault()
    inputRef.value?.focus()
    return
  }
  if (e.key === 'Escape') {
    if (showSuggestions.value) {
      resetSelection()
      isFocused.value = false
    }
    inputRef.value?.blur()
    return
  }

  if (showSuggestions.value) {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      selectedIndex.value = Math.min(selectedIndex.value + 1, suggestions.value.length - 1)
      scrollSelectedIntoView()
      return
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault()
      selectedIndex.value = Math.max(selectedIndex.value - 1, 0)
      scrollSelectedIntoView()
      return
    }
    if ((e.key === 'Enter' || e.key === 'Tab') && selectedIndex.value >= 0) {
      const item = suggestions.value[selectedIndex.value]
      if (!item) return
      e.preventDefault()
      onClickSuggestion(item)
      return
    }
  }
}

function scrollSelectedIntoView() {
  nextTick(() => {
    const el = dropdownRef.value?.querySelector('.suggestion-item.selected')
    el?.scrollIntoView({ block: 'nearest' })
  })
}

function onInputKeyUp() {
  updateCursorPos()
}

function onInputClick() {
  updateCursorPos()
}

onMounted(() => {
  document.addEventListener('keydown', onKeydown)
})

onUnmounted(() => {
  document.removeEventListener('keydown', onKeydown)
  clearBlurTimer()
})

watch(
  () => store.searchQuery,
  (value) => {
    query.value = value
  },
  { immediate: true },
)
</script>

<template>
  <div class="search-bar">
    <div class="search-input-wrap">
      <Search :size="16" class="search-icon" />
      <input
        ref="inputRef"
        v-model="query"
        type="text"
        :placeholder="isFocused ? t('hero.searchPlaceholderFocused') : t('hero.searchPlaceholder')"
        class="search-input"
        role="combobox"
        autocomplete="off"
        :aria-expanded="showSyntaxHint || showSuggestions"
        :aria-activedescendant="selectedIndex >= 0 ? `suggestion-${selectedIndex}` : undefined"
        aria-controls="search-listbox"
        @input="onInput"
        @focus="onFocus"
        @blur="onBlur"
        @keyup="onInputKeyUp"
        @click="onInputClick"
      />
      <span class="search-shortcut">/</span>
    </div>

    <!-- Syntax hint dropdown -->
    <div v-if="showSyntaxHint" id="search-listbox" role="listbox" class="search-dropdown">
      <div class="dropdown-header">{{ t('hero.searchSyntax') }}</div>
      <div
        v-for="(hint, idx) in syntaxHints"
        :id="`syntax-hint-${idx}`"
        :key="hint.prefix"
        role="option"
        tabindex="-1"
        class="syntax-hint-row"
        @mousedown.prevent="onClickSyntaxHint(hint.prefix)"
        @keydown.enter.prevent="onClickSyntaxHint(hint.prefix)"
      >
        <code class="hint-example"
          ><span class="hint-prefix">{{ hint.prefix }}</span
          >{{ hint.example }}</code
        >
        <span class="hint-desc">{{ t(hint.descKey) }}</span>
      </div>
    </div>

    <!-- Suggestion dropdown -->
    <div
      v-else-if="showSuggestions"
      id="search-listbox"
      ref="dropdownRef"
      role="listbox"
      class="search-dropdown suggestions-dropdown"
    >
      <div
        v-for="(item, idx) in suggestions"
        :id="`suggestion-${idx}`"
        :key="item.label"
        role="option"
        :aria-selected="idx === selectedIndex"
        class="suggestion-item"
        :class="{ selected: idx === selectedIndex }"
        @mousedown.prevent="onClickSuggestion(item)"
        @mouseenter="selectedIndex = idx"
      >
        <span class="suggestion-prefix">{{ context?.prefix }}:</span>{{ item.label }}
      </div>
    </div>
  </div>
</template>

<style scoped>
.search-bar {
  width: 100%;
  max-width: 540px;
  position: relative;
}

.search-input-wrap {
  position: relative;
  display: flex;
  align-items: center;
}

.search-icon {
  position: absolute;
  left: 1rem;
  color: var(--text-muted);
  pointer-events: none;
}

.search-input {
  width: 100%;
  padding: 0.75rem 3rem 0.75rem 2.75rem;
  font-size: 0.95rem;
  background: var(--bg-input);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  color: var(--text-primary);
  outline: none;
  transition:
    border-color 0.2s,
    box-shadow 0.2s;
  font-family: inherit;
}

.search-input::placeholder {
  color: var(--text-muted);
}

.search-input:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 3px rgba(232, 54, 45, 0.1);
}

.search-shortcut {
  position: absolute;
  right: 1rem;
  font-size: 0.75rem;
  font-family: 'IBM Plex Mono', monospace;
  color: var(--text-muted);
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0.1rem 0.4rem;
  pointer-events: none;
}

.search-input:focus ~ .search-shortcut {
  opacity: 0;
}

.search-dropdown {
  position: absolute;
  top: 100%;
  left: 0;
  right: 0;
  margin-top: 4px;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.1);
  z-index: 100;
  padding: 0.5rem 0;
  animation: dropdown-in 0.12s ease-out;
}

@keyframes dropdown-in {
  from {
    opacity: 0;
    transform: translateY(-4px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.dropdown-header {
  padding: 0.25rem 0.75rem 0.5rem;
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
}

.syntax-hint-row {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.375rem 0.75rem;
  font-size: 0.85rem;
  color: var(--text-secondary);
  cursor: pointer;
  border-radius: 4px;
  margin: 0 0.25rem;
  transition: background 0.1s;
}

.syntax-hint-row:hover {
  background: var(--bg-input);
}

.hint-example {
  font-family: 'IBM Plex Mono', monospace;
  font-size: 0.8rem;
  background: var(--bg-input);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0.15rem 0.4rem;
  color: var(--text-primary);
  white-space: nowrap;
  min-width: 5.5rem;
  text-align: left;
}

.hint-prefix {
  color: var(--accent);
  font-weight: 600;
}

.hint-desc {
  color: var(--text-muted);
  font-size: 0.8rem;
}

.suggestions-dropdown {
  max-height: 200px;
  overflow-y: auto;
  padding: 0.25rem 0;
}

.suggestion-item {
  padding: 0.4rem 0.75rem;
  font-family: 'IBM Plex Mono', monospace;
  font-size: 0.82rem;
  color: var(--text-primary);
  cursor: pointer;
  border-radius: 4px;
  margin: 0 0.25rem;
  transition: background 0.1s;
  text-align: left;
}

.suggestion-prefix {
  color: var(--accent);
  font-weight: 600;
}

.suggestion-item:hover,
.suggestion-item.selected {
  background: var(--bg-input);
}
</style>
