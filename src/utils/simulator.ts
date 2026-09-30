import type { SkillData } from '@/types/skill'

const DEFAULT_SIMULATOR_BASE_URL = 'https://simulator.esp-claw.com/'

export function canSimulateApp(skill: SkillData): boolean {
  return skill.kind === 'app' && skill.simulator === true
}

export function buildAppSimulatorUrl(skill: SkillData): string {
  const base = import.meta.env?.VITE_SIMULATOR_BASE_URL || DEFAULT_SIMULATOR_BASE_URL
  const url = new URL(base)
  url.searchParams.set('repo', 'skills-lab')
  url.searchParams.set('ref', import.meta.env?.VITE_BUILD_GIT_SHA || 'main')
  url.searchParams.set('app', `apps/${skill.id}/launcher.json`)
  return url.toString()
}
