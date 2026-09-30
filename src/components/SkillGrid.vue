<script setup lang="ts">
import type { SkillData } from '@/types/skill'
import SkillCard from './SkillCard.vue'

defineProps<{ skills: SkillData[] }>()
</script>

<template>
  <div class="skill-grid">
    <SkillCard v-for="skill in skills" :key="skill.key" :skill="skill" />
    <div v-if="skills.length === 0" class="empty-state">
      <p>{{ $t('package.empty') }}</p>
    </div>
  </div>
</template>

<style scoped>
.skill-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  flex: 1;
  align-content: flex-start;
}

.skill-grid > * {
  flex: 1 1 100%;
  min-width: 0;
}

.empty-state {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 4rem 2rem;
  color: var(--text-muted);
  font-size: 0.95rem;
  flex-basis: 100%;
  max-width: 100%;
  text-align: center;
}

@media (min-width: 720px) {
  .skill-grid > * {
    flex-basis: calc(50% - 0.375rem);
    max-width: calc(50% - 0.375rem);
  }

  .skill-grid > .empty-state {
    flex-basis: 100%;
    max-width: 100%;
  }
}

@media (min-width: 1200px) {
  .skill-grid > * {
    flex-basis: calc((100% - 1.5rem) / 3);
    max-width: calc((100% - 1.5rem) / 3);
  }

  .skill-grid > .empty-state {
    flex-basis: 100%;
    max-width: 100%;
  }
}
</style>
