import test from 'node:test'
import assert from 'node:assert/strict'
import { PiAcpSession } from '../../src/acp/session.js'
import { FakeAgentSideConnection, FakePiRpcProcess, asAgentConn } from '../helpers/fakes.js'
import type { PiRpcProcess } from '../../src/pi-rpc/process.js'

function fixture() {
  const conn = new FakeAgentSideConnection()
  const proc = new FakePiRpcProcess()
  const session = new PiAcpSession({
    sessionId: 'session',
    cwd: process.cwd(),
    mcpServers: [],
    proc: proc as unknown as PiRpcProcess,
    conn: asAgentConn(conn),
    fileCommands: []
  })
  return { session, conn, proc }
}
test('steering is consumed inside the active turn and persisted as user input', async () => {
  const { session, proc, conn } = fixture()
  const turn = session.prompt('original', [], 'run')
  proc.emit({ type: 'agent_start' })
  let acknowledged = false
  const receipt = session.steer('run', 'id', 'new requirement').then(value => {
    acknowledged = true
    return value
  })
  await Promise.resolve()
  assert.equal(acknowledged, false)
  assert.equal(proc.prompts.length, 1)
  assert.deepEqual(proc.steers, ['new requirement'])
  assert.throws(() => session.steer('other-run', 'id2', 'wrong'), /Invalid params/)
  assert.throws(() => session.steer('run', 'id', 'different'), /Invalid params/)
  proc.emit({ type: 'message_start', message: { role: 'user', content: [{ type: 'text', text: 'new requirement' }] } })
  assert.deepEqual(await receipt, { applied: true })
  assert.ok(conn.updates.some(update => update.update.sessionUpdate === 'user_message_chunk'))
  await session.steer('run', 'id', 'new requirement')
  assert.equal(proc.steers.length, 1)
  proc.emit({ type: 'agent_settled' })
  await turn
  assert.throws(() => session.steer('run', 'late', 'late'), /Invalid params/)
})
test('stop rejects unconsumed steering and clears Pi queue before reuse', async () => {
  const { session, proc } = fixture()
  const turn = session.prompt('original', [], 'run')
  proc.emit({ type: 'agent_start' })
  const receipt = session.steer('run', 'id', 'new requirement')
  await session.cancel()
  assert.equal(proc.clearQueueCount, 1)
  assert.deepEqual(await receipt, { applied: false })
  proc.emit({ type: 'agent_settled' })
  await turn
})
