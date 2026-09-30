<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { X, Download } from '@lucide/vue'
import { FILE_EXTENSION_LANGUAGE_MAP, highlightCode } from '@/utils/highlight'

const props = defineProps<{
  rawPath: string
  filePath: string
}>()
const emit = defineEmits<{ close: [] }>()
const { t } = useI18n()

const content = ref('')
const highlighted = ref('')
const loading = ref(true)
const isBinary = ref(false)
let originalBodyOverflow = ''
let originalBodyPaddingRight = ''

const fileUrl = computed(() => `${props.rawPath}/${props.filePath}`)

const PREVIEWABLE_EXTENSIONS = Object.keys(FILE_EXTENSION_LANGUAGE_MAP)

const ext = computed(() => {
  const idx = props.filePath.lastIndexOf('.')
  return idx >= 0 ? props.filePath.substring(idx).toLowerCase() : ''
})

const canPreview = computed(() => PREVIEWABLE_EXTENSIONS.includes(ext.value))

async function loadContent() {
  loading.value = true
  try {
    const resp = await fetch(fileUrl.value)
    if (!resp.ok) {
      isBinary.value = true
      return
    }

    const ct = resp.headers.get('content-type') || ''
    if (
      ct.includes('application/octet-stream') ||
      (!ct.includes('text') && !ct.includes('json') && !ct.includes('yaml'))
    ) {
      if (!canPreview.value) {
        isBinary.value = true
        return
      }
    }

    const text = await resp.text()

    if (!canPreview.value || text.includes('\0')) {
      isBinary.value = true
      return
    }

    content.value = text

    try {
      const lang = FILE_EXTENSION_LANGUAGE_MAP[ext.value]
      highlighted.value = `<pre><code class="hljs language-${lang}">${highlightCode(text, lang)}</code></pre>`
    } catch {
      highlighted.value = ''
    }
  } catch {
    isBinary.value = true
  } finally {
    loading.value = false
  }
}

function lockBodyScroll() {
  const scrollbarWidth = window.innerWidth - document.documentElement.clientWidth
  const bodyPaddingRight =
    Number.parseFloat(window.getComputedStyle(document.body).paddingRight) || 0

  originalBodyOverflow = document.body.style.overflow
  originalBodyPaddingRight = document.body.style.paddingRight

  document.body.style.overflow = 'hidden'

  if (scrollbarWidth > 0) {
    document.body.style.paddingRight = `${bodyPaddingRight + scrollbarWidth}px`
  }
}

function unlockBodyScroll() {
  document.body.style.overflow = originalBodyOverflow
  document.body.style.paddingRight = originalBodyPaddingRight
}

function downloadFile() {
  const a = document.createElement('a')
  a.href = fileUrl.value
  a.download = props.filePath.split('/').pop() || 'file'
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
}

onMounted(() => {
  lockBodyScroll()
  loadContent()
})
onUnmounted(unlockBodyScroll)
</script>

<template>
  <div class="modal-overlay" @click.self="emit('close')">
    <div class="modal-panel">
      <div class="modal-header">
        <span class="modal-filename">{{ filePath }}</span>
        <div class="modal-actions">
          <button class="modal-btn" @click="downloadFile">
            <Download :size="14" />
            {{ t('raw.download') }}
          </button>
          <button class="modal-btn close-btn" @click="emit('close')">
            <X :size="16" />
          </button>
        </div>
      </div>
      <div class="modal-body">
        <div v-if="loading" class="modal-loading">Loading...</div>
        <div v-else-if="isBinary" class="modal-binary">
          <p>{{ t('raw.cannotPreview') }}</p>
          <button class="btn-primary" @click="downloadFile">
            <Download :size="14" />
            {{ t('raw.download') }}
          </button>
        </div>
        <!-- eslint-disable-next-line vue/no-v-html -->
        <div v-else-if="highlighted" class="modal-code" v-html="highlighted" />
        <pre v-else class="modal-pre">{{ content }}</pre>
      </div>
    </div>
  </div>
</template>

<style scoped>
.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: stretch;
  justify-content: center;
  z-index: 1000;
  padding: 1rem;
}

.modal-panel {
  background: var(--bg-base);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  width: 100%;
  max-width: 72rem;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.modal-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1.25rem;
  border-bottom: 1px solid var(--border);
  background: var(--bg-surface);
  flex-shrink: 0;
}

.modal-filename {
  font-family: 'IBM Plex Mono', monospace;
  font-size: 0.85rem;
  color: var(--text-primary);
  font-weight: 600;
}

.modal-actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.modal-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.3rem 0.7rem;
  font-size: 0.8rem;
  font-family: inherit;
  color: var(--text-secondary);
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition:
    background 0.15s,
    color 0.15s;
}

.modal-btn:hover {
  background: rgba(255, 255, 255, 0.05);
  color: var(--text-primary);
}

.close-btn {
  padding: 0.3rem;
}

.modal-body {
  flex: 1;
  overflow: auto;
  padding: 0;
}

.modal-loading {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 200px;
  color: var(--text-muted);
}

.modal-binary {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1.5rem;
  height: 300px;
  color: var(--text-secondary);
  font-size: 0.95rem;
}

.modal-code {
  padding: 1rem;
  overflow: auto;
}

.modal-code :deep(pre) {
  margin: 0;
  background: transparent !important;
}

.modal-code :deep(code) {
  font-family: 'IBM Plex Mono', monospace;
  font-size: 0.82rem;
  line-height: 1.7;
}

.modal-pre {
  margin: 0;
  padding: 1rem;
  font-family: 'IBM Plex Mono', monospace;
  font-size: 0.82rem;
  line-height: 1.7;
  color: var(--text-primary);
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
