import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { MascotPlace, MascotRoll, MascotTurn } from '../types'
import { ERROR_FRAMES, FACES, FLAT, SHIMMER, TALK, TALK_ERROR, UNIQUE_RAMP } from './mascot-data'
import type { FaceProps } from './mascot-face'

// The mascot, drawn by Claude Code itself under the prompt so a legend can
// shimmer every 100 ms; the status line only redraws every second or two.
// The face, the roll and the spoken lines follow the status line's own rules.

const PLACES: Record<MascotPlace, string> = {
  right: '프롬프트 아래 오른쪽',
  left: '프롬프트 아래 왼쪽',
  above: '프롬프트 위',
  line: '상태줄 끝 (예전 방식, 반짝임 없음)',
}
const DEFAULT_PLACE: MascotPlace = 'right'
// How long after a turn ends the mascot keeps talking.
const TALK_WINDOW_MS = 60_000
// How often the roll file is looked at, so a new roll shows within seconds.
const ROLL_POLL_MS = 3_000

const place = atom({ plugin: 'statusline', key: 'place' } as const, DEFAULT_PLACE)
const turn = atom({ plugin: 'statusline', key: 'turn' } as const, { state: 'idle', stamp: 0 })
const roll = atom({ plugin: 'statusline', key: 'roll' } as const, null)

type Settings = { isShown: boolean; isTalking: boolean; isColored: boolean; cacheDir: string }

// The status line's own switches, read once per load.
let settings: Promise<Settings> | undefined
function loadSettings($: EngineInterface): Promise<Settings> {
  settings ??= (async () => {
    const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? ''
    const cacheDir = (await $.env.get('STATUSLINE_CACHE_DIR')) || `${home}/.claude/statusline-cache`
    return {
      isShown: (await $.env.get('STATUSLINE_MASCOT')) !== '0',
      isTalking: (await $.env.get('STATUSLINE_TALK')) !== '0',
      isColored: !(await $.env.get('NO_COLOR')),
      cacheDir,
    }
  })()
  return settings
}

function isPlace(text: string): text is MascotPlace {
  return Object.hasOwn(PLACES, text)
}

function isTier(text: string): text is MascotRoll['tier'] {
  return Object.hasOwn(FACES, text)
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', data))
}

// HMAC-SHA256 as lowercase hex, built on digest alone: the environment's
// crypto.subtle has no importKey or sign.
export async function hmacHex(key: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  let k = enc.encode(key)
  if (k.length > 64) k = await sha256(k)
  const pad = (byte: number) => {
    const out = new Uint8Array(64).fill(byte)
    k.forEach((b, i) => {
      out[i] = b ^ byte
    })
    return out
  }
  const join = (a: Uint8Array, b: Uint8Array) => {
    const out = new Uint8Array(a.length + b.length)
    out.set(a)
    out.set(b, a.length)
    return out
  }
  const inner = await sha256(join(pad(0x36), enc.encode(message)))
  const mac = await sha256(join(pad(0x5c), inner))
  return Array.from(mac, b => b.toString(16).padStart(2, '0')).join('')
}

// The roll on file, or null when there is none or its signature is wrong:
// an edited file loses the mascot rather than granting a better one.
async function readRoll($: EngineInterface, cacheDir: string): Promise<MascotRoll | null> {
  try {
    const key = (await $.fs.read(`${cacheDir}/.gacha-key`)).trim()
    const tok = (await $.fs.read(`${cacheDir}/gacha.txt`)).trim().split(/\s+/)
    const [v, date, stamp, tier, idx, sig] = tok
    if (key === '' || v !== 'v1' || tier === undefined || !isTier(tier)) return null
    if ((await hmacHex(key, `roll|v1|${date}|${stamp}|${tier}|${idx}`)) !== sig) return null
    const index = Number(idx)
    if (!Number.isInteger(index) || index < 0 || index >= FACES[tier].length) return null
    return { tier, index }
  } catch {
    return null
  }
}

let rollSeenAt = -1
async function refreshRoll($: EngineInterface): Promise<void> {
  const { cacheDir } = await loadSettings($)
  let mtime = 0
  try {
    mtime = (await $.fs.stat(`${cacheDir}/gacha.txt`)).mtimeMs
  } catch {
    mtime = 0
  }
  if (mtime === rollSeenAt) return
  rollSeenAt = mtime
  const now = await readRoll($, cacheDir)
  await update($, roll, old =>
    old?.tier === now?.tier && old?.index === now?.index ? old : now,
  )
}

// Tells the status line whether to leave its own face out.
async function applyPlace($: EngineInterface, where: MascotPlace): Promise<void> {
  const { isShown } = await loadSettings($)
  await $.env.set('STATUSLINE_MASCOT_BY_MOD', isShown && where !== 'line' ? '1' : undefined)
}

// The same pick as the status line: seeded by the turn's stamp, so the line
// holds steady through the turn and changes with the next one.
function pickTalk(pool: string[] | undefined, stamp: number): string {
  if (pool === undefined || pool.length === 0) return ''
  let h = (BigInt(stamp) * 1103515245n + 12345n) % 2147483648n
  if (h < 0n) h = -h
  return pool[Number(h % BigInt(pool.length))] ?? ''
}

// What the face instance is handed, or null when there is nothing to show.
async function faceProps($: EngineInterface): Promise<FaceProps | null> {
  const s = await loadSettings($)
  if (!s.isShown) return null
  const t: MascotTurn = await read($, turn)
  const talkOf = (pool: string[] | undefined) => (s.isTalking ? pickTalk(pool, t.stamp) : '')

  if (t.state === 'error') {
    return {
      frames: ERROR_FRAMES,
      talk: talkOf(TALK_ERROR),
      paint: s.isColored ? 'flat' : 'plain',
      colors: [FLAT.error ?? ''],
      bold: false,
      animate: true,
    }
  }

  const r = await read($, roll)
  if (r === null) return null
  const face = FACES[r.tier][r.index]
  if (face === undefined) return null
  const talk =
    t.state === 'working'
      ? talkOf(TALK.work[r.tier])
      : t.state === 'notify'
        ? talkOf(TALK.notify[r.tier])
        : t.state === 'done'
          ? talkOf(TALK.done[r.tier])
          : ''
  const base = { frames: face.frames, talk, animate: t.state === 'working' }

  if (!s.isColored) return { ...base, paint: 'plain', colors: [], bold: false }
  if (r.tier === 'legend') return { ...base, paint: 'shimmer', colors: SHIMMER[r.index] ?? [], bold: false }
  if (r.tier === 'unique') return { ...base, paint: 'gradient', colors: UNIQUE_RAMP, bold: false }
  return { ...base, paint: 'flat', colors: [FLAT[r.tier] ?? ''], bold: r.tier === 'dev' }
}

async function setTurn($: EngineInterface, state: MascotTurn['state']): Promise<number> {
  const stamp = Math.floor((await $.clock.now()) / 1000)
  await update($, turn, () => ({ state, stamp }))
  return stamp
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'statusline-place',
      description: '마스코트 위치 바꾸기: right(아래 오른쪽) · left(아래 왼쪽) · above(위) · line(상태줄 끝)',
      argumentHint: '[right|left|above|line]',
      immediate: true,
    })
    const saved = await $.store.get('place')
    const where = typeof saved === 'string' && isPlace(saved) ? saved : DEFAULT_PLACE
    await update($, place, () => where)
    await applyPlace($, where)
    rollSeenAt = -1
    await refreshRoll($)
    $.clock.every(ROLL_POLL_MS, () => {
      refreshRoll($).catch(() => undefined)
    })

    return next(e)
  })

  on('command.run', { command: 'statusline-place' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === '') {
      const now = await read($, place)
      return { text: `마스코트 위치: ${PLACES[now]}\n바꾸려면 /statusline-place right · left · above · line` }
    }
    if (!isPlace(arg)) {
      return { text: `그런 위치는 없습니다: ${arg}\n고를 수 있는 값: right · left · above · line` }
    }
    await update($, place, () => arg)
    await $.store.set('place', arg)
    await applyPlace($, arg)
    return { text: `마스코트 위치: ${PLACES[arg]}` }
  })

  // The turn's states, from the same events the status line's hooks use. A
  // failure here never holds the event up: the catch lets it go on.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    await setTurn($, 'working')
    return next(e)
  }).catch(($, e, next) => next(e))

  on('classic.Stop', async ($, e, next) => {
    const stamp = await setTurn($, 'done')
    $.clock.after(TALK_WINDOW_MS, () => {
      update($, turn, t => (t.state === 'done' && t.stamp === stamp ? { state: 'idle', stamp } : t)).catch(
        () => undefined,
      )
    })
    return next(e)
  }).catch(($, e, next) => next(e))

  on('classic.StopFailure', async ($, e, next) => {
    await setTurn($, 'error')
    return next(e)
  }).catch(($, e, next) => next(e))

  on('classic.Notification', async ($, e, next) => {
    await setTurn($, 'notify')
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || (await read($, place)) !== 'right') return next(e)
    const props = await faceProps($)
    if (props === null) return next(e)
    const { Box, Text, Client } = $.ui.resolve(e)
    const modes = e.props.modes.join(' & ')
    return (
      <Box flexDirection="row">
        {modes !== '' && <Text dimColor>{modes} </Text>}
        <Client key="mascot" module="./mascot-face.tsx" props={props} />
      </Box>
    )
  })

  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    // Whatever the engine has to say there (a second Ctrl-C, a hint) wins.
    if (e.surface !== 'terminal' || e.props.hint.trim() !== '' || (await read($, place)) !== 'left') return next(e)
    const props = await faceProps($)
    if (props === null) return next(e)
    const { Box, Client } = $.ui.resolve(e)
    return (
      <Box>
        <Client key="mascot" module="./mascot-face.tsx" props={props} />
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.hasSurvey || (await read($, place)) !== 'above') return next(e)
    const props = await faceProps($)
    if (props === null) return next(e)
    const { Box, Client } = $.ui.resolve(e)
    return (
      <Box>
        <Client key="mascot" module="./mascot-face.tsx" props={props} />
      </Box>
    )
  })
}
