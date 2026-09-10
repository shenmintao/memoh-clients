import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { spawn } from 'node:child_process'

const home = homedir()
const config = JSON.parse(readFileSync(join(home, '.memoh/runtime.json'), 'utf8'))
const key = readFileSync(join(home, '.memoh/runtime-key'), 'utf8').trim()
const child = spawn(process.execPath, [join(home, '.local/lib/node_modules/@memohai/runtime/dist/cli.mjs')], {
  stdio: 'inherit',
  env: { ...process.env, MEMOH_RUNTIME_SERVER: config.server, MEMOH_RUNTIME_KEY: key },
})
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => child.kill(signal))
child.on('error', () => process.exit(1))
child.on('exit', code => process.exit(code ?? 1))
