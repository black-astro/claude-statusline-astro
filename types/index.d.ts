// What the in-app mascot and info line keep for the session.

// Where the face is drawn: under the prompt on the right or the left, in the
// band above the prompt, or left to the status line as before.
export type MascotPlace = 'right' | 'left' | 'above' | 'line'

// Who draws the info line: the status line script (as always), or the plugin
// itself under the prompt, with the script switched off.
export type LineMode = 'script' | 'app'

// What the turn is doing, as the hooks used to record it, and when (epoch s).
export type MascotTurn = {
  state: 'idle' | 'working' | 'done' | 'notify' | 'error'
  stamp: number
}

// What the latest tool call was doing, and since when (epoch ms).
export type MascotActivity = {
  kind: 'read' | 'search' | 'edit' | 'run' | 'web' | 'agent'
  since: number
}

// The roll on file, once its signature checked out.
export type MascotRoll = {
  tier: 'common' | 'uncommon' | 'rare' | 'unique' | 'legend' | 'dev'
  index: number
}

// One rate-limit window: percent used, and when it resets (epoch s, 0 unknown).
export type LineWindow = { used: number; resets: number }

// What the info line shows, refreshed every couple of seconds.
export type LineInfo = {
  project: string
  branch: string
  model: string
  context: number | null
  fiveHour: LineWindow | null
  sevenDay: LineWindow | null
}

declare module 'claude-code' {
  interface PluginState {
    statusline: {
      place: MascotPlace
      mode: LineMode
      turn: MascotTurn
      activity: MascotActivity | null
      roll: MascotRoll | null
      info: LineInfo | null
    }
  }
}
