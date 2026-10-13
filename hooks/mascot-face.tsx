import type { ClientModule } from 'claude-code'

// How the text is coloured: legend walks through its hues, unique wears a
// fixed gradient, the rest one colour, and nothing at all under NO_COLOR.
export type FacePaint = 'shimmer' | 'gradient' | 'flat' | 'plain'

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
  colors: string[]
  // A shimmer's other rainbows: it wears one, then moves to another at random.
  themes?: string[][]
  bold: boolean
  // Whether the expression changes (while a turn runs, or on an error).
  animate: boolean
}

type FaceState = { tick: number }

// Every 100 ms a shimmering face moves its hues one character on, the way
// the effort picker walks "max" through its rainbow.
const STEP_MS = 100
// The expression changes every 2 s, as it did in the status line.
const FRAME_TICKS = 20
// A spoken line stays 10 s; a riddle's answer comes after 5 s of it.
const LINE_TICKS = 100
const ANSWER_TICKS = 50
// What the turn is doing is said for 6 s each time it changes.
const LEAD_TICKS = 60
// A legend keeps one of its theme rainbows for 15 s, then takes another.
const THEME_TICKS = 150

// The tick a drawing needs: every one for a shimmer, once a second for an
// animated face or a talking one, none for a still one.
function shownTick(props: FaceProps, tick: number): number {
  if (props.paint === 'shimmer') return tick
  if (props.animate || props.talk.rotate || props.talk.lead !== '') return tick - (tick % 10)
  return 0
}

type Live = { props: FaceProps; leadKey: string; leadAt: number; seed: number; slot: number; theme: number }
// The newest props of each running instance, so its timer reads what the
// last redraw handed in, and when its current lead started.
const live = new WeakMap<object, Live>()

// A small hash of a slot and the instance's own seed.
function hashOf(slot: number, seed: number): number {
  let x = Math.imul(slot ^ seed, 2654435761) >>> 0
  x = Math.imul(x ^ (x >>> 15), 2246822519) >>> 0
  return (x ^ (x >>> 13)) >>> 0
}

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

const MascotFace: ClientModule<FaceProps, FaceState> = (props, surface) => {
  const tick = surface.state?.tick ?? 0
  const seen = live.get(surface)
  const leadAt = seen === undefined || seen.leadKey !== props.talk.leadKey ? tick : seen.leadAt
  const seed = seen?.seed ?? Math.floor(Math.random() * 0x7fffffff)
  // Each 15 s slot moves to another theme at random, never the one just worn.
  const themes = props.themes ?? []
  const n = themes.length
  const slot = Math.floor(tick / THEME_TICKS)
  let theme = seen?.theme ?? (n > 0 ? hashOf(0, seed) % n : 0)
  if (seen !== undefined && slot !== seen.slot && n > 1) theme = (theme + 1 + (hashOf(slot, seed) % (n - 1))) % n
  live.set(surface, { props, leadKey: props.talk.leadKey, leadAt, seed, slot, theme })

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
  const text = said === '' ? face : `${face} ${said}`

  if (props.paint === 'plain') return <Text>{text}</Text>
  if (props.paint === 'flat') {
    return (
      <Text color={props.colors[0]} bold={props.bold}>
        {text}
      </Text>
    )
  }

  const colors = n > 1 ? (themes[theme] ?? props.colors) : props.colors
  const width = colors.length
  const chars = Array.from(text)
  const faceLen = Array.from(face).length
  // A gradient is stretched over the face and over the line on their own.
  const stretched = (i: number): string | undefined => {
    const start = i < faceLen ? 0 : faceLen + 1
    const len = i < faceLen ? faceLen : chars.length - faceLen - 1
    const at = len > 1 ? Math.floor(((i - start) * (width - 1)) / (len - 1)) : 0
    return colors[at]
  }

  return (
    <Box flexDirection="row">
      {chars.map((ch, i) => (
        <Text color={props.paint === 'shimmer' ? colors[(i + tick) % width] : stretched(i)} bold={props.bold}>
          {ch}
        </Text>
      ))}
    </Box>
  )
}

export default MascotFace
