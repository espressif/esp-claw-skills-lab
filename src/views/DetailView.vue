<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { ArrowLeft, Package, FileText, Puzzle, Copy, Check, ExternalLink, Play } from '@lucide/vue'
import MarkdownPreview from '@/components/MarkdownPreview.vue'
import FileTree from '@/components/FileTree.vue'
import RawPreviewModal from '@/components/RawPreviewModal.vue'
import { useSkillsStore } from '@/stores/skills'
import type { SkillData } from '@/types/skill'
import { buildSkillSimulatorUrl, isSimulatorSkill } from '@/utils/simulator'

const route = useRoute()
const router = useRouter()
const { t } = useI18n()
const store = useSkillsStore()

const skill = ref<SkillData | null>(null)
const markdownBody = ref('')
const previewFile = ref<string | null>(null)
const activeSection = ref('overview')
const copiedInstallText = ref(false)

const skillId = computed(() => route.params.id as string)
const lang = computed(() => (route.params.lang as string) || 'zh-cn')

const scriptCount = computed(() => skill.value?.extra_files.scripts.length ?? 0)
const assetCount = computed(() => skill.value?.extra_files.assets.length ?? 0)
const refCount = computed(() => skill.value?.extra_files.references.length ?? 0)

const totalSizeFormatted = computed(() => {
  const bytes = skill.value?.totalSize ?? 0
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
})
const lastModifiedFormatted = computed(() => {
  const timestamp = skill.value?.lastModified ?? 0
  if (!timestamp) return 'N/A'

  const date = new Date(timestamp)
  if (Number.isNaN(date.getTime())) return 'N/A'

  return new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
})
const buildGitSha = import.meta.env.VITE_BUILD_GIT_SHA || 'master'

const peripherals = computed(() => skill.value?.metadata.peripherals ?? [])
const tags = computed(() => skill.value?.metadata.tags ?? [])
const categories = computed(() => skill.value?.metadata.category ?? [])
const canSimulate = computed(() => (skill.value ? isSimulatorSkill(skill.value) : false))
const githubTreeUrl = computed(() =>
  skill.value
    ? `https://github.com/espressif/esp-claw-skills-lab/tree/${buildGitSha}/skills/${skill.value.id}`
    : '',
)
const authorInfo = computed(() => {
  const rawAuthor = skill.value?.author?.trim() ?? ''
  const match = rawAuthor.match(/^(.*?)\s*<([^<>\s]+@[^<>\s]+)>$/)

  if (!match) {
    return {
      name: rawAuthor,
      email: '',
    }
  }

  const [, name = rawAuthor, email = ''] = match

  return {
    name: name.trim(),
    email: email.trim(),
  }
})
const installText = computed(() =>
  skill.value ? t('install.command', { id: skill.value.id }) : '',
)

async function loadSkill() {
  await store.load()
  skill.value = store.getSkillById(skillId.value) ?? null

  if (skill.value) {
    try {
      const resp = await fetch(`/raw/${skillId.value}/SKILL.md`)
      if (resp.ok) {
        const raw = await resp.text()
        const fmEnd = raw.indexOf('---', raw.indexOf('---') + 3)
        markdownBody.value = fmEnd >= 0 ? raw.substring(fmEnd + 3).trim() : raw
      }
    } catch {
      markdownBody.value = ''
    }
  }
}

function goBack() {
  router.push(`/${lang.value}`)
}

function goToCategory(category: string) {
  store.searchQuery = `category:"${category}"`
  router.push(`/${lang.value}`)
}

function openSimulator() {
  if (!skill.value) return
  window.open(buildSkillSimulatorUrl(skill.value), '_blank', 'noopener,noreferrer')
}

async function copyInstallText() {
  if (!installText.value) return

  try {
    await navigator.clipboard.writeText(installText.value)
  } catch {
    const ta = document.createElement('textarea')
    ta.value = installText.value
    document.body.appendChild(ta)
    ta.select()
    document.execCommand('copy')
    document.body.removeChild(ta)
  }

  copiedInstallText.value = true
  setTimeout(() => {
    copiedInstallText.value = false
  }, 2000)
}

function searchByFilter(filter: string, value: string) {
  const query = `${filter}:\"${value}\"`
  store.searchQuery = query
  router.push(`/${lang.value}`)
}

function scrollTo(id: string) {
  activeSection.value = id
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

onMounted(loadSkill)
watch(skillId, loadSkill)
</script>

<template>
  <div v-if="skill" class="detail">
    <aside class="detail-sidebar">
      <button class="back-btn" type="button" :aria-label="t('detail.backToHome')" @click="goBack">
        <ArrowLeft :size="14" />
        <span class="back-label">{{ t('detail.backToHome') }}</span>
      </button>
      <div class="detail-nav-scroll">
        <nav class="detail-nav">
          <button
            class="nav-item"
            :class="{ active: activeSection === 'overview' }"
            @click="scrollTo('overview')"
          >
            {{ t('detail.overview') }}
          </button>
          <button
            class="nav-item"
            :class="{ active: activeSection === 'install' }"
            @click="scrollTo('install')"
          >
            {{ t('detail.installToEspClaw') }}
          </button>
          <button
            class="nav-item"
            :class="{ active: activeSection === 'skills-detail' }"
            @click="scrollTo('skills-detail')"
          >
            {{ t('detail.skillsDetail') }}
          </button>
          <button
            class="nav-item"
            :class="{ active: activeSection === 'files' }"
            @click="scrollTo('files')"
          >
            {{ t('detail.files') }}
          </button>
        </nav>
      </div>
    </aside>

    <div class="detail-main">
      <section id="overview" class="section">
        <div class="overview-info">
          <div class="title-row">
            <h1 class="skill-title">{{ skill.title || skill.name }}</h1>
            <span class="title-id">id: {{ skill.id }}</span>
          </div>
          <div class="skill-meta">
            <span class="meta-item">
              {{ t('detail.lastUpdate') }}: {{ lastModifiedFormatted }}
            </span>
            <span v-if="authorInfo.name" class="meta-item">
              {{ t('detail.author') }}:
              <a v-if="authorInfo.email" class="meta-link" :href="`mailto:${authorInfo.email}`">
                {{ authorInfo.name }}
              </a>
              <span v-else>{{ authorInfo.name }}</span>
            </span>
            <span class="meta-counts">
              <button
                type="button"
                class="meta-count-button"
                :title="t('detail.scriptFiles', { n: scriptCount })"
              >
                <FileText :size="14" />
                <span>{{ scriptCount }}</span>
              </button>
              <button
                type="button"
                class="meta-count-button"
                :title="t('detail.assetFiles', { n: assetCount })"
              >
                <Package :size="14" />
                <span>{{ assetCount }}</span>
              </button>
              <button
                type="button"
                class="meta-count-button"
                :title="t('detail.referenceFiles', { n: refCount })"
              >
                <Puzzle :size="14" />
                <span>{{ refCount }}</span>
              </button>
              <span class="meta-total">
                {{ t('detail.totalSize', { size: totalSizeFormatted }) }}
              </span>
            </span>
          </div>
          <p class="skill-desc">{{ skill.description }}</p>
          <div class="skill-tags">
            <template v-if="categories.length > 0 || peripherals.length > 0 || tags.length > 0">
              <button
                v-for="cat in categories"
                :key="`category:${cat}`"
                type="button"
                class="tag tag-button category-tag"
                @click="goToCategory(cat)"
              >
                {{ t(`category.${cat}`) }}
              </button>
              <button
                v-for="p in peripherals"
                :key="`peripheral:${p}`"
                type="button"
                class="tag tag-button periph-tag"
                @click="searchByFilter('peripheral', p)"
              >
                {{ p }}
              </button>
              <button
                v-for="tag in tags"
                :key="`tag:${tag}`"
                type="button"
                class="tag tag-button plain-tag"
                @click="searchByFilter('tag', tag)"
              >
                {{ tag }}
              </button>
            </template>
            <span v-else class="empty-text">
              {{ t('detail.noTags') }}
            </span>
          </div>
        </div>
      </section>

      <section id="install" class="section">
        <h2 class="section-title">{{ t('detail.installToEspClaw') }}</h2>
        <div>
          <button v-if="canSimulate" class="simulator-btn" type="button" @click="openSimulator">
            <Play :size="14" />
            <span>{{ t('detail.tryOnline') }}</span>
          </button>
          <p class="install-note">
            {{ t('install.safetyMessage') }}
          </p>
          <p class="install-instruction">
            {{ t('install.instruction') }}
            <button
              class="copy-btn"
              :class="{ copied: copiedInstallText }"
              @click="copyInstallText"
            >
              <Check v-if="copiedInstallText" :size="14" />
              <Copy v-else :size="14" />
              {{ copiedInstallText ? t('install.copySuccess') : t('install.copy') }}
            </button>
          </p>
          <div class="install-code-block">
            <code>{{ installText }}</code>
          </div>
        </div>
      </section>

      <section id="skills-detail" class="section">
        <h2 class="section-title">{{ t('detail.skillsDetail') }}</h2>
        <MarkdownPreview :content="markdownBody" />
      </section>

      <section id="files" class="section">
        <div class="section-title-row">
          <h2 class="section-title">{{ t('detail.files') }}</h2>
          <a
            v-if="githubTreeUrl"
            class="section-link"
            :href="githubTreeUrl"
            target="_blank"
            rel="noopener noreferrer"
          >
            <ExternalLink :size="14" />
            <span>{{ t('detail.viewOnGithub') }}</span>
          </a>
        </div>
        <FileTree :files="skill.files" @preview="previewFile = $event" />
      </section>
    </div>

    <RawPreviewModal
      v-if="previewFile"
      :skill-id="skill.id"
      :file-path="previewFile"
      @close="previewFile = null"
    />
  </div>
  <div v-else class="loading-state">
    <p>Loading...</p>
  </div>
</template>

<style scoped>
.detail {
  display: flex;
  flex: 1;
  min-height: 0;
  min-width: 0;
}

.detail-sidebar {
  min-width: 180px;
  max-width: 200px;
  border-right: 1px solid var(--border);
  padding: 1rem 0;
  position: sticky;
  top: 56px;
  align-self: flex-start;
  max-height: calc(100vh - 56px);
}

.back-btn {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.5rem 1.25rem;
  font-size: 0.82rem;
  color: var(--text-muted);
  background: none;
  border: none;
  cursor: pointer;
  font-family: inherit;
  transition: color 0.15s;
  margin-bottom: 0.75rem;
}

.back-btn:hover {
  color: var(--text-primary);
}

.back-label {
  display: inline;
}

.detail-nav-scroll {
  min-width: 0;
}

.detail-nav {
  display: flex;
  flex-direction: column;
}

.nav-item {
  display: block;
  width: 100%;
  text-align: left;
  padding: 0.55rem 1.25rem;
  font-size: 0.85rem;
  color: var(--text-secondary);
  background: none;
  border: none;
  border-left: 2px solid transparent;
  cursor: pointer;
  font-family: inherit;
  transition:
    color 0.15s,
    background 0.15s,
    border-color 0.15s;
}

.nav-item:hover {
  color: var(--text-primary);
  background: rgba(255, 255, 255, 0.03);
}

.nav-item.active {
  color: var(--accent-soft);
  border-left-color: var(--accent);
  background: var(--accent-dim);
  font-weight: 600;
}

.detail-main {
  flex: 1;
  min-width: 0;
  padding: 2rem 2.5rem;
  overflow-y: auto;
}

.section {
  margin-bottom: 3rem;
}

.section-title {
  font-size: 1.15rem;
  font-weight: 600;
  color: var(--text-primary);
  margin-bottom: 1.25rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border);
}

.section-title-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1.25rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border);
}

.section-title-row .section-title {
  margin-bottom: 0;
  padding-bottom: 0;
  border-bottom: none;
}

.section-link {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.82rem;
  color: var(--accent-soft);
  text-decoration: none;
  white-space: nowrap;
}

.section-link:hover {
  color: var(--text-primary);
}

.overview-info {
  min-width: 0;
}

.title-row {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  flex-wrap: wrap;
  margin-bottom: 0.5rem;
}

.skill-title {
  font-size: 1.75rem;
  font-weight: 700;
  color: var(--text-primary);
  letter-spacing: -0.02em;
  margin: 0;
}

.skill-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 1.5rem;
  margin-bottom: 1rem;
  align-items: center;
}

.meta-item {
  font-size: 0.82rem;
  color: var(--text-muted);
  font-family: 'IBM Plex Mono', monospace;
}

.meta-link {
  color: inherit;
  text-decoration: none;
}

.meta-link:hover {
  color: var(--text-primary);
  text-decoration: underline;
}

.meta-counts {
  display: inline-flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.65rem;
  min-width: 0;
}

.meta-count-button {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0;
  border: none;
  background: none;
  color: var(--text-secondary);
  font-size: 0.82rem;
  font-family: 'IBM Plex Mono', monospace;
  cursor: help;
}

.meta-total {
  font-size: 0.82rem;
  color: var(--text-muted);
  font-family: 'IBM Plex Mono', monospace;
}

.skill-desc {
  font-size: 0.92rem;
  color: var(--text-secondary);
  line-height: 1.65;
  margin-bottom: 1.25rem;
}

.skill-tags {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.4rem;
}

.tag-label {
  font-size: 0.8rem;
  color: var(--text-muted);
  margin-right: 0.25rem;
}

.tag {
  font-size: 0.72rem;
  padding: 0.15rem 0.55rem;
  border-radius: 100px;
  font-weight: 500;
}

.title-id {
  font-size: 0.78rem;
  color: var(--text-muted);
  font-family: 'IBM Plex Mono', monospace;
}

.tag-button {
  cursor: pointer;
  font-family: inherit;
  transition:
    transform 0.15s,
    opacity 0.15s;
}

.tag-button:hover {
  transform: translateY(-1px);
  opacity: 0.92;
}

.category-tag {
  background: var(--accent-dim);
  color: var(--accent-soft);
  border: 1px solid var(--border-accent);
}

.periph-tag {
  background: rgba(255, 196, 61, 0.14);
  color: #ffcf5a;
  border: 1px solid rgba(255, 196, 61, 0.35);
}

.plain-tag {
  background: rgba(255, 255, 255, 0.05);
  color: var(--text-secondary);
  border: 1px solid var(--border);
}

.empty-text {
  font-size: 0.85rem;
  color: var(--text-muted);
}

.install-instruction {
  font-size: 0.92rem;
  color: var(--text-secondary);
  margin-bottom: 1rem;
}

.simulator-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  margin-bottom: 0.85rem;
  padding: 0.55rem 0.9rem;
  font-size: 0.84rem;
  font-family: inherit;
  color: #75d7aa;
  background: rgba(84, 182, 139, 0.12);
  border: 1px solid rgba(84, 182, 139, 0.45);
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition:
    background 0.15s,
    color 0.15s;
}

.simulator-btn:hover {
  background: rgba(84, 182, 139, 0.22);
  color: #dffbed;
}

.install-note {
  font-size: 0.86rem;
  color: #e1bb62;
  background: rgba(255, 196, 61, 0.16);
  border: 1px solid rgba(255, 196, 61, 0.35);
  border-radius: var(--radius-sm);
  padding: 0.7rem 0.85rem;
  margin-bottom: 0.85rem;
}

.install-code-block {
  background: var(--bg-base);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 1rem;
}

.install-code-block code {
  font-family: 'IBM Plex Mono', monospace;
  font-size: 0.82rem;
  color: var(--text-primary);
  word-break: break-all;
  line-height: 1.6;
}

.copy-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  margin-left: 0.5rem;
  padding: 0.45rem 0.85rem;
  font-size: 0.78rem;
  font-family: inherit;
  background: var(--accent-dim);
  color: var(--accent-soft);
  border: 1px solid var(--border-accent);
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition:
    background 0.15s,
    color 0.15s;
}

.copy-btn:hover {
  background: rgba(232, 54, 45, 0.15);
}

.copy-btn.copied {
  color: var(--green);
  border-color: rgba(104, 211, 145, 0.3);
  background: var(--green-dim);
}

.loading-state {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: 1;
  color: var(--text-muted);
}

@media (max-width: 900px) {
  .detail {
    flex-direction: column;
  }

  .detail-sidebar {
    position: sticky;
    top: 56px;
    z-index: 90;
    align-self: stretch;
    width: 100%;
    max-width: 100%;
    min-width: 0;
    box-sizing: border-box;
    max-height: none;
    border-right: none;
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    padding: 0.5rem 0 0.5rem 1rem;
    gap: 0.5rem;
    overflow-x: visible;
    background: rgba(10, 11, 14, 0.92);
    backdrop-filter: blur(10px);
  }

  .back-btn {
    margin-bottom: 0;
    flex-shrink: 0;
    padding: 0.5rem 0.65rem;
  }

  .back-label {
    display: none;
  }

  .detail-nav-scroll {
    flex: 1;
    min-width: 0;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    padding-right: 1rem;
  }

  .detail-nav {
    flex-direction: row;
    flex-wrap: nowrap;
    flex-shrink: 0;
    gap: 0.25rem;
    width: max-content;
    min-width: 100%;
    box-sizing: border-box;
  }

  .nav-item {
    width: auto;
    flex-shrink: 0;
    white-space: nowrap;
    padding: 0.4rem 0.8rem;
    border-left: none;
    border-bottom: 2px solid transparent;
    border-radius: 0;
    font-size: 0.8rem;
  }

  .nav-item.active {
    border-left-color: transparent;
    border-bottom-color: var(--accent);
  }

  .detail-main {
    padding: 1.5rem;
  }

  .section-title-row {
    align-items: flex-start;
    flex-direction: column;
  }

  .skill-meta {
    gap: 0.75rem 1.25rem;
  }

  .meta-counts {
    flex-basis: 100%;
  }
}
</style>
