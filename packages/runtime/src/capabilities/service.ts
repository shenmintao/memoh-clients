import { access } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

import { loadPackageDefinition, status, type ServiceDefinition, type handleUnaryCall } from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'

import { rpcError } from '../rpc'
import { CapabilityHost } from './host'

export async function capabilityService(home: string): Promise<{
  definition: ServiceDefinition
  implementation: { List: handleUnaryCall<Record<string, never>, { value: string }>, Call: handleUnaryCall<{ value: string }, { value: string }> }
  close: () => Promise<void>
}> {
  const candidates = [new URL('./capabilities.proto', import.meta.url), new URL('../capabilities.proto', import.meta.url)]
  let proto = ''
  for (const candidate of candidates) {
    try { await access(fileURLToPath(candidate)); proto = fileURLToPath(candidate); break }
    catch { /* Source and bundled layouts differ. */ }
  }
  if (!proto) throw new Error('capabilities.proto was not found')
  const loaded = loadPackageDefinition(loadSync(proto)) as unknown as { memoh: { runtime: { v1: { CapabilityService: { service: ServiceDefinition } } } } }
  const host = new CapabilityHost(home)
  function handler<Request>(operation: (request: Request, signal: AbortSignal) => Promise<Record<string, unknown>>): handleUnaryCall<Request, { value: string }> {
    return (call, callback) => {
      const controller = new AbortController()
      const abort = () => controller.abort()
      call.once('cancelled', abort)
      if (call.cancelled) abort()
      void Promise.resolve().then(() => operation(call.request, controller.signal)).then((result) => {
        const value = JSON.stringify(result)
        if (Buffer.byteLength(value) > 4 * 1024 * 1024) throw rpcError(status.RESOURCE_EXHAUSTED, 'Local capability result exceeds 4 MiB')
        callback(null, { value })
      }).catch(() => callback(rpcError(status.FAILED_PRECONDITION, 'Local capability unavailable; check the machine configuration. A failed MCP call must not be retried automatically'))).finally(() => call.off('cancelled', abort))
    }
  }
  return {
    definition: loaded.memoh.runtime.v1.CapabilityService.service,
    implementation: {
      List: handler((_request, signal) => host.list(signal)),
      Call: handler((request: { value: string }, signal) => host.call(JSON.parse(request.value) as unknown, signal)),
    },
    close: () => host.close(),
  }
}
