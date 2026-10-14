import type { ClientModule } from 'claude-code'

// How the text is coloured: a legend plays its own effect, every other tier
// wears one colour, and nothing at all under NO_COLOR.
export type FacePaint = 'effect' | 'flat' | 'plain'

// A legend's look (from LEGEND_FX in mascot-data.ts). Restated here because a
// Client module stands alone.
export type FaceFx = {
  effect: 'azure' | 'luna' | 'volt' | 'stella' | 'mystic'
  theme: string
  sides: string
  ramp: string[]
  bolts?: string[]
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
  // The ghost fades almost out and back in to bright silver; the moon glows
  // gold when the ghost is faint; the sparkle twinkles on its own beat.
  luna(fx, cells, t) {
    const n = cells.length
    const p = 0.5 + 0.5 * Math.sin((TAU * t) / 30)
    let slot = 0
    return cells.map((c, i) => {
      if (c.deco) {
        if (slot++ === 0) return mix('#c9a640', '#fff2b0', 1 - p)
        const tw = (t + 5) % 14
        return tw < 3 ? (['#ffffff', '#d8f4ff', '#a8d8ff'][tw] ?? '#ffffff') : mix('#5c6cb8', '#9fb4ff', p)
      }
      const col = rampAt(fx.ramp, (i / n) * 0.7 - t * 0.012)
      return p < 0.5 ? lit(col, -0.72 * (1 - p * 2)) : lit(col, 0.55 * (p * 2 - 1))
    })
  },
  // Only the bolts are yellow; they rest dim and strike bright, the right one
  // a beat after the left. The body flashes white with each strike.
  volt(fx, cells, t) {
    const n = cells.length
    const s0 = thunder(t)
    const s1 = thunder(Math.max(0, t - 1))
    const bolts = fx.bolts ?? ['#ffe600', '#ffc400']
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
  // Stardust: single letters of the pink body sparkle white, each on its own
  // timer; the two side stars twinkle through the rainbow in turn.
  stella(fx, cells, t) {
    const n = cells.length
    let slot = 0
    return cells.map((c, i) => {
      if (c.deco) {
        const k = slot++
        const tw = (t + k * 9) % 18
        const env = tw < 6 ? ([1, 0.75, 0.5, 0.3, 0.15, 0.05][tw] ?? 0) : 0
        return lit(hsl(t * 8 + k * 180, 1, 0.62), env * 0.8)
      }
      const period = 16 + (hash(i * 31) % 14)
      const tw = (t + (hash(i * 7 + 1) % period)) % period
      const env = tw < 5 ? ([1, 0.7, 0.4, 0.2, 0.08][tw] ?? 0) : 0
      return lit(rampAt(fx.ramp, i / n - t * 0.015), env * 0.9)
    })
  },
  // Aurora: the whole rainbow spread across the body, flowing; the crystal
  // pulses white.
  mystic(_fx, cells, t) {
    const n = cells.length
    return cells.map((c, i) =>
      c.deco ? lit('#b07cff', 0.75 * (0.5 + 0.5 * Math.sin((TAU * t) / 12))) : hsl((i / n) * 300 - t * 9, 0.95, 0.66),
    )
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
  return (
    <Box flexDirection="row">
      {cells.map((c, i) => (
        <Text color={colors[i]} bold={props.bold}>
          {c.ch}
        </Text>
      ))}
      {said !== '' && <Text color={props.colors[0]}>{` ${said}`}</Text>}
    </Box>
  )
}

export default MascotFace
