import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { hmacHex } from '../hooks/mascot'
import { FACES, TALK } from '../hooks/mascot-data'

// A key shaped like the ones the hooks make: 64 hex characters.
const KEY = '0123456789abcdef'.repeat(4)

// The machine beneath the plugin: its environment, store, clock and the two
// files a roll leaves, signed (or not) the way the status line signs them.
async function machine(on: On, roll: { tier: string; index: number } | null, options: { forged?: boolean } = {}) {
  mock.env(on, { USERPROFILE: '/home/me' })
  mock.store(on)
  const clock = mock.clock(on, { now: 1_800_000_000_000 })
  const files: Record<string, string> = { '.gacha-key': KEY }
  if (roll !== null) {
    const body = `v1 20270115 1800000000 ${roll.tier} ${roll.index}`
    const sig = options.forged ? 'deadbeef' : await hmacHex(KEY, `roll|v1|20270115|1800000000|${roll.tier}|${roll.index}`)
    files['gacha.txt'] = `${body} ${sig}`
  }
  // The engine hands paths on resolved for this machine; the name is enough.
  const at = (path: string) => files[path.split(/[\\/]/).pop() ?? '']
  on('fs.read', (_$, e) => {
    const text = at(e.path)
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.stat', (_$, e) => {
    const text = at(e.path)
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: 'file', size: text.length, mtimeMs: 1, isLink: false } }
  })
  on('env.set', () => ({ value: undefined }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('classic.UserPromptSubmit', () => ({}))
  on('classic.Stop', () => ({}))
  // What the engine draws where the mascot does not.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  return clock
}

const RIGHT = {
  plugin: 'statusline',
  surface: 'terminal',
  component: 'SessionMode',
  props: { modes: [] as string[] },
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

test('the roll signature matches the status line scripts', async () => {
  // RFC 4231 test case 2, and a roll signed by Python's hmac with a hook-made key.
  expect(await hmacHex('Jefe', 'what do ya want for nothing?')).toBe(
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
  )
  expect(await hmacHex(KEY, 'roll|v1|20270115|1800000000|legend|1')).toBe(
    '972b676b2fabadd8b44f57d576b25b1fafa81628615850e426fb833d6ac269ab',
  )
})

test('a legend sits at the right of the footer and moves a shade every 100 ms', async ($, on) => {
  await machine(on, { tier: 'legend', index: 1 })
  await $.session.start({ cwd: '/', surface: 'terminal' })
  const ui = await $.ui.mount(RIGHT)
  const first = async () => (await ui.findAll({ type: 'Text', in: 'mascot' }))[0]

  const start = await first()
  expect(start?.text).toBe(Array.from(WRATH.frames[0]!)[0])
  const startColor = start?.props.color

  await ui.advance(100)
  expect((await first())?.props.color).not.toBe(startColor)
  await ui.advance(600)
  expect((await first())?.props.color).toBe(startColor)
  await ui.unmount()
})

test('it talks while a turn runs, and says something else when it ends', async ($, on) => {
  await machine(on, { tier: 'legend', index: 1 })
  await $.session.start({ cwd: '/', surface: 'terminal' })
  await $.classic.UserPromptSubmit({ prompt: 'go' })
  const ui = await $.ui.mount(RIGHT)
  const drawn = async () => (await ui.findAll({ type: 'Text', in: 'mascot' })).map(t => t.text).join('')

  const working = await drawn()
  expect(TALK.work.legend.some(line => working.endsWith(line))).toBe(true)

  await $.classic.Stop({ stop_hook_active: false })
  await ui.redraw()
  const done = await drawn()
  expect(TALK.done.legend.some(line => done.endsWith(line))).toBe(true)
  await ui.unmount()
})

test('a plain tier is one coloured text', async ($, on) => {
  await machine(on, { tier: 'rare', index: 2 })
  await $.session.start({ cwd: '/', surface: 'terminal' })
  const ui = await $.ui.mount(RIGHT)
  const text = await ui.find({ type: 'Text', in: 'mascot' })
  expect(text?.text).toBe(FACES.rare[2]!.frames[0])
  expect(text?.props.color).toBe('#87d7ff')
  await ui.unmount()
})

test('a forged roll shows no mascot and leaves the footer as it was', async ($, on) => {
  await machine(on, { tier: 'legend', index: 0 }, { forged: true })
  await $.session.start({ cwd: '/', surface: 'terminal' })
  const ui = await $.ui.mount(RIGHT)
  expect(await ui.find({ type: 'Client' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'engine' })).toBeDefined()
  await ui.unmount()
})

test('the chosen place is the only one drawn', async ($, on) => {
  await machine(on, { tier: 'legend', index: 0 })
  await $.session.start({ cwd: '/', surface: 'terminal' })
  const moved = await $.command.run({ command: 'statusline-place', args: 'above' })
  expect(moved.text).toContain('프롬프트 위')
  const above = await $.ui.mount(ABOVE)
  expect(await above.find({ type: 'Client' })).toBeDefined()
  await above.unmount()
  const right = await $.ui.mount(RIGHT)
  expect(await right.find({ type: 'Client' })).toBeUndefined()
  await right.unmount()
})
