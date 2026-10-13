// What the in-app mascot keeps for the session.

// Where the face is drawn: under the prompt on the right or the left, in the
// band above the prompt, or left to the status line as before.
export type MascotPlace = 'right' | 'left' | 'above' | 'line'

// What the turn is doing, as the hooks used to record it, and when (epoch s).
export type MascotTurn = {
  state: 'idle' | 'working' | 'done' | 'notify' | 'error'
  stamp: number
}

// The roll on file, once its signature checked out.
export type MascotRoll = {
  tier: 'common' | 'uncommon' | 'rare' | 'unique' | 'legend' | 'dev'
  index: number
}

declare module 'claude-code' {
  interface PluginState {
    statusline: {
      place: MascotPlace
      turn: MascotTurn
      roll: MascotRoll | null
    }
  }
}
