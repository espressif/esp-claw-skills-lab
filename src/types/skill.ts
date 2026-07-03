export interface SkillMetadata {
  cap_groups: string[]
  manage_mode: string
  category: string[]
  peripherals?: string[]
  tags?: string[]
}

export interface SkillFrontmatter {
  name: string
  description: string
  author?: string
  metadata: SkillMetadata
  featured?: boolean
  simulator?: {
    entry: string
    files: string[]
  }
}

export interface SkillExtraFiles {
  references: string[]
  scripts: string[]
  assets: string[]
}

export interface SkillData {
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
