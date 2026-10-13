import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LineInfo, LineMode, LinePlace, LineWindow, MascotActivity, MascotPlace, MascotRoll, MascotTurn } from '../types'
import { ERROR_FRAMES, FACES, FLAT, SHIMMER, TALK, UNIQUE_RAMP } from './mascot-data'
import type { Activity, Riddle } from './mascot-data'
import type { FaceProps, TalkPlan } from './mascot-face'

// The mascot, drawn by Claude Code itself under the prompt so a legend can
// shimmer every 100 ms; the status line only redraws every second or two.
// In app mode the info line (DIR, GIT, MODEL, CTX, 5H) is drawn here too and
// the status line command is switched off, so no script runs at all.

const PLACES: Record<MascotPlace, string> = {
  right: '프롬프트 아래 오른쪽',
  left: '프롬프트 아래 왼쪽',
  above: '프롬프트 위',
  line: '상태줄 끝 (예전 방식, 반짝임 없음)',
}
const MODES: Record<LineMode, string> = {
  script: '스크립트 (상태줄을 스크립트가 그림, 기본)',
  app: '앱 (정보 줄도 플러그인이 그리고 스크립트는 멈춤)',
}
const LINE_PLACES: Record<LinePlace, string> = {
  above: '프롬프트 바로 위 (한 줄 전체)',
  below: '프롬프트 아래 (모드 표시 옆, 넘치면 끝을 자름)',
}
const DEFAULT_PLACE: MascotPlace = 'right'
// What the status line runs while the plugin draws the info line: nothing.
const APP_COMMAND = 'exit 0'
// How long after a turn ends the mascot keeps talking.
const TALK_WINDOW_MS = 60_000
// How often the roll file is looked at, so a new roll shows within seconds.
const ROLL_POLL_MS = 3_000
// How often the info line is refreshed in app mode.
const INFO_POLL_MS = 2_000
const BAR_LENGTH = 10
const DIR_MAX = 32
const WARN_AT = 60
const CRIT_AT = 90

const place = atom({ plugin: 'statusline', key: 'place' } as const, DEFAULT_PLACE)
const mode = atom({ plugin: 'statusline', key: 'mode' } as const, 'script')
const linePlace = atom({ plugin: 'statusline', key: 'linePlace' } as const, 'above')
const turn = atom({ plugin: 'statusline', key: 'turn' } as const, { state: 'idle', stamp: 0 })
const activity = atom({ plugin: 'statusline', key: 'activity' } as const, null)
const roll = atom({ plugin: 'statusline', key: 'roll' } as const, null)
const info = atom({ plugin: 'statusline', key: 'info' } as const, null)

type Settings = {
  isShown: boolean
  isTalking: boolean
  isColored: boolean
  showsWeek: boolean
  cacheDir: string
  settingsFile: string
}

// The status line's own switches, read once per load.
let settings: Promise<Settings> | undefined
function loadSettings($: EngineInterface): Promise<Settings> {
  settings ??= (async () => {
    const home = (await $.env.get('USERPROFILE')) || (await $.env.get('HOME')) || ''
    const config = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${home}/.claude`
    return {
      isShown: (await $.env.get('STATUSLINE_MASCOT')) !== '0',
      isTalking: (await $.env.get('STATUSLINE_TALK')) !== '0',
      isColored: !(await $.env.get('NO_COLOR')),
      showsWeek: (await $.env.get('STATUSLINE_SEVEN_DAY')) === '1',
      cacheDir: (await $.env.get('STATUSLINE_CACHE_DIR')) || `${home}/.claude/statusline-cache`,
      settingsFile: `${config}/settings.json`,
    }
  })()
  return settings
}

function isPlace(text: string): text is MascotPlace {
  return Object.hasOwn(PLACES, text)
}

function isMode(text: string): text is LineMode {
  return Object.hasOwn(MODES, text)
}

function isLinePlace(text: string): text is LinePlace {
  return Object.hasOwn(LINE_PLACES, text)
}

function isTier(text: string): text is MascotRoll['tier'] {
  return Object.hasOwn(FACES, text)
}

// ---- roll ------------------------------------------------------------------

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
  await update($, roll, old => (old?.tier === now?.tier && old?.index === now?.index ? old : now))
}

// ---- talk ------------------------------------------------------------------

// The status line's pick: seeded by the turn's stamp, so a line holds through
// the turn and changes with the next one.
function seeded(stamp: number, n: number): number {
  if (n <= 0) return 0
  let h = (BigInt(stamp) * 1103515245n + 12345n) % 2147483648n
  if (h < 0n) h = -h
  return Number(h % BigInt(n))
}

const SILENT: TalkPlan = { lead: '', leadKey: '', lines: [], start: 0, rotate: false }
const plain = (q: string) => ({ q, a: '' })

// Work lines with a riddle after every second one, so jokes come now and then.
function workLines(work: string[], quiz: Riddle[]): { q: string; a: string }[] {
  const out: { q: string; a: string }[] = []
  let r = 0
  work.forEach((line, i) => {
    out.push(plain(line))
    if (i % 2 === 1 && r < quiz.length) out.push(quiz[r++]!)
  })
  while (r < quiz.length) out.push(quiz[r++]!)
  return out
}

function talkPlan(t: MascotTurn, tier: MascotRoll['tier'], act: MascotActivity | null): TalkPlan {
  const say = TALK[tier]
  const once = (pool: string[]) => ({ ...SILENT, lines: pool.map(plain), start: seeded(t.stamp, pool.length) })
  switch (t.state) {
    case 'working': {
      const lines = workLines(say.work, say.quiz)
      const lead = act !== null ? (say.activity[act.kind as Activity] ?? '') : ''
      const leadKey = act !== null ? `${act.kind}:${act.since}` : ''
      return { lead, leadKey, lines, start: seeded(t.stamp, lines.length), rotate: true }
    }
    case 'done':
      return once(say.done)
    case 'notify':
      return once(say.notify)
    case 'error':
      return once(say.error)
    default:
      return SILENT
  }
}

// What the face instance is handed, or null when there is nothing to show.
async function faceProps($: EngineInterface): Promise<FaceProps | null> {
  const s = await loadSettings($)
  if (!s.isShown) return null
  const t: MascotTurn = await read($, turn)
  const r = await read($, roll)

  if (t.state === 'error') {
    const talk = s.isTalking ? talkPlan(t, r?.tier ?? 'rare', null) : SILENT
    return {
      frames: ERROR_FRAMES,
      talk,
      paint: s.isColored ? 'flat' : 'plain',
      colors: [FLAT.error ?? ''],
      bold: false,
      animate: true,
    }
  }

  if (r === null) return null
  const face = FACES[r.tier][r.index]
  if (face === undefined) return null
  const talk = s.isTalking ? talkPlan(t, r.tier, await read($, activity)) : SILENT
  const base = { frames: face.frames, talk, animate: t.state === 'working' }

  if (!s.isColored) return { ...base, paint: 'plain', colors: [], bold: false }
  // Legend wears seven hues of its own colour, bold, walked like "max".
  if (r.tier === 'legend') return { ...base, paint: 'shimmer', colors: SHIMMER[r.index] ?? [], bold: true }
  if (r.tier === 'unique') return { ...base, paint: 'gradient', colors: UNIQUE_RAMP, bold: false }
  return { ...base, paint: 'flat', colors: [FLAT[r.tier] ?? ''], bold: r.tier === 'dev' }
}

async function setTurn($: EngineInterface, state: MascotTurn['state']): Promise<number> {
  const stamp = Math.floor((await $.clock.now()) / 1000)
  await update($, turn, () => ({ state, stamp }))
  return stamp
}

const TOOL_KINDS: Record<string, MascotActivity['kind']> = {
  Read: 'read',
  NotebookRead: 'read',
  Glob: 'search',
  Grep: 'search',
  Edit: 'edit',
  MultiEdit: 'edit',
  Write: 'edit',
  NotebookEdit: 'edit',
  Bash: 'run',
  PowerShell: 'run',
  WebFetch: 'web',
  WebSearch: 'web',
  Agent: 'agent',
  Task: 'agent',
}

// ---- place and mode --------------------------------------------------------

// Tells the status line whether to leave its own face out.
async function applyPlace($: EngineInterface, where: MascotPlace, how: LineMode): Promise<void> {
  const { isShown } = await loadSettings($)
  const isOurs = isShown && (how === 'app' || where !== 'line')
  await $.env.set('STATUSLINE_MASCOT_BY_MOD', isOurs ? '1' : undefined)
}

type SettingsJson = Record<string, unknown> & { statusLine?: { command?: string } & Record<string, unknown> }

async function readSettingsFile($: EngineInterface): Promise<SettingsJson | null> {
  const { settingsFile } = await loadSettings($)
  try {
    const parsed: unknown = JSON.parse(await $.fs.read(settingsFile))
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as SettingsJson) : null
  } catch {
    return null
  }
}

async function writeSettingsFile($: EngineInterface, json: SettingsJson): Promise<void> {
  const { settingsFile } = await loadSettings($)
  await $.fs.write(settingsFile, `${JSON.stringify(json, null, 2)}\n`)
}

// Switches the status line command off (app) or back to what it was (script).
// The original entry is kept in the cache folder, so it survives the plugin.
async function switchMode($: EngineInterface, to: LineMode): Promise<string | null> {
  const { cacheDir } = await loadSettings($)
  const json = await readSettingsFile($)
  if (json === null) return 'settings.json을 읽지 못했습니다.'
  const saved = `${cacheDir}/statusline-setting.json`
  if (to === 'app') {
    if (json.statusLine === undefined) return '설정에 상태줄이 없습니다. 먼저 /statusline-install 을 실행하세요.'
    if (json.statusLine.command !== APP_COMMAND) await $.fs.write(saved, JSON.stringify(json.statusLine))
    json.statusLine = { type: 'command', command: APP_COMMAND }
  } else {
    if (json.statusLine?.command !== APP_COMMAND) return null
    try {
      json.statusLine = JSON.parse(await $.fs.read(saved)) as SettingsJson['statusLine']
    } catch {
      return '예전 상태줄 설정을 찾지 못했습니다. /statusline-install 로 다시 설치하세요.'
    }
  }
  await writeSettingsFile($, json)
  return null
}

// ---- info line (app mode) --------------------------------------------------

function leafName(path: string): string {
  const parts = path.replace(/[\\/]+$/, '').split(/[\\/]/)
  const name = parts[parts.length - 1] || path
  return name.length > DIR_MAX ? `…${name.slice(name.length - DIR_MAX + 1)}` : name
}

function epochOf(iso: string | undefined): number {
  if (iso === undefined) return 0
  const ms = Date.parse(iso)
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0
}

// The best reading any session published: the newest window wins, and within
// the same window the highest reading, as the status line scripts do.
function best(a: LineWindow | null, b: LineWindow | null): LineWindow | null {
  if (a === null) return b
  if (b === null) return a
  if (b.resets > a.resets) return b
  if (b.resets === a.resets && b.used > a.used) return b
  return a
}

let gitAt = 0
let gitCache = { root: '', branch: '' }
async function gitOf($: EngineInterface, cwd: string, now: number): Promise<{ root: string; branch: string }> {
  if (now - gitAt < 5_000) return gitCache
  gitAt = now
  try {
    const argv = ['git', '-C', cwd, 'rev-parse', '--show-toplevel', '--abbrev-ref', 'HEAD', '--short', 'HEAD']
    const run = await $.process.run(argv, { timeoutMs: 3_000 })
    const lines = run.stdout.split(/\r?\n/).map(l => l.trim())
    let branch = lines[1] ?? ''
    if (branch === 'HEAD') branch = lines[2] ?? ''
    gitCache = run.exitCode === 0 ? { root: lines[0] ?? '', branch } : { root: '', branch: '' }
  } catch {
    gitCache = { root: '', branch: '' }
  }
  return gitCache
}

async function refreshInfo($: EngineInterface): Promise<void> {
  if ((await read($, mode)) !== 'app') return
  const { cacheDir } = await loadSettings($)
  const now = await $.clock.now()
  const cwd = await $.session.cwd()
  const git = await gitOf($, cwd, now)
  const usage = await $.session.usage()
  const win = (kind: string): LineWindow | null => {
    const w = usage.rateLimits.find(x => x.kind === kind)
    return w === undefined ? null : { used: Math.round(w.percentUsed), resets: epochOf(w.resetsAt) }
  }
  let five = win('five_hour')
  let seven = win('seven_day')

  // Share this session's reading and take the best one any session has seen.
  try {
    const sid = (await $.session.id()).replace(/[^a-zA-Z0-9]/g, '').slice(0, 8)
    const field = (w: LineWindow | null, f: 'used' | 'resets') => (w === null || w[f] === 0 ? '-' : String(w[f]))
    if (five !== null && sid !== '') {
      const line = `v1 ${five.used} ${field(five, 'resets')} ${field(seven, 'used')} ${field(seven, 'resets')}\n`
      await $.fs.write(`${cacheDir}/rl-${sid}.txt`, line)
    }
    const of = (u: string | undefined, r: string | undefined): LineWindow | null => {
      const used = Number(u)
      return u !== undefined && u !== '-' && Number.isFinite(used) ? { used: Math.round(used), resets: Number(r) || 0 } : null
    }
    for (const entry of await $.fs.list(cacheDir)) {
      if (!/^rl-.*\.txt$/.test(entry.name)) continue
      const tok = (await $.fs.read(`${cacheDir}/${entry.name}`)).trim().split(/\s+/)
      if (tok[0] !== 'v1') continue
      five = best(five, of(tok[1], tok[2]))
      seven = best(seven, of(tok[3], tok[4]))
    }
  } catch {
    // The shared readings are a bonus; this session's own still shows.
  }

  const next: LineInfo = {
    project: leafName(git.root || cwd),
    branch: git.branch,
    model: await $.session.model(),
    context: usage.context.percent === undefined ? null : Math.round(usage.context.percent),
    fiveHour: five,
    sevenDay: seven,
  }
  await update($, info, old => (JSON.stringify(old) === JSON.stringify(next) ? old : next))
}

function remaining(sec: number): string {
  if (sec >= 3600) return `${Math.floor(sec / 3600)}h${String(Math.floor((sec % 3600) / 60)).padStart(2, '0')}m`
  if (sec >= 60) return `${Math.floor(sec / 60)}m`
  return '<1m'
}

// The colours the status line scripts use: the 16-colour ones by name, so
// they follow the terminal's palette, the 256-colour ones (46, 214, 203) as hex.
const C = {
  dim: 'blackBright',
  dir: 'whiteBright',
  gitMain: 'magentaBright',
  gitOther: 'cyanBright',
  model: 'yellowBright',
  ok: '#00ff00',
  warn: '#ffaf00',
  crit: '#ff5f5f',
}

type Piece = { text: string; color?: string }

function meter(pct: number | null, resets: number, nowSec: number): Piece[] {
  if (pct === null) return [{ text: `[${'◻'.repeat(BAR_LENGTH)}] --%`, color: C.dim }]
  const n = Math.max(0, Math.min(100, pct))
  const filled = Math.max(0, Math.min(BAR_LENGTH, Math.floor((n + 5) / 10)))
  const c = n >= CRIT_AT ? C.crit : n >= WARN_AT ? C.warn : C.ok
  const bar = { text: `[${'◼'.repeat(filled)}${'◻'.repeat(BAR_LENGTH - filled)}] `, color: c }
  if (resets > 0 && resets < nowSec) return [bar, { text: `~${n}%`, color: C.dim }]
  const out: Piece[] = [bar, { text: `${n}%`, color: c }]
  if (resets > 0) out.push({ text: ` ${remaining(resets - nowSec)}`, color: C.dim })
  return out
}

export function infoPieces(i: LineInfo, nowSec: number, showsWeek: boolean): Piece[] {
  const sep: Piece = { text: ' | ', color: C.dim }
  const branch = i.branch || '-'
  const branchColor = i.branch === '' ? C.dim : branch === 'main' || branch === 'master' ? C.gitMain : C.gitOther
  const out: Piece[] = [
    { text: 'DIR ', color: C.dim },
    { text: i.project || '-', color: C.dir },
    sep,
    { text: 'GIT ', color: C.dim },
    { text: branch, color: branchColor },
    sep,
    { text: 'MODEL ', color: C.dim },
    { text: i.model || '-', color: C.model },
    sep,
    { text: 'CTX ', color: C.dim },
    ...meter(i.context, 0, nowSec),
    sep,
    { text: '5H ', color: C.dim },
    ...meter(i.fiveHour?.used ?? null, i.fiveHour?.resets ?? 0, nowSec),
  ]
  if (showsWeek) {
    out.push(sep, { text: '7D ', color: C.dim }, ...meter(i.sevenDay?.used ?? null, i.sevenDay?.resets ?? 0, nowSec))
  }
  return out
}

// ---- hooks -----------------------------------------------------------------

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'statusline-place',
      description: '마스코트 위치 바꾸기: right(아래 오른쪽) · left(아래 왼쪽) · above(위) · line(상태줄 끝)',
      argumentHint: '[right|left|above|line]',
      immediate: true,
    })
    await $.command.register({
      name: 'statusline-mode',
      description: '정보 줄을 누가 그릴지: script(상태줄 스크립트, 기본) · app(플러그인이 그리고 스크립트는 멈춤)',
      argumentHint: '[script|app] [above|below]',
      immediate: true,
    })
    const savedPlace = await $.store.get('place')
    const where = typeof savedPlace === 'string' && isPlace(savedPlace) ? savedPlace : DEFAULT_PLACE
    // App mode holds only while the status line command is really switched
    // off; a reinstall puts the script back, and then the script draws.
    const savedMode = await $.store.get('mode')
    const json = await readSettingsFile($)
    const how: LineMode = savedMode === 'app' && json?.statusLine?.command === APP_COMMAND ? 'app' : 'script'
    const savedLine = await $.store.get('linePlace')
    const lineAt = typeof savedLine === 'string' && isLinePlace(savedLine) ? savedLine : 'above'
    await update($, place, () => where)
    await update($, mode, () => how)
    await update($, linePlace, () => lineAt)
    await applyPlace($, where, how)
    rollSeenAt = -1
    await refreshRoll($)
    $.clock.every(ROLL_POLL_MS, () => {
      refreshRoll($).catch(() => undefined)
    })
    await refreshInfo($).catch(() => undefined)
    $.clock.every(INFO_POLL_MS, () => {
      refreshInfo($).catch(() => undefined)
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
    await applyPlace($, arg, await read($, mode))
    return { text: `마스코트 위치: ${PLACES[arg]}` }
  })

  on('command.run', { command: 'statusline-mode' }, async ($, e) => {
    const [arg = '', at = ''] = e.args.trim().toLowerCase().split(/\s+/)
    const usage = '바꾸려면 /statusline-mode script · app · app above · app below'
    if (arg === '') {
      const now = await read($, mode)
      const where = now === 'app' ? `\n정보 줄 위치: ${LINE_PLACES[await read($, linePlace)]}` : ''
      return { text: `지금 방식: ${MODES[now]}${where}\n${usage}` }
    }
    if (!isMode(arg) || (at !== '' && (arg !== 'app' || !isLinePlace(at)))) {
      return { text: `그런 방식은 없습니다: ${e.args.trim()}\n${usage}` }
    }
    const failed = await switchMode($, arg)
    if (failed !== null) return { text: failed }
    await update($, mode, () => arg)
    await $.store.set('mode', arg)
    if (isLinePlace(at)) {
      await update($, linePlace, () => at)
      await $.store.set('linePlace', at)
    }
    await applyPlace($, await read($, place), arg)
    await refreshInfo($).catch(() => undefined)
    const where = arg === 'app' ? ` · 위치: ${LINE_PLACES[await read($, linePlace)]}` : ''
    return { text: `정보 줄: ${MODES[arg]}${where}` }
  })

  // The turn's states, from the same events the status line's hooks use. A
  // failure here never holds the event up: the catch lets it go on.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    await setTurn($, 'working')
    await update($, activity, () => null)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('classic.Stop', async ($, e, next) => {
    const stamp = await setTurn($, 'done')
    $.clock.after(TALK_WINDOW_MS, () => {
      update($, turn, t => (t.state === 'done' && t.stamp === stamp ? { state: 'idle', stamp } : t)).catch(
        () => undefined,
      )
    })
    refreshInfo($).catch(() => undefined)
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

  // What the turn is doing, for the tiers that talk about it. Only a change
  // of kind is recorded, so a run of reads is said once.
  on('tool.call', async ($, e, next) => {
    const kind = TOOL_KINDS[String(e.tool)]
    if (kind !== undefined) {
      const since = await $.clock.now()
      await update($, activity, a => (a?.kind === kind ? a : { kind, since }))
    }
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

  // Under the prompt, beside the mode label: the info line in app mode when
  // placed below, and the mascot when placed left.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const how = await read($, mode)
    const where = await read($, place)
    const isBelow = how === 'app' && (await read($, linePlace)) === 'below'
    const line = isBelow ? await read($, info) : null
    const hint = e.props.hint.trim()
    // In app mode a mascot placed at the end of the status line follows the
    // info line, since that line is the plugin's now.
    const wantsFace = where === 'left' || (isBelow && where === 'line')
    // Whatever the engine has to say here (a second Ctrl-C, a hint) wins
    // over a lone face; next to the info line it is kept, dim, at the end.
    if (line === null && (!wantsFace || hint !== '')) return next(e)
    const face = wantsFace ? await faceProps($) : null
    if (line === null && face === null) return next(e)
    const { Box, Text, Client } = $.ui.resolve(e)
    const s = await loadSettings($)
    const nowSec = Math.floor((await $.clock.now()) / 1000)
    return (
      <Box flexDirection="row">
        {line !== null && infoText(Text, line, nowSec, s, hint)}
        {line !== null && face !== null && <Text> </Text>}
        {face !== null && <Client key="mascot" module="./mascot-face.tsx" props={face} />}
      </Box>
    )
  })

  // The band right above the prompt: the info line in app mode (a row of its
  // own, so it never wraps) and the mascot when it is placed there.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.hasSurvey) return next(e)
    const how = await read($, mode)
    const where = await read($, place)
    const isAbove = how === 'app' && (await read($, linePlace)) === 'above'
    const line = isAbove ? await read($, info) : null
    const wantsFace = where === 'above' || (isAbove && where === 'line')
    const face = wantsFace ? await faceProps($) : null
    if (line === null && face === null) return next(e)
    const { Box, Text, Client } = $.ui.resolve(e)
    const s = await loadSettings($)
    const nowSec = Math.floor((await $.clock.now()) / 1000)
    return (
      <Box flexDirection="row">
        {line !== null && infoText(Text, line, nowSec, s, '')}
        {line !== null && face !== null && <Text> </Text>}
        {face !== null && <Client key="mascot" module="./mascot-face.tsx" props={face} />}
      </Box>
    )
  })
}

// The info line as one Text, so it is cut at the row's end and never wraps.
function infoText(
  Text: (props: { color?: string; dimColor?: boolean; wrap?: 'truncate-end'; children?: unknown }) => unknown,
  line: LineInfo,
  nowSec: number,
  s: Settings,
  hint: string,
) {
  return (
    <Text wrap="truncate-end">
      {infoPieces(line, nowSec, s.showsWeek).map(p => (
        <Text color={s.isColored ? p.color : undefined}>{p.text}</Text>
      ))}
      {hint !== '' && <Text dimColor> · {hint}</Text>}
    </Text>
  )
}
