import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { Client, credentials, type ServiceError } from '@grpc/grpc-js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { CapabilityHost } from '../src/capabilities/host'
import { expandEnvironment } from '../src/capabilities/config'
import { startRuntimeGrpcServer } from '../src/service'
import { createGrpcWebSocketTestHarness } from './grpc-websocket-harness'

let home: string
let host: CapabilityHost
const signal = () => new AbortController().signal
beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'memoh-capabilities-'))
  await mkdir(join(home, '.memoh'), { recursive: true })
  host = new CapabilityHost(home)
})
afterEach(async () => {
  await host.close()
  await rm(home, { recursive: true, force: true })
})
async function config(value: object) {
  await writeFile(join(home, '.memoh', 'capabilities.json'), JSON.stringify(value))
}
async function skill(name: string, metadata = '') {
  const directory = join(home, '.memoh', 'skills', name)
  await mkdir(directory, { recursive: true })
  await writeFile(join(directory, 'SKILL.md'), `---\nname: ${name}\ndescription: Read fixture data\n${metadata}---\nRun the local script.\n`)
}

describe('local capabilities', () => {
  it('discovers Skills progressively and applies configuration changes on call', async () => {
    await skill('test')
    await skill('hidden', 'disable-model-invocation: true\n')
    const catalog = await host.list(signal())
    const skills = catalog.skills as Array<{ id: string, name: string }>
    expect(skills.map(item => item.name)).toEqual(['test'])
    expect(JSON.stringify(catalog)).not.toContain('Run the local script')
    const result = await host.call({ kind: 'skill', skill_id: skills[0].id }, signal())
    expect(result.structuredContent).toMatchObject({ name: 'test', instructions: expect.stringContaining('Run the local script') })
    await config({ disabledSkills: ['test'] })
    await expect(host.call({ kind: 'skill', skill_id: skills[0].id }, signal())).rejects.toThrow('unavailable')
  })

  it('runs stdio MCP locally without inheriting the runtime credential', async () => {
    await config({ mcpServers: { fixture: { command: process.execPath, args: [fileURLToPath(new URL('./fixtures/local-mcp.mjs', import.meta.url))], env: { CAPABILITY_TEST_VALUE: 'local' } } } })
    const catalog = await host.list(signal())
    expect(catalog.tools).toMatchObject([{ server: 'fixture', name: 'echo' }])
    const result = await host.call({ kind: 'mcp', server: 'fixture', tool: 'echo', arguments: { value: 'hello' } }, signal())
    expect(result.structuredContent).toEqual({ value: 'hello', localEnv: 'local', secretInherited: false })
    await config({ enabled: false })
    await expect(host.call({ kind: 'mcp', server: 'fixture', tool: 'echo', arguments: {} }, signal())).rejects.toThrow('disabled')
    expect((await host.list(signal())).tools).toEqual([])
  })

  it('does not serialize local headers or inherit the runtime key via expansion', async () => {
    await config({ mcpServers: { unavailable: { url: 'http://127.0.0.1:1/mcp', headers: { Authorization: 'fixture-secret' } } } })
    const result = await host.list(signal())
    expect(result.servers).toEqual([{ name: 'unavailable', status: 'unavailable' }])
    expect(JSON.stringify(result)).not.toContain('fixture-secret')
    expect(() => expandEnvironment('${MEMOH_RUNTIME_KEY}')).toThrow()
  })

  it('serves JSON envelopes on the runtime WebSocket and survives malformed calls', async () => {
    await skill('rpc')
    const running = await startRuntimeGrpcServer({ workspaceBase: home })
    const transport = await createGrpcWebSocketTestHarness(running)
    const client = new Client(transport.target, credentials.createInsecure(), { 'grpc.enable_http_proxy': 0 })
    const invoke = (method: string, value: string) => new Promise<{ value: string }>((resolve, reject) => {
      // google.protobuf.StringValue wire encoding; List uses empty protobuf input.
      client.makeUnaryRequest(`/memoh.runtime.v1.CapabilityService/${method}`, (input: string) => method === 'List' ? Buffer.alloc(0) : Buffer.concat([Buffer.from([10, Buffer.byteLength(input)]), Buffer.from(input)]), data => {
        let index = 1, length = 0, shift = 0
        while (true) { const byte = data[index++]; length |= (byte & 127) << shift; if (!(byte & 128)) break; shift += 7 }
        return { value: data.subarray(index, index + length).toString() }
      }, value, (error: ServiceError | null, result?: { value: string }) => error ? reject(error) : resolve(result!))
    })
    try {
      await expect(invoke('Call', '{')).rejects.toMatchObject({ code: 9 })
      const catalog = JSON.parse((await invoke('List', '')).value) as { version: number, skills: unknown[] }
      expect(catalog.version).toBe(1)
      expect(catalog.skills).toHaveLength(1)
    }
    finally { client.close(); await transport.close(); await running.close() }
  })
})
