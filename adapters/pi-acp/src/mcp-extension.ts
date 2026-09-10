import { createHash } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import type { McpServer } from '@agentclientprotocol/sdk'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { SSEClientTransport } from '@modelcontextprotocol/sdk/client/sse.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js'
import { CallToolResultSchema } from '@modelcontextprotocol/sdk/types.js'

type Content = { type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string }
interface ExtensionAPI {
  registerTool(tool: {
    name: string
    label: string
    description: string
    parameters: Record<string, unknown>
    execute: (
      id: string,
      params: Record<string, unknown>,
      signal?: AbortSignal
    ) => Promise<{ content: Content[]; details: unknown }>
  }): void
  on(event: 'session_shutdown', handler: () => Promise<void>): void
}

export async function registerMcpTools(pi: ExtensionAPI, servers: McpServer[]): Promise<void> {
  const clients = new Set<Client>()
  const close = async () => {
    await Promise.allSettled([...clients].map(client => client.close()))
    clients.clear()
  }
  pi.on('session_shutdown', close)
  try {
    for (const server of servers) {
      const client = new Client({ name: 'pi-acp-mcp', version: '1' })
      clients.add(client)
      let transport: Transport
      if ('url' in server) {
        const url = new URL(server.url)
        if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Invalid MCP URL')
        const headers = Object.fromEntries(server.headers.map(header => [header.name, header.value]))
        transport =
          server.type === 'sse'
            ? new SSEClientTransport(url, {
                requestInit: { headers },
                eventSourceInit: { fetch: (input, init) => fetch(input, { ...init, headers }) }
              })
            : new StreamableHTTPClientTransport(url, {
                requestInit: { headers },
                reconnectionOptions: {
                  maxRetries: 0,
                  initialReconnectionDelay: 1000,
                  maxReconnectionDelay: 1000,
                  reconnectionDelayGrowFactor: 1
                }
              })
      } else if ('command' in server) {
        const stdio = new StdioClientTransport({
          command: server.command,
          args: server.args,
          env: Object.fromEntries(server.env.map(entry => [entry.name, entry.value])),
          stderr: 'pipe'
        })
        stdio.stderr?.on('data', () => undefined)
        transport = stdio
      } else {
        throw new Error('ACP callback MCP transport is not supported')
      }
      await client.connect(transport, { timeout: 10000 })
      let cursor: string | undefined
      for (let page = 0; page < 16; page++) {
        const response = await client.listTools({ cursor }, { timeout: 15000 })
        for (const tool of response.tools) {
          const name =
            'mcp_' +
            createHash('sha256')
              .update(server.name + '\0' + tool.name)
              .digest('hex')
              .slice(0, 24)
          pi.registerTool({
            name,
            label: server.name + '/' + tool.name,
            description: `[${server.name}/${tool.name}] ${tool.description ?? tool.name}`,
            parameters: tool.inputSchema,
            async execute(_id, args, signal) {
              const result = CallToolResultSchema.parse(
                await client.callTool({ name: tool.name, arguments: args }, CallToolResultSchema, {
                  signal,
                  timeout: 600000
                })
              )
              const content: Content[] = []
              for (const item of result.content ?? []) {
                if (item.type === 'text') content.push({ type: 'text', text: item.text })
                else if (item.type === 'image')
                  content.push({ type: 'image', data: item.data, mimeType: item.mimeType })
                else content.push({ type: 'text', text: JSON.stringify(item) })
              }
              if (result.isError)
                throw new Error(
                  content
                    .filter(item => item.type === 'text')
                    .map(item => item.text)
                    .join('\n') || 'MCP tool failed'
                )
              return { content, details: result.structuredContent ?? {} }
            }
          })
        }
        cursor = response.nextCursor
        if (!cursor) break
      }
    }
  } catch {
    await close()
    throw new Error('ACP MCP initialization failed; check the configured server connection')
  }
}

// The adapter owns this private temporary file and removes it when Pi exits.
export default async function extension(pi: ExtensionAPI): Promise<void> {
  const path = process.env.PI_ACP_MCP_CONFIG
  if (!path) return
  if (statSync(path).size > 1024 * 1024) throw new Error('ACP MCP configuration is too large')
  const servers = JSON.parse(readFileSync(path, 'utf8')) as McpServer[]
  await registerMcpTools(pi, servers)
}
