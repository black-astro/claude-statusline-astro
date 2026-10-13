import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { hmacHex } from '../hooks/mascot'
import { FACES, TALK } from '../hooks/mascot-data'

// A key shaped like the ones the hooks make: 64 hex characters.
const KEY = '0123456789abcdef'.repeat(4)
const SCRIPT_LINE = { type: 'command', command: 'powershell -File C:/Users/me/.claude/statusline.ps1', refreshInterval: 2 }

// The machine beneath the plugin: its environment, store, clock, files (the
// roll, the key, settings.json and the shared rate-limit readings) and what
// the session reports.
async function machine(on: On, roll: { tier: string; index: number } | null, options: { forged?: boolean } = {}) {
  mock.env(on, { USERPROFILE: '/home/me' })
  mock.store(on)
  const clock = mock.clock(on, { now: 1_800_000_000_000 })
  const files: Record<string, string> = {
    '.gacha-key': KEY,
    'settings.json': JSON.stringify({ theme: 'dark', statusLine: SCRIPT_LINE }),
    'rl-peer0001.txt': 'v1 80 1800003600 10 1800500000\n',
  }
  if (roll !== null) {
    const body = `v1 20270115 1800000000 ${roll.tier} ${roll.index}`
    const sig = options.forged ? 'deadbeef' : await hmacHex(KEY, `roll|v1|20270115|1800000000|${roll.tier}|${roll.index}`)
    files['gacha.txt'] = `${body} ${sig}`
  }
  // The engine hands paths on resolved for this machine; the name is enough.
  const at = (path: string) => path.split(/[\\/]/).pop() ?? ''
  on('fs.read', (_$, e) => {
    const text = files[at(e.path)]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    files[at(e.path)] = e.text
    return { value: undefined }
  })
  on('fs.stat', (_$, e) => {
    const text = files[at(e.path)]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: 'file', size: text.length, mtimeMs: 1, isLink: false } }
  })
  on('fs.list', () => ({
    value: Object.keys(files).map(name => ({ name, kind: 'file', size: 1, mtimeMs: 1, isLink: false })),
  }))
  on('env.set', () => ({ value: undefined }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('session.cwd', () => ({ value: '/work/my-project' }))
  on('session.id', () => ({ value: 'abcd1234-5678' }))
  on('session.model', () => ({ value: 'Opus 5.5' }))
  on('session.usage', () => ({
    value: {
      startedAt: 0,
      context: { window: 200000, percent: 42 },
      rateLimits: [{ kind: 'five_hour', percentUsed: 63, resetsAt: '2027-01-15T09:00:00Z' }],
    },
  }))
  on('process.run', () => ({
    value: { exitCode: 0, stdout: '/work/my-project\nmain\nabc123\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('classic.UserPromptSubmit', () => ({}))
  on('classic.Stop', () => ({}))
  on('tool.call', () => ({ result: {} }))
  on('command.run', () => ({ text: 'engine' }))
  // What the engine draws where the plugin does not.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  return { clock, files }
}

const RIGHT = {
  plugin: 'statusline',
  surface: 'terminal',
  component: 'SessionMode',
  props: { modes: [] as string[] },
} as const

const HINT = {
  plugin: 'statusline',
  surface: 'terminal',
  component: 'PromptHint',
  props: { isDraft: false, isWorking: false, hint: '' },
} as const

const ABOVE = {
  plugin: 'statusline',
  surface: 'terminal',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const WRATH = FACES.legend[1]!
const start = { cwd: '/', surface: 'terminal' } as const

test('the roll signature matches the status line scripts', async () => {
  // RFC 4231 test case 2, and a roll signed by Python's hmac with a hook-made key.
  expect(await hmacHex('Jefe', 'what do ya want for nothing?')).toBe(
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
  )
  expect(await hmacHex(KEY, 'roll|v1|20270115|1800000000|legend|1')).toBe(
    '972b676b2fabadd8b44f57d576b25b1fafa81628615850e426fb833d6ac269ab',
  )
})

test('a legend sits at the right of the footer, bold, and walks its hues every 100 ms', async ($, on) => {
  await machine(on, { tier: 'legend', index: 1 })
  await $.session.start(start)
  const ui = await $.ui.mount(RIGHT)
  const first = async () => (await ui.findAll({ type: 'Text', in: 'mascot' }))[0]

  const head = await first()
  expect(head?.text).toBe(Array.from(WRATH.frames[0]!)[0])
  expect(head?.props.bold).toBe(true)
  const startColor = head?.props.color

  await ui.advance(100)
  expect((await first())?.props.color).not.toBe(startColor)
  await ui.advance(600)
  expect((await first())?.props.color).toBe(startColor)
  await ui.unmount()
})

test('while working it rotates lines, gives a riddle its answer later, and says what it is doing', async ($, on) => {
  await machine(on, { tier: 'legend', index: 1 })
  await $.session.start(start)
  await $.classic.UserPromptSubmit({ prompt: 'go' })
  const ui = await $.ui.mount(RIGHT)
  const said = async () => (await ui.findAll({ type: 'Text', in: 'mascot' })).map(t => t.text).join('')
  const legend = TALK.legend
  const known = [...legend.work, ...legend.quiz.flatMap(r => [r.q, `${r.q} ${r.a}`])]

  // Over a full round every line comes up, and each riddle gets its answer.
  const seen = new Set<string>()
  for (let i = 0; i < (legend.work.length + legend.quiz.length) * 2; i++) {
    const text = await said()
    const line = known.find(k => text.endsWith(k))
    expect(line).toBeDefined()
    seen.add(line!)
    await ui.advance(5_000)
  }
  for (const r of legend.quiz) expect(seen.has(`${r.q} ${r.a}`)).toBe(true)

  // A tool call that edits makes it say so first.
  await $.tool.call({ tool: 'Edit', file_path: '/work/a.ts', old_string: 'a', new_string: 'b' })
  await ui.redraw()
  expect((await said()).endsWith(legend.activity.edit!)).toBe(true)

  await $.classic.Stop({ stop_hook_active: false })
  await ui.redraw()
  const done = await said()
  expect(legend.done.some(line => done.endsWith(line))).toBe(true)
  await ui.unmount()
})

test('the higher the tier, the more it has to say', () => {
  const amount = (t: keyof typeof TALK) => TALK[t].work.length + TALK[t].quiz.length + Object.keys(TALK[t].activity).length
  expect(amount('common')).toBeLessThan(amount('rare'))
  expect(amount('rare')).toBeLessThanOrEqual(amount('unique'))
  expect(amount('unique')).toBeLessThanOrEqual(amount('legend'))
  expect(Object.keys(TALK.common.activity)).toHaveLength(0)
  expect(Object.keys(TALK.legend.activity).length).toBeGreaterThan(0)
})

test('a plain tier is one coloured text', async ($, on) => {
  await machine(on, { tier: 'rare', index: 2 })
  await $.session.start(start)
  const ui = await $.ui.mount(RIGHT)
  const text = await ui.find({ type: 'Text', in: 'mascot' })
  expect(text?.text).toBe(FACES.rare[2]!.frames[0])
  expect(text?.props.color).toBe('#87d7ff')
  await ui.unmount()
})

test('a forged roll shows no mascot and leaves the footer as it was', async ($, on) => {
  await machine(on, { tier: 'legend', index: 0 }, { forged: true })
  await $.session.start(start)
  const ui = await $.ui.mount(RIGHT)
  expect(await ui.find({ type: 'Client' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'engine' })).toBeDefined()
  await ui.unmount()
})

test('the chosen place is the only one drawn', async ($, on) => {
  await machine(on, { tier: 'legend', index: 0 })
  await $.session.start(start)
  const moved = await $.command.run({ command: 'statusline-place', args: 'above' })
  expect(moved.text).toContain('프롬프트 위')
  const above = await $.ui.mount(ABOVE)
  expect(await above.find({ type: 'Client' })).toBeDefined()
  await above.unmount()
  const right = await $.ui.mount(RIGHT)
  expect(await right.find({ type: 'Client' })).toBeUndefined()
  await right.unmount()
})

test('app mode draws the info line itself, switches the script off, and gives it back', async ($, on) => {
  const { files } = await machine(on, { tier: 'legend', index: 1 })
  await $.session.start(start)

  const hint0 = await $.ui.mount(HINT)
  expect(await hint0.find({ type: 'Text', text: 'engine' })).toBeDefined()
  await hint0.unmount()

  const on1 = await $.command.run({ command: 'statusline-mode', args: 'app' })
  expect(on1.text).toContain('앱')
  const settings = JSON.parse(files['settings.json']!)
  expect(settings.statusLine.command).toBe('exit 0')
  expect(settings.theme).toBe('dark')

  // By default the line takes the row of its own above the prompt, as one
  // Text cut at the row's end, never wrapped.
  const band = await $.ui.mount(ABOVE)
  const whole = (await band.findAll({ type: 'Text' }))[0]
  expect(whole?.props.wrap).toBe('truncate-end')
  const line = whole?.text ?? ''
  expect(line).toContain('DIR my-project')
  expect(line).toContain('GIT main')
  expect(line).toContain('MODEL Opus 5.5')
  expect(line).toContain('42%')
  // The other session's newer window wins.
  expect(line).toContain('80%')
  await band.unmount()
  const hintAbove = await $.ui.mount(HINT)
  expect(await hintAbove.find({ type: 'Text', text: 'engine' })).toBeDefined()
  await hintAbove.unmount()

  // Placed below, it moves under the prompt and leaves the band alone.
  const below = await $.command.run({ command: 'statusline-mode', args: 'app below' })
  expect(below.text).toContain('프롬프트 아래')
  const hint = await $.ui.mount(HINT)
  const under = (await hint.findAll({ type: 'Text' }))[0]
  expect(under?.props.wrap).toBe('truncate-end')
  expect(under?.text).toContain('DIR my-project')
  await hint.unmount()
  const band2 = await $.ui.mount(ABOVE)
  expect(await band2.find({ type: 'Text', text: 'engine' })).toBeDefined()
  await band2.unmount()

  const off = await $.command.run({ command: 'statusline-mode', args: 'script' })
  expect(off.text).toContain('스크립트')
  expect(JSON.parse(files['settings.json']!).statusLine).toEqual(SCRIPT_LINE)
  const hint2 = await $.ui.mount(HINT)
  expect(await hint2.find({ type: 'Text', text: 'engine' })).toBeDefined()
  await hint2.unmount()
})
