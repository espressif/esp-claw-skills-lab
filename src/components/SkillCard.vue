<script setup lang="ts">
import { computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { ArrowRight, Play } from '@lucide/vue'
import type { SkillData } from '@/types/skill'
import { buildSkillSimulatorUrl, isSimulatorSkill } from '@/utils/simulator'

const props = defineProps<{ skill: SkillData }>()
const router = useRouter()
const route = useRoute()

const lang = computed(() => (route.params.lang as string) || 'zh-cn')
const authorName = computed(() => {
  const rawAuthor = props.skill.author?.trim() || 'Unknown'
  return rawAuthor.split('<')[0]?.trim() || rawAuthor
})
const canSimulate = computed(() => isSimulatorSkill(props.skill))

function goToDetail() {
  router.push(`/${lang.value}/skill/${props.skill.id}`)
}

function openSimulator() {
  window.open(buildSkillSimulatorUrl(props.skill), '_blank', 'noopener,noreferrer')
}
</script>

<template>
  <div class="skill-card" tabindex="0" @click="goToDetail" @keydown.enter="goToDetail">
    <div class="card-top">
      <div class="card-copy">
        <h3 class="card-title">{{ skill.title || skill.name }}</h3>
        <p class="card-author">by {{ authorName }}</p>
      </div>
      <div class="card-actions">
        <button v-if="canSimulate" class="sim-btn" type="button" @click.stop="openSimulator">
          <Play :size="14" />
          <span>{{ $t('skillCard.tryOnline') }}</span>
        </button>
        <button class="install-btn" type="button" @click.stop="goToDetail">
          <ArrowRight :size="14" />
          <span>{{ $t('skillCard.download') }}</span>
        </button>
      </div>
    </div>
    <p class="card-desc">{{ skill.description }}</p>
  </div>
</template>

<style scoped>
.skill-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 0;
  padding: 1rem;
  cursor: pointer;
  transition:
    background 0.2s,
    border-color 0.2s;
  position: relative;
  overflow: hidden;
  min-height: 9rem;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  width: 100%;
  min-width: 0;
}

.skill-card::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: var(--accent);
  transform: scaleX(0);
  transform-origin: left;
  transition: transform 0.35s ease;
}

.skill-card:hover,
.skill-card:focus-visible {
  background: var(--bg-card);
  border-color: var(--border-accent);
}

.skill-card:hover::before,
.skill-card:focus-visible::before {
  transform: scaleX(1);
}

.card-top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 0.55rem;
}

.card-copy {
  min-width: 0;
  flex: 1;
}

.card-actions {
  display: inline-flex;
  align-items: stretch;
  gap: 0.45rem;
  flex-shrink: 0;
}

.card-title {
  font-size: 1.05rem;
  font-weight: 700;
  color: var(--text-primary);
  margin: 0;
  letter-spacing: -0.01em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  min-width: 0;
}

.card-author {
  font-size: 0.8rem;
  color: var(--text-muted);
  margin: 0.3rem 0 0;
}

.install-btn,
.sim-btn {
  display: inline-flex;
  align-items: center;
  align-self: stretch;
  gap: 0.3rem;
  padding: 0.1rem 0.65rem;
  height: 2.1rem;
  font: inherit;
  font-size: 0.82rem;
  font-weight: 600;
  cursor: pointer;
  white-space: nowrap;
  transition:
    background 0.2s ease,
    color 0.2s ease,
    background-position 0.4s ease;
}

.install-btn {
  border: 0.1rem solid var(--accent);
  background: linear-gradient(135deg, var(--accent) 50%, transparent 50%);
  background-size: 300% 300%;
  background-position: 100% 100%;
  color: var(--accent);
}

.install-btn:hover,
.install-btn:focus-visible {
  background-position: 0 0;
  color: #fff;
}

.sim-btn {
  border: 0.1rem solid #54b68b;
  background: rgba(84, 182, 139, 0.12);
  color: #75d7aa;
}

.sim-btn:hover,
.sim-btn:focus-visible {
  background: rgba(84, 182, 139, 0.22);
  color: #dffbed;
}

.card-desc {
  font-size: 0.85rem;
  color: var(--text-secondary);
  line-height: 1.55;
  margin: 0;
  flex: 0 1 auto;
  min-width: 0;
  min-height: 0;
  max-height: calc(1.55em * 2);
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
  text-overflow: ellipsis;
  overflow-wrap: break-word;
}

@media (max-width: 720px) {
  .card-top {
    flex-direction: column;
  }

  .card-actions {
    width: 100%;
  }

  .install-btn,
  .sim-btn {
    justify-content: center;
    flex: 1;
  }
}
</style>
