import { createHash } from 'node:crypto'
import { readdir, realpath } from 'node:fs/promises'
import { join } from 'node:path'

import { parse } from 'yaml'

import { object, readBounded } from './config'

export interface LocalSkill {
  id: string
  name: string
  description: string
  path: string
}

export function parseSkill(raw: string): { name: string, description: string } | undefined {
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(raw)
  if (!frontmatter) return
  const metadata: unknown = parse(frontmatter[1], { maxAliasCount: 20 })
  if (!object(metadata) || typeof metadata.name !== 'string' || typeof metadata.description !== 'string') return
  if (!metadata.name.trim() || !metadata.description.trim() || metadata['disable-model-invocation'] === true) return
  if (object(metadata.metadata) && ['hidden', 'internal', 'internal_only', 'subagent_only'].some(key => metadata.metadata && object(metadata.metadata) && metadata.metadata[key] === true)) return
  return { name: metadata.name.slice(0, 128), description: metadata.description.slice(0, 4000) }
}

export async function discoverSkills(roots: string[], disabled: string[]): Promise<LocalSkill[]> {
  const visited = new Set<string>()
  const names = new Set(disabled)
  const skills: LocalSkill[] = []
  let entriesSeen = 0
  async function walk(directory: string, depth: number): Promise<void> {
    if (depth > 8 || entriesSeen > 4096 || skills.length >= 256) return
    try {
      const canonical = await realpath(directory)
      if (visited.has(canonical)) return
      visited.add(canonical)
      const entries = await readdir(canonical, { withFileTypes: true })
      entries.sort((a, b) => a.name.localeCompare(b.name))
      entriesSeen += entries.length
      if (entriesSeen > 4096) return
      const file = entries.find(entry => entry.name === 'SKILL.md' && entry.isFile())
      if (file) {
        const path = join(canonical, file.name)
        const metadata = parseSkill(await readBounded(path))
        if (metadata && !names.has(metadata.name)) {
          names.add(metadata.name)
          skills.push({ ...metadata, path, id: createHash('sha256').update(path).digest('hex').slice(0, 24) })
        }
        return
      }
      for (const entry of entries) {
        if ((entry.isDirectory() || entry.isSymbolicLink()) && !entry.name.startsWith('.') && entry.name !== 'node_modules') await walk(join(canonical, entry.name), depth + 1)
      }
    }
    catch { /* A missing or malformed skill must not hide other skills. */ }
  }
  for (const root of roots) await walk(root, 0)
  return skills
}
