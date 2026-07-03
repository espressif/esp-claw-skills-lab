import type { SkillData } from '@/types/skill'

const DEFAULT_SIMULATOR_BASE_URL = 'https://simulator.esp-claw.com/'

export function isSimulatorSkill(skill: SkillData): boolean {
  return skill.metadata.category?.includes('ui') ?? false
}

export function buildSkillSimulatorUrl(skill: SkillData): string {
  const base = import.meta.env.VITE_SIMULATOR_BASE_URL || DEFAULT_SIMULATOR_BASE_URL
  const url = new URL(base)
  url.searchParams.set('repo', 'skills-lab')
  url.searchParams.set('ref', import.meta.env.VITE_BUILD_GIT_SHA || 'main')
  url.searchParams.set('skill', `skills/${skill.id}/SKILL.md`)
  return url.toString()
}
