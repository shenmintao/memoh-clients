import { createHash } from 'node:crypto'
import { dirname, resolve } from 'node:path'

import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { SSEClientTransport } from '@modelcontextprotocol/sdk/client/sse.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js'

import { expandEnvironment, loadConfig, object, readBounded, type McpConfig } from './config'
import { discoverSkills } from './skills'

export interface LocalTool {
  id: string
  server: string
  name: string
  description: string
  inputSchema: Record<string, unknown>
}

export class CapabilityHost {
  private readonly lifetime = new AbortController()
  private readonly clients = new Set<Client>()

  constructor(private readonly home: string) {}

  async close(): Promise<void> {
    this.lifetime.abort()
    await Promise.allSettled([...this.clients].map(client => client.close()))
  }

  async list(signal: AbortSignal): Promise<Record<string, unknown>> {
    signal = AbortSignal.any([signal, this.lifetime.signal, AbortSignal.timeout(6500)])
    const config = await loadConfig(this.home)
    const skills = await discoverSkills(config.skillRoots, config.disabledSkills)
    const tools: LocalTool[] = []
    const servers: Array<{ name: string, status: string }> = []
    const entries = Object.entries(config.mcpServers)
    let index = 0
    const workers = Array.from({ length: Math.min(4, entries.length) }, async () => {
      while (index < entries.length && !signal.aborted && !this.lifetime.signal.aborted) {
        const [name, entry] = entries[index++]
        try {
          const discovered = await this.withClient(entry, signal, async (client, activeSignal) => {
            const collected: LocalTool[] = []
            let cursor: string | undefined
            for (let page = 0; page < 8; page++) {
              const response = await client.listTools({ cursor }, { signal: activeSignal, timeout: 5000 })
              for (const tool of response.tools) {
                if (collected.length >= 256) break
                collected.push({
                  id: createHash('sha256').update(name + '\0' + tool.name).digest('hex').slice(0, 24),
                  server: name, name: tool.name, description: (tool.description ?? tool.name).slice(0, 4000),
                  inputSchema: tool.inputSchema,
                })
              }
              cursor = response.nextCursor
              if (!cursor || collected.length >= 256) break
            }
            return collected
          }, 6000)
          tools.push(...discovered)
          servers.push({ name, status: 'ready' })
        }
        catch { servers.push({ name, status: 'unavailable' }) }
      }
    })
    await Promise.all(workers)
    tools.sort((a, b) => a.id.localeCompare(b.id))
    return { version: 1, enabled: config.enabled, tools: tools.slice(0, 512), skills, servers }
  }

  async call(request: unknown, signal: AbortSignal): Promise<Record<string, unknown>> {
    if (!object(request)) throw new Error('Invalid capability request')
    const config = await loadConfig(this.home)
    if (!config.enabled) throw new Error('Local capabilities are disabled')
    if (request.kind === 'skill' && typeof request.skill_id === 'string') {
      const skills = await discoverSkills(config.skillRoots, config.disabledSkills)
      const skill = skills.find(item => item.id === request.skill_id)
      if (!skill) throw new Error('Skill is unavailable')
      const instructions = await readBounded(skill.path)
      return {
        content: [{ type: 'text', text: instructions }],
        structuredContent: { ...skill, directory: dirname(skill.path), instructions },
      }
    }
    if (request.kind !== 'mcp' || typeof request.server !== 'string' || typeof request.tool !== 'string' || !object(request.arguments)) throw new Error('Invalid MCP call')
    const entry = config.mcpServers[request.server]
    if (!entry) throw new Error('MCP server is unavailable')
    const tool = request.tool
    const args = request.arguments
    try {
      return await this.withClient(entry, signal, async (client, activeSignal) => {
        // Never retry an effect: transport failure leaves its outcome unknown.
        const result = await client.callTool({ name: tool, arguments: args }, undefined, { signal: activeSignal, timeout: 60000 })
        return result as Record<string, unknown>
      }, 65000)
    }
    catch {
      throw new Error('Local MCP call failed; its outcome may be unknown. Check the local server before retrying')
    }
  }

  private async withClient<T>(entry: McpConfig, signal: AbortSignal, operation: (client: Client, signal: AbortSignal) => Promise<T>, timeoutMs: number): Promise<T> {
    const controller = new AbortController()
    const abort = () => controller.abort()
    signal.addEventListener('abort', abort, { once: true })
    this.lifetime.signal.addEventListener('abort', abort, { once: true })
    const timer = setTimeout(abort, timeoutMs)
    const client = new Client({ name: 'memoh-local-capabilities', version: '1' })
    this.clients.add(client)
    let transport: Transport | undefined
    try {
      if (signal.aborted || this.lifetime.signal.aborted) throw new Error('Runtime is stopping')
      if (entry.command) {
        const env = Object.fromEntries(Object.entries(entry.env ?? {}).map(([key, value]) => [key, expandEnvironment(value)]))
        for (const key of Object.keys(env)) {
          if (key.toUpperCase() === 'MEMOH_RUNTIME_KEY') throw new Error('Runtime credentials cannot be passed to MCP servers')
        }
        const stdio = new StdioClientTransport({
          command: expandEnvironment(entry.command), args: (entry.args ?? []).map(expandEnvironment),
          cwd: entry.cwd ? resolve(this.home, expandEnvironment(entry.cwd)) : this.home,
          env, stderr: 'pipe',
        })
        stdio.stderr?.on('data', () => undefined)
        transport = stdio
      }
      else {
        const url = new URL(expandEnvironment(entry.url ?? ''))
        if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('Invalid MCP URL')
        const headers = Object.fromEntries(Object.entries(entry.headers ?? {}).map(([key, value]) => [key, expandEnvironment(value)]))
        transport = entry.transport === 'sse'
          ? new SSEClientTransport(url, { requestInit: { headers }, eventSourceInit: { fetch: (input, init) => fetch(input, { ...init, headers }) } })
          : new StreamableHTTPClientTransport(url, { requestInit: { headers }, reconnectionOptions: { maxRetries: 0, initialReconnectionDelay: 1000, maxReconnectionDelay: 1000, reconnectionDelayGrowFactor: 1 } })
      }
      await client.connect(transport, { signal: controller.signal, timeout: 5000 })
      return await operation(client, controller.signal)
    }
    finally {
      clearTimeout(timer)
      signal.removeEventListener('abort', abort)
      this.lifetime.signal.removeEventListener('abort', abort)
      await client.close().catch(() => undefined)
      await transport?.close().catch(() => undefined)
      this.clients.delete(client)
    }
  }
}
