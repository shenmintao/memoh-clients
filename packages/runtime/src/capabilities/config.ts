import { open } from 'node:fs/promises'
import { isAbsolute, join, resolve } from 'node:path'

export interface McpConfig {
  command?: string
  args?: string[]
  cwd?: string
  env?: Record<string, string>
  url?: string
  headers?: Record<string, string>
  transport?: 'http' | 'sse'
  disabled?: boolean
}

export interface CapabilityConfig {
  enabled: boolean
  mcpServers: Record<string, McpConfig>
  skillRoots: string[]
  disabledSkills: string[]
}

export function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

export async function readBounded(path: string, maxBytes = 512 * 1024): Promise<string> {
  const file = await open(path, 'r')
  try {
    const stat = await file.stat()
    if (!stat.isFile() || stat.size > maxBytes) throw new Error('invalid file or size limit exceeded')
    const content = Buffer.alloc(maxBytes + 1)
    let length = 0
    while (length < content.length) {
      const { bytesRead } = await file.read(content, length, content.length - length, null)
      if (bytesRead === 0) break
      length += bytesRead
    }
    if (length > maxBytes) throw new Error('file exceeds size limit')
    return content.subarray(0, length).toString('utf8').replace(/^\uFEFF/, '')
  }
  finally { await file.close() }
}

async function readConfig(path: string): Promise<Record<string, unknown>> {
  try {
    const value: unknown = JSON.parse(await readBounded(path))
    if (!object(value)) throw new Error('configuration must be an object')
    return value
  }
  catch (error) {
    if (object(error) && error.code === 'ENOENT') return {}
    throw new Error('Invalid local capability configuration')
  }
}

export async function loadConfig(home: string): Promise<CapabilityConfig> {
  const directory = join(home, '.memoh')
  const common = await readConfig(join(directory, 'mcp.json'))
  const config = await readConfig(join(directory, 'capabilities.json'))
  if (config.enabled === false) return { enabled: false, mcpServers: {}, skillRoots: [], disabledSkills: [] }
  const servers = { ...(object(common.mcpServers) ? common.mcpServers : {}), ...(object(config.mcpServers) ? config.mcpServers : {}) }
  if (Object.keys(servers).length > 32) throw new Error('At most 32 local MCP servers are supported')
  const mcpServers: Record<string, McpConfig> = Object.create(null) as Record<string, McpConfig>
  for (const [name, entry] of Object.entries(servers)) {
    if (!object(entry) || entry.disabled === true || entry.is_active === false) continue
    if (typeof entry.command !== 'string' && typeof entry.url !== 'string') throw new Error('MCP entry requires command or url')
    if (entry.cwd !== undefined && typeof entry.cwd !== 'string') throw new Error('Invalid MCP working directory')
    if (entry.args !== undefined && (!Array.isArray(entry.args) || !entry.args.every(item => typeof item === 'string'))) throw new Error('Invalid MCP arguments')
    for (const field of ['env', 'headers']) {
      if (entry[field] !== undefined && (!object(entry[field]) || !Object.values(entry[field]).every(value => typeof value === 'string'))) throw new Error('Invalid MCP environment or headers')
    }
    if (entry.transport !== undefined && entry.transport !== 'http' && entry.transport !== 'sse') throw new Error('Unsupported MCP transport')
    mcpServers[name] = entry as McpConfig
  }
  const roots = [join(directory, 'skills'), join(home, '.agents', 'skills'), join(home, '.pi', 'agent', 'skills')]
  if (config.skillRoots !== undefined) {
    if (!Array.isArray(config.skillRoots) || !config.skillRoots.every(root => typeof root === 'string') || config.skillRoots.length > 32) throw new Error('Invalid skillRoots')
    for (const root of config.skillRoots as string[]) {
      roots.push(root.startsWith('~/') ? join(home, root.slice(2)) : isAbsolute(root) ? root : resolve(directory, root))
    }
  }
  const disabledSkills = Array.isArray(config.disabledSkills) ? config.disabledSkills.filter((name): name is string => typeof name === 'string') : []
  return { enabled: true, mcpServers, skillRoots: [...new Set(roots)], disabledSkills }
}

export function expandEnvironment(value: string): string {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_match: string, name: string) => {
    if (name.toUpperCase() === 'MEMOH_RUNTIME_KEY' || process.env[name] === undefined) throw new Error('MCP environment variable is unavailable')
    return process.env[name] ?? ''
  })
}
