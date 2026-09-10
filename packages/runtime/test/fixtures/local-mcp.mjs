import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'

const server = new Server({ name: 'capability-fixture', version: '1' }, { capabilities: { tools: {} } })
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [{ name: 'echo', description: 'Echo test data', inputSchema: { type: 'object', properties: { value: { type: 'string' } } } }] }))
server.setRequestHandler(CallToolRequestSchema, async request => ({ content: [{ type: 'text', text: String(request.params.arguments?.value) }], structuredContent: { value: request.params.arguments?.value, secretInherited: Boolean(process.env.MEMOH_RUNTIME_KEY), localEnv: process.env.CAPABILITY_TEST_VALUE } }))
await server.connect(new StdioServerTransport())
