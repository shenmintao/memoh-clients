import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { registerMcpTools } from '../../src/mcp-extension.js'

test('ACP servers expose tools with isolated arguments and lifecycle cleanup', async () => {
  const tools: Parameters<Parameters<typeof registerMcpTools>[0]['registerTool']>[0][] = []
  let close: () => Promise<void> = async () => {}
  await registerMcpTools(
    {
      registerTool: tool => tools.push(tool),
      on: (_event, handler) => {
        close = handler
      }
    },
    [
      {
        name: 'fixture',
        command: process.execPath,
        args: [fileURLToPath(new URL('../fixtures/mcp-server.mjs', import.meta.url))],
        env: []
      }
    ]
  )
  try {
    assert.equal(tools.length, 1)
    assert.match(tools[0].description, /fixture\/echo/)
    const response = await tools[0].execute('call-1', { value: 'via-pi' })
    assert.deepEqual(response.content, [{ type: 'text', text: 'via-pi' }])
    const controller = new AbortController()
    controller.abort()
    await assert.rejects(tools[0].execute('cancelled', { value: 'cancelled' }, controller.signal))
  } finally {
    await close()
  }
})
