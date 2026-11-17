// Captures real ACP traffic from a local backend into test fixtures.
//
//   node tool/acp/capture.mjs opencode  out.jsonl  "say hi"
//   node tool/acp/capture.mjs claude    out.jsonl --no-prompt
//
// No account is required: OpenCode answers `session/new` and runs a turn with
// one of its free models, and Claude Code answers `initialize` / `session/new`
// before login. Nothing outside the temporary directory is touched.
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const [, , backend = 'opencode', outFile, prompt = 'Reply with one short sentence.', ...flags] = process.argv
const noPrompt = flags.includes('--no-prompt')
const timeoutMs = Number(process.env.ACP_CAPTURE_TIMEOUT_MS ?? 120000)

const commands = {
  opencode: { bin: process.env.OPENCODE_BIN ?? 'opencode', args: ['acp'] },
  claude: {
    bin: process.env.CLAUDE_ACP_NODE ?? 'node',
    args: [process.env.CLAUDE_ACP_ENTRY ?? ''],
  },
}

const spec = commands[backend]
if (!spec || (backend === 'claude' && !spec.args[0])) {
  console.error(`usage: capture.mjs <opencode|claude> <out.jsonl> [prompt] [--no-prompt]`)
  console.error('  claude needs CLAUDE_ACP_NODE and CLAUDE_ACP_ENTRY')
  process.exit(2)
}

const cwd = mkdtempSync(join(tmpdir(), 'acp-capture-'))
const child = spawn(spec.bin, spec.args, { cwd, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true })
const received = []
let buffer = ''
let finished = false

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`)
}

function finish(code) {
  if (finished) return
  finished = true
  try {
    writeFileSync(outFile, received.map((frame) => JSON.stringify(frame)).join('\n') + '\n', 'utf8')
  } finally {
    child.kill()
    try {
      rmSync(cwd, { recursive: true, force: true })
    } catch {}
  }
  console.log(`${received.length} frames -> ${outFile}`)
  process.exit(code)
}

child.stdout.setEncoding('utf8')
child.stdout.on('data', (chunk) => {
  buffer += chunk
  let index
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim()
    buffer = buffer.slice(index + 1)
    if (!line) continue
    let message
    try {
      message = JSON.parse(line)
    } catch {
      continue
    }
    if (message.id === 1 && message.result) {
      send({ jsonrpc: '2.0', id: 2, method: 'session/new', params: { cwd, mcpServers: [] } })
    } else if (message.id === 2 && message.result?.sessionId && !noPrompt) {
      send({
        jsonrpc: '2.0',
        id: 3,
        method: 'session/prompt',
        params: { sessionId: message.result.sessionId, prompt: [{ type: 'text', text: prompt }] },
      })
    } else if (message.id === 3) {
      received.push(message)
      finish(0)
      return
    } else if (message.method === 'session/update') {
      received.push(message)
      if (message.params?.update?.sessionUpdate === 'prompt_completed') finish(0)
    } else if (message.id === 1 || message.id === 2) {
      received.push(message)
      if (noPrompt && message.id === 2) finish(0)
    }
  }
})

child.stderr.setEncoding('utf8')
child.stderr.on('data', (chunk) => process.stderr.write(chunk))

setTimeout(() => finish(received.length > 0 ? 0 : 1), timeoutMs)

send({
  jsonrpc: '2.0',
  id: 1,
  method: 'initialize',
  params: { protocolVersion: 1, clientInfo: { name: 'dsh-capture', version: '0.1.0' } },
})
