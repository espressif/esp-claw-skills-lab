export interface SkillMetadata {
  cap_groups?: string[]
  category?: string[]
  peripherals?: string[]
  tags?: string[]
}

export interface SkillFrontmatter {
  name: string
  description: string
  author?: string
  metadata?: SkillMetadata
  featured?: boolean
}

export interface SkillExtraFiles {
  references: string[]
  scripts: string[]
  assets: string[]
}

export type PackageKind = 'skill' | 'app'

export interface SkillData {
  icon?: string
  simulator?: boolean
  kind: PackageKind
  key: string
  packagePath: string
  rawPath: string
  readme: string
  id: string
  name: string
  description: string
  author: string
  title: string
  metadata: SkillMetadata
  extra_files: SkillExtraFiles
  files: string[]
  totalSize: number
  lastModified: number
}
