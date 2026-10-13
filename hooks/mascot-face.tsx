import type { ClientModule } from 'claude-code'

// How the text is coloured: legend shimmers through its shades, unique wears
// a fixed gradient, the rest one colour, and nothing at all under NO_COLOR.
export type FacePaint = 'shimmer' | 'gradient' | 'flat' | 'plain'

export type FaceProps = {
  frames: string[]
  talk: string
  paint: FacePaint
  colors: string[]
  bold: boolean
  // Whether the expression changes (while a turn runs, or on an error).
  animate: boolean
}

type FaceState = { tick: number }

// Every 100 ms a shimmering face moves its shades one character on, the way
// the effort picker walks "max" through its rainbow.
const STEP_MS = 100
// The expression changes every 2 s, as it did in the status line.
const FRAME_TICKS = 20

// The tick a drawing needs: every one for a shimmer, every frame change for
// an animated face, none for a still one.
function shownTick(props: FaceProps, tick: number): number {
  if (props.paint === 'shimmer') return tick
  if (props.animate) return tick - (tick % FRAME_TICKS)
  return 0
}

// The newest props of each running instance, so its timer reads what the
// last redraw handed in.
const live = new WeakMap<object, FaceProps>()

const MascotFace: ClientModule<FaceProps, FaceState> = (props, surface) => {
  live.set(surface, props)
  if (surface.state === undefined) {
    let tick = 0
    let shown = 0
    surface.every(STEP_MS, () => {
      tick += 1
      const next = shownTick(live.get(surface) ?? props, tick)
      if (next !== shown) {
        shown = next
        surface.setState({ tick: next })
      }
    })
    surface.setState({ tick: 0 })
  }

  const tick = surface.state?.tick ?? 0
  const { Box, Text } = surface.elements
  const frames = props.frames.length > 0 ? props.frames : ['']
  const frame = props.animate ? Math.floor(tick / FRAME_TICKS) % frames.length : 0
  const face = frames[frame] ?? ''
  const text = props.talk === '' ? face : `${face} ${props.talk}`

  if (props.paint === 'plain') return <Text>{text}</Text>
  if (props.paint === 'flat') {
    return (
      <Text color={props.colors[0]} bold={props.bold}>
        {text}
      </Text>
    )
  }

  const n = props.colors.length
  const chars = Array.from(text)
  const faceLen = Array.from(face).length
  // A gradient is stretched over the face and over the line on their own.
  const stretched = (i: number): string | undefined => {
    const start = i < faceLen ? 0 : faceLen + 1
    const len = i < faceLen ? faceLen : chars.length - faceLen - 1
    const at = len > 1 ? Math.floor(((i - start) * (n - 1)) / (len - 1)) : 0
    return props.colors[at]
  }

  return (
    <Box flexDirection="row">
      {chars.map((ch, i) => (
        <Text color={props.paint === 'shimmer' ? props.colors[(i + tick) % n] : stretched(i)}>{ch}</Text>
      ))}
    </Box>
  )
}

export default MascotFace
