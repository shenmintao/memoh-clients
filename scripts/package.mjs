import { execFileSync } from 'node:child_process'
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const out = resolve(root, 'artifacts')
mkdirSync(out, { recursive: true })
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm'
for (const [directory, name] of [['packages/runtime', 'runtime'], ['adapters/pi-acp', 'pi-acp'], ['adapters/codex-acp', 'codex-acp']]) {
  const result = execFileSync(npm, ['pack', '--ignore-scripts', '--json', '--pack-destination', '../../artifacts'], { cwd: resolve(root, directory), encoding: 'utf8', shell: process.platform === 'win32' })
  const file = JSON.parse(result)[0].filename
  writeFileSync(resolve(out, `${name}.tgz`), readFileSync(resolve(out, file)))
}
const sums = readdirSync(out).filter(file => ['runtime.tgz', 'pi-acp.tgz', 'codex-acp.tgz'].includes(file)).sort().map(file => `${createHash('sha256').update(readFileSync(resolve(out, file))).digest('hex')}  ${file}`)
writeFileSync(resolve(out, 'SHA256SUMS'), `${sums.join('\n')}\n`)
