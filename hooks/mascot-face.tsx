import type { ClientModule } from 'claude-code'

// How the text is coloured: a legend plays its own effect, every other tier
// wears one colour, and nothing at all under NO_COLOR.
export type FacePaint = 'effect' | 'flat' | 'plain'

// A legend's look (from LEGEND_FX in mascot-data.ts). Restated here because a
// Client module stands alone.
export type FaceFx = {
  effect: 'azure' | 'bat' | 'volt' | 'blaze' | 'aurora'
  theme: string
  sides: string
  ramp: string[]
  deco?: string[]
}

// What the mascot says. `lines` take turns every ten seconds while `rotate`
// is set; a line with an answer shows its question first and the answer a
// few seconds later. `lead` (what the turn is doing) is said first for a
// while whenever `leadKey` changes.
export type TalkPlan = {
  lead: string
  leadKey: string
  lines: { q: string; a: string }[]
  start: number
  rotate: boolean
}

export type FaceProps = {
  frames: string[]
  talk: TalkPlan
  paint: FacePaint
  // The face's colour for 'flat'; the spoken line always wears colors[0].
  colors: string[]
  fx?: FaceFx
  bold: boolean
  // Whether the expression changes (while a turn runs, or on an error).
  animate: boolean
}

type FaceState = { tick: number }

// A legend's effect is drawn every 100 ms.
const STEP_MS = 100
// The expression changes every 2 s, as it did in the status line.
const FRAME_TICKS = 20
// A spoken line stays 10 s; a riddle's answer comes after 5 s of it.
const LINE_TICKS = 100
const ANSWER_TICKS = 50
// What the turn is doing is said for 6 s each time it changes.
const LEAD_TICKS = 60

// The tick a drawing needs: every one for an effect, once a second for an
// animated face or a talking one, none for a still one.
function shownTick(props: FaceProps, tick: number): number {
  if (props.paint === 'effect') return tick
  if (props.animate || props.talk.rotate || props.talk.lead !== '') return tick - (tick % 10)
  return 0
}

type Live = { props: FaceProps; leadKey: string; leadAt: number }
// The newest props of each running instance, so its timer reads what the
// last redraw handed in, and when its current lead started.
const live = new WeakMap<object, Live>()

function spoken(talk: TalkPlan, tick: number, leadAt: number): string {
  if (talk.lead !== '' && tick - leadAt < LEAD_TICKS) return talk.lead
  const n = talk.lines.length
  if (n === 0) return ''
  const slot = talk.rotate ? Math.floor(tick / LINE_TICKS) : 0
  const line = talk.lines[(talk.start + slot) % n]
  if (line === undefined) return ''
  if (line.a === '') return line.q
  return talk.rotate && tick % LINE_TICKS < ANSWER_TICKS ? line.q : `${line.q} ${line.a}`
}

// ---- legend effects ----------------------------------------------------------
// Each legend has its own effect, worked out per 100 ms tick from the cells of
// the face (deco = an outside decoration at the first or last character).

type Cell = { ch: string; deco: boolean }
const TAU = Math.PI * 2

function rgb(hex: string): number[] {
  return [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16))
}
function mix(a: string, b: string, t: number): string {
  const x = rgb(a)
  const y = rgb(b)
  return `#${x.map((v, i) => Math.round(v + ((y[i] ?? v) - v) * t).toString(16).padStart(2, '0')).join('')}`
}
// Towards white for k > 0, towards black for k < 0.
const lit = (c: string, k: number) => (k >= 0 ? mix(c, '#ffffff', k) : mix(c, '#000000', -k))
const ease = (u: number) => u * u * (3 - 2 * u)
function hsl(h: number, s: number, l: number): string {
  h = ((h % 360) + 360) % 360
  const c = (1 - Math.abs(2 * l - 1)) * s
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = l - c / 2
  const parts = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]][Math.floor(h / 60) % 6] ?? [0, 0, 0]
  return `#${parts.map(v => Math.round((v + m) * 255).toString(16).padStart(2, '0')).join('')}`
}
// A loop through the ramp's colours at u (any real number).
function rampAt(stops: string[], u: number): string {
  const n = stops.length
  if (n === 0) return '#ffffff'
  u = ((u % 1) + 1) % 1
  const x = u * n
  const i = Math.floor(x)
  return mix(stops[i % n] ?? '#ffffff', stops[(i + 1) % n] ?? '#ffffff', x - i)
}
function hash(n: number): number {
  n = (n ^ 61) ^ (n >>> 16)
  n = Math.imul(n, 9)
  n ^= n >>> 4
  n = Math.imul(n, 0x27d4eb2d)
  return (n ^ (n >>> 15)) >>> 0
}

// Thunder: each strike window (2.4-4 s, varying) gets one strike at a varying
// moment - flash, a dark dip, a second flash, then a fade back to rest.
const STRIKE = [0.95, -0.55, 1, 0.6, 0.38, 0.2, 0.08]
function thunder(tick: number): number {
  let start = 0
  for (let c = 0; ; c++) {
    const len = 24 + (hash(c) % 16)
    if (tick < start + len) {
      const r = tick - start - (4 + (hash(c * 7 + 3) % (len - 12)))
      return r >= 0 && r < STRIKE.length ? (STRIKE[r] ?? 0) : 0
    }
    start += len
  }
}

// The bat's night: the body barely shows until lightning lights it.
const NIGHT = '#2a2140'
const DARK = '#241c30'
// Fire from embers to white-hot, read from 0 to 1 (not a loop).
const FIRE = ['#4a0500', '#8e0d05', '#c81e0e', '#f2401a', '#ff7a1f', '#ffb43a', '#ffe27a']
function rampEdge(stops: string[], u: number): string {
  const x = Math.max(0, Math.min(1, u)) * (stops.length - 1)
  const i = Math.floor(x)
  return mix(stops[i] ?? '#ffffff', stops[Math.min(i + 1, stops.length - 1)] ?? '#ffffff', x - i)
}
// Smooth value noise, for flames.
function noise(x: number): number {
  const i = Math.floor(x)
  const a = (hash(i) % 1000) / 1000
  const b = (hash(i + 1) % 1000) / 1000
  return a + (b - a) * ease(x - i)
}

// ---- moving letters ----------------------------------------------------------
// Besides colour, a legend's letters move: the bat's wings flap fast, the
// fox's bolts turn bold while they strike, and paws (ฅ) lift now and then.
// Every swap keeps the width, so the line never shifts.

const WINGS: Record<string, string> = { '⎛': '⎝', '⎝': '⎛', '⎠': '⎞', '⎞': '⎠' }

// Up and down every 200 ms for 3 s, then a 1 s glide.
function wingsUp(t: number): boolean {
  return t % 40 < 30 && Math.floor(t / 2) % 2 === 1
}

// Each 2.4-4 s window one paw, the other or both go up for 0.6 s (or none).
function liftedPaws(cells: Cell[], t: number): Set<number> {
  const paws = cells.flatMap((c, i) => (c.ch === 'ฅ' ? [i] : []))
  if (paws.length === 0) return new Set()
  let start = 0
  for (let w = 0; ; w++) {
    const len = 24 + (hash(w * 31) % 16)
    if (t < start + len) {
      const r = t - start
      const at = 3 + (hash(w * 17 + 5) % (len - 12))
      const pick = hash(w * 7 + 9) % 5
      if (r < at || r >= at + 6 || pick === 0) return new Set()
      if (pick <= 2 || paws.length === 1) return new Set([paws[pick === 1 ? 0 : paws.length - 1] ?? -1])
      return new Set(paws)
    }
    start += len
  }
}

function moveLetters(fx: FaceFx, cells: Cell[], t: number): Cell[] {
  const lifted = liftedPaws(cells, t)
  const flap = fx.effect === 'bat' && wingsUp(t)
  let bolt = 0
  return cells.map((c, i) => {
    if (lifted.has(i)) return { ...c, ch: ' ' }
    if (flap && WINGS[c.ch] !== undefined) return { ...c, ch: WINGS[c.ch] ?? c.ch }
    if (fx.effect === 'volt' && c.deco && c.ch === 'ϟ') {
      const st = bolt++ === 0 ? thunder(t) : thunder(Math.max(0, t - 1))
      if (st > 0.3) return { ...c, ch: 'Ϟ' }
    }
    return c
  })
}

const EFFECTS: Record<FaceFx['effect'], (fx: FaceFx, cells: Cell[], t: number) => string[]> = {
  // Water ripples run through the blue body; every 3 s a rainbow breath bursts
  // from ≋ and sweeps right to left, leaving a fading rainbow trail.
  azure(fx, cells, t) {
    const n = cells.length
    const ph = t % 30
    const front = ph < 12 ? n - 1 - ease(ph / 12) * (n + 5) : -99
    return cells.map((c, i) => {
      if (c.deco) return hsl(t * 14, 1, ph < 12 ? 0.78 : 0.62)
      let col = lit(rampAt(fx.ramp, i / n - t * 0.02), 0.28 * Math.max(0, Math.sin(TAU * (i / 5 - t * 0.09))))
      const d = i - front
      if (d >= 0 && d < 6) col = mix(col, hsl(i * 40 - t * 10, 1, 0.66), 0.95 * (1 - d / 6))
      return col
    })
  },
  // Night: the body sits in the dark with only its red eyes lit, until
  // thunder strikes - each flash lights the whole bat and its swarm.
  bat(fx, cells, t) {
    const n = cells.length
    const st = thunder(t)
    return cells.map((c, i) => {
      if (c.deco) return st > 0 ? mix(DARK, '#efe4ff', st) : DARK
      if (c.ch === '•') return st > 0 ? mix('#ff2040', '#ffd0d8', st * 0.5) : '#ff2040'
      const body = lit(rampAt(fx.ramp, 0.2 + (0.4 * i) / n), 0.25)
      return st > 0 ? mix(NIGHT, body, st) : st < 0 ? '#1c1628' : NIGHT
    })
  },
  // Only the bolts are yellow; they rest dim and strike bright, the right one
  // a beat after the left. The body flashes white with each strike.
  volt(fx, cells, t) {
    const n = cells.length
    const s0 = thunder(t)
    const s1 = thunder(Math.max(0, t - 1))
    const bolts = fx.deco ?? ['#ffe600', '#ffc400']
    let slot = 0
    return cells.map((c, i) => {
      if (c.deco) {
        const k = slot++
        const s = k === 0 ? s0 : s1
        const bolt = bolts[k % bolts.length] ?? '#ffe600'
        return s === 0 ? lit(bolt, -0.3) : lit(bolt, s)
      }
      const col = rampAt(fx.ramp, i / n - t * 0.015)
      return s0 > 0 ? lit(col, s0 * 0.7) : s0 < 0 ? lit(col, -0.35) : col
    })
  },
  // Fire: every letter burns on its own flickering flame, mostly deep red
  // with orange and yellow licks; a flare rolls through the body every few
  // seconds; the hot springs dance orange to white-gold.
  blaze(_fx, cells, t) {
    const n = cells.length
    const flare = t % 36
    const at = flare < 14 ? ease(flare / 14) * (n + 4) - 2 : -99
    let slot = 0
    return cells.map((c, i) => {
      if (c.deco) {
        const h = noise(t * 0.45 + slot++ * 17.3)
        return h > 0.72 ? mix('#ffd84a', '#fff4c8', (h - 0.72) / 0.28) : mix('#ff5a14', '#ffb020', h / 0.72)
      }
      const d = Math.abs(i - at)
      const h = 0.15 + 0.55 * noise(t * 0.32 + i * 3.7) + 0.3 * noise(t * 0.9 + i * 11.1) + (d < 3 ? 0.45 * (1 - d / 3) : 0)
      return rampEdge(FIRE, Math.min(1, h) * 0.82)
    })
  },
  // Aurora: violet, teal and pink waves weave through each other; the
  // sparkles pulse.
  aurora(_fx, cells, t) {
    const n = cells.length
    return cells.map((c, i) => {
      if (c.deco) return lit('#b07cff', 0.6 * (0.5 + 0.5 * Math.sin((TAU * t) / 12)))
      const w = 0.5 + 0.5 * Math.sin(TAU * (i / n - t * 0.03)) * Math.sin(TAU * (i / (n * 0.7) + t * 0.02))
      return mix('#7b4dff', w > 0.5 ? '#3fe0d0' : '#ff6ad5', Math.abs(w - 0.5) * 2)
    })
  },
}

function cellsOf(face: string, sides: string): Cell[] {
  const chars = Array.from(face)
  const last = chars.length - 1
  return chars.map((ch, i) => ({ ch, deco: (i === 0 && sides.includes('L')) || (i === last && sides.includes('R')) }))
}

const MascotFace: ClientModule<FaceProps, FaceState> = (props, surface) => {
  const tick = surface.state?.tick ?? 0
  const seen = live.get(surface)
  const leadAt = seen === undefined || seen.leadKey !== props.talk.leadKey ? tick : seen.leadAt
  live.set(surface, { props, leadKey: props.talk.leadKey, leadAt })

  if (surface.state === undefined) {
    let ticks = 0
    let shown = 0
    surface.every(STEP_MS, () => {
      ticks += 1
      const next = shownTick(live.get(surface)?.props ?? props, ticks)
      if (next !== shown) {
        shown = next
        surface.setState({ tick: next })
      }
    })
    surface.setState({ tick: 0 })
  }

  const { Box, Text } = surface.elements
  const frames = props.frames.length > 0 ? props.frames : ['']
  const frame = props.animate ? Math.floor(tick / FRAME_TICKS) % frames.length : 0
  const face = frames[frame] ?? ''
  const said = spoken(props.talk, tick, leadAt)

  if (props.paint === 'plain') return <Text>{said === '' ? face : `${face} ${said}`}</Text>
  if (props.paint === 'flat' || props.fx === undefined) {
    return (
      <Text color={props.colors[0]} bold={props.bold}>
        {said === '' ? face : `${face} ${said}`}
      </Text>
    )
  }

  // A legend: each letter of the face in its effect's colour, then the line
  // one space to the right in the legend's own steady colour.
  const cells = cellsOf(face, props.fx.sides)
  const colors = EFFECTS[props.fx.effect](props.fx, cells, tick)
  const letters = moveLetters(props.fx, cells, tick)
  return (
    <Box flexDirection="row">
      {letters.map((c, i) => (
        <Text color={colors[i]} bold={props.bold}>
          {c.ch}
        </Text>
      ))}
      {said !== '' && <Text color={props.colors[0]}>{` ${said}`}</Text>}
    </Box>
  )
}

export default MascotFace
