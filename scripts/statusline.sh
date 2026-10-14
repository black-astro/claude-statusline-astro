#!/bin/sh
# claude-statusline — POSIX sh implementation (macOS, Linux, WSL, Git Bash).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% 4h10m
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Nothing may reach stderr: Claude Code renders whatever the command emits.
exec 2>/dev/null

# ---- appearance ------------------------------------------------------------
BAR_LEN=10
# U+25FC/25FB draw a near-square block with the glyph's own margins, so flush
# cells still show a hairline gap, and the empty cell renders as an outlined
# box rather than a shaded fill.
BAR_FULL='◼'    # U+25FC  filled cell
BAR_EMPTY='◻'   # U+25FB  empty cell (outlined)
BAR_GAP=''      # cells are flush; the glyph provides its own separation
BAR_PAD=''      # spacing just inside the brackets
DIR_MAX=32      # project name is left-truncated past this many characters

STATUSLINE_VERSION='1.14.0'

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   --roll      roll today's mascot (once a day) and exit
#   --today     print the mascot you are currently wearing and exit
#   --version   print the version and exit
#   --help      print a short usage summary and exit
SUBCOMMAND=''
case "${1:-}" in
    --version|-v)
        printf 'claude-statusline-astro %s\n' "$STATUSLINE_VERSION"
        exit 0
        ;;
    --help|-h)
        printf 'claude-statusline-astro %s\n\n' "$STATUSLINE_VERSION"
        printf '  statusline.sh            Claude Code calls this with session JSON on stdin\n'
        printf '  statusline.sh --roll     오늘의 마스코트 뽑기 (하루 한 번)\n'
        printf '  statusline.sh --today    지금 쓰고 있는 마스코트 보기\n'
        printf '  statusline.sh --version  버전 보기\n'
        printf '  statusline.sh --help     이 도움말\n\n'
        printf '뽑기는 하루 한 번이고, 뽑기 전까지 지금 마스코트가 그대로 유지됩니다.\n'
        printf '
  statusline.sh --roll legend         등급 지정 (메인테이너 키 전용)
'
        printf '  statusline.sh --roll legend Volt    얼굴 지정 (메인테이너 키 전용)
'
        exit 0
        ;;
    --roll)
        SUBCOMMAND=roll
        ROLL_WANT="${2:-}"
        ROLL_FACE="${3:-}"
        ;;
    --today)
        SUBCOMMAND=today
        ;;
esac

SHOW_SEVEN_DAY=0  # set to 1 to also show the 7-day (weekly) meter
# The reasoning effort after the model, as one or two letters (L M H XH U).
SHOW_EFFORT=1

# Mascot: a kaomoji at the end of the line reflecting what the session is doing.
# It needs the companion hook (mascot-hook.sh) to know the state - without it the
# state file never appears and the mascot simply stays hidden.
SHOW_MASCOT=1
# The mascot speaks a line when a turn finishes; set 0 for the face alone.
SHOW_MASCOT_TALK=1
# Seconds per expression frame while a turn runs. Claude Code only redraws
# every refreshInterval (the installer sets 2), so keep the two equal.
ANIM_SECS=2
# Legend sparkle: the palette runs from its darkest colour at the edges of
# the face to its lightest in the middle, and on every redraw one character
# in SPARKLE_EVERY flashes the lightest colour (or the darkest where the text
# is already pale), picked by the clock so the twinkle wanders. 1 lights
# everything, 0 turns the twinkle off. The spoken line gets the same
# treatment on its own.
SPARKLE_EVERY=4
# 24-bit colour for the legend ramp. Set 0 on a terminal that only knows 256
# colours; the ramp then snaps to the nearest of those.
LEGEND_TRUE_COLOR=1
# How long after a turn ends the mascot keeps talking. Past this it goes quiet
# until the next turn, so an idle terminal is not left with a stale sentence.
TALK_WINDOW_SECS=60
# The switches above can also be flipped without editing this file, through
# environment variables (Claude Code passes its "env" settings through):
#   STATUSLINE_MASCOT=0      hide the mascot
#   STATUSLINE_TALK=0        face only, no lines
#   STATUSLINE_SEVEN_DAY=1   show the weekly meter
#   STATUSLINE_TRUE_COLOR=0  256-colour ramps
#   STATUSLINE_EFFORT=0      hide the effort
case "${STATUSLINE_MASCOT:-}" in 0) SHOW_MASCOT=0 ;; 1) SHOW_MASCOT=1 ;; esac
case "${STATUSLINE_TALK:-}" in 0) SHOW_MASCOT_TALK=0 ;; 1) SHOW_MASCOT_TALK=1 ;; esac
case "${STATUSLINE_SEVEN_DAY:-}" in 0) SHOW_SEVEN_DAY=0 ;; 1) SHOW_SEVEN_DAY=1 ;; esac
case "${STATUSLINE_TRUE_COLOR:-}" in 0) LEGEND_TRUE_COLOR=0 ;; 1) LEGEND_TRUE_COLOR=1 ;; esac
case "${STATUSLINE_EFFORT:-}" in 0) SHOW_EFFORT=0 ;; 1) SHOW_EFFORT=1 ;; esac
# The plugin draws the mascot under the prompt itself on a Claude Code that
# can, and says so here; the line then leaves its own face out.
case "${STATUSLINE_MASCOT_BY_MOD:-}" in 1) SHOW_MASCOT=0 ;; esac

# Rarity odds in per-mille, lowest rarity first, totalling 1000 and lined up with
# MASCOT_TIERS below. These are fixed on purpose: everyone rolls against the same
# table, and editing them turns the roll into a choice, which is no roll at all.
MASCOT_ODDS='250 300 250 150 50'
MASCOT_TIERS='common uncommon rare unique legend'

# Maintainer tier. A key whose SHA-256 is listed here also rolls 'dev' faces;
# every other key never sees them. Only the hash is published, so the list gives
# nothing away - matching it would mean finding a preimage of SHA-256. Add your
# own hash to claim the tier on your machine: SHA-256 of the key file's text,
# trimmed of whitespace, hashed as UTF-8. The README gives the exact command.
DEV_KEY_HASHES='64528c9f19e91ed0ca521f443a672235456aa3cdf23f45787f07482759777238'
# Per-mille odds of the dev tier; the ordinary tiers share what is left, keeping
# their ratio to each other.
DEV_ODDS=100

# Meters turn amber at WARN_AT and red at CRIT_AT.
WARN_AT=60
CRIT_AT=90

# Rate-limit snapshots are shared between sessions through this directory so
# every terminal shows the freshest value any of them has seen.
CACHE_DIR="${STATUSLINE_CACHE_DIR:-$HOME/.claude/statusline-cache}"

if [ -n "${NO_COLOR:-}" ]; then
    RESET=''
    DIM=''
    C_DIR=''
    C_GIT_MAIN=''
    C_GIT_OTHER=''
    C_MODEL=''
    C_EFF_L=''; C_EFF_M=''; C_EFF_H=''; C_EFF_XH=''; C_EFF_U=''
    C_OK=''
    C_WARN=''
    C_CRIT=''
    C_COMMON=''
    C_UNCOMMON=''
    C_RARE=''
    C_UNIQUE=''
    C_LEGEND=''
    C_DEV=''
else
    ESC=$(printf '\033')
    RESET="${ESC}[0m"
    DIM="${ESC}[90m"
    C_DIR="${ESC}[97m"              # bright white — project name
    C_GIT_MAIN="${ESC}[95m"         # magenta — main / master
    C_GIT_OTHER="${ESC}[96m"        # sky blue — every other branch
    C_MODEL="${ESC}[93m"            # yellow — model name
    # Effort, low -> max: grey, green, sky blue, magenta, bold yellow.
    C_EFF_L="${ESC}[37m"
    C_EFF_M="${ESC}[92m"
    C_EFF_H="${ESC}[96m"
    C_EFF_XH="${ESC}[95m"
    C_EFF_U="${ESC}[1;93m"
    # 256-color meter palette. For 16-color-only terminals use
    # 96 / 93 / 91 in place of these three.
    C_OK="${ESC}[38;5;46m"          # neon green  — under WARN_AT
    C_WARN="${ESC}[38;5;214m"       # amber       — WARN_AT and up
    C_CRIT="${ESC}[38;5;203m"       # red         — CRIT_AT and up
    # Mascot rarity palette, common -> legend.
    C_COMMON="${ESC}[38;5;253m"     # the faintest grey
    C_UNCOMMON="${ESC}[38;5;120m"   # light green
    C_RARE="${ESC}[38;5;117m"       # sky blue
    C_UNIQUE="${ESC}[38;5;141m"     # purple
    C_LEGEND="${ESC}[1;38;5;208m"   # orange, bold
    C_DEV="${ESC}[1;38;5;51m"       # cyan, bold - maintainer only
fi

payload=''
[ -n "$SUBCOMMAND" ] || payload=$(cat | tr -d '\n\r')

# ---- payload fields --------------------------------------------------------
# jq handles the payload properly when present; the sed fallback covers the
# handful of flat fields this status line needs on machines without it.
get_str() {
    printf '%s' "$payload" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

# The block may hold one level of nested objects (context_window carries a
# current_usage object); those are blanked before the field is looked up.
get_nested_num() {
    printf '%s' "$payload" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{\(\([^{}]*{[^{}]*}\)*[^{}]*\)}.*/\1/p" |
        sed 's/{[^{}]*}//g' |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p"
}

if command -v jq >/dev/null 2>&1; then
    dir=$(printf '%s' "$payload" | jq -r '(.workspace.current_dir // .cwd // "")')
    model=$(printf '%s' "$payload" | jq -r '(.model.display_name // "")')
    effort=$(printf '%s' "$payload" | jq -r '(.effort.level // "")')
    sid=$(printf '%s' "$payload" | jq -r '(.session_id // "")')
    ctx=$(printf '%s' "$payload" | jq -r '(.context_window.used_percentage // "")')
    five=$(printf '%s' "$payload" | jq -r '(.rate_limits.five_hour.used_percentage // "")')
    five_reset=$(printf '%s' "$payload" | jq -r '(.rate_limits.five_hour.resets_at // "")')
    seven=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.used_percentage // "")')
    seven_reset=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.resets_at // "")')
else
    dir=$(get_str current_dir)
    [ -z "$dir" ] && dir=$(get_str cwd)
    model=$(get_str display_name)
    effort=$(printf '%s' "$payload" |
        sed -n 's/.*"effort"[[:space:]]*:[[:space:]]*{[^{}]*"level"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    sid=$(get_str session_id)
    ctx=$(get_nested_num context_window used_percentage)
    five=$(get_nested_num five_hour used_percentage)
    five_reset=$(get_nested_num five_hour resets_at)
    seven=$(get_nested_num seven_day used_percentage)
    seven_reset=$(get_nested_num seven_day resets_at)
fi

[ -z "$model" ] && model='-'
# The model as family and version only: "Opus 5.5 (1M context)" and
# "claude-opus-5-5" both read opus5.5. A name with no family stays as it is.
model=$(printf '%s' "$model" | awk '{
    s = tolower($0)
    gsub(/\([^)]*\)|\[[^]]*\]/, "", s)
    gsub(/claude/, "", s)
    if (!match(s, /[a-z]+/)) { print $0; exit }
    fam = substr(s, RSTART, RLENGTH)
    rest = substr(s, RSTART + RLENGTH)
    v = ""; n = 0
    while (n < 2 && match(rest, /[0-9]+/)) {
        d = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (length(d) > 3) break
        v = v (n ? "." : "") d; n++
    }
    print fam v
}')

now=$(date +%s 2>/dev/null)
case "$now" in ''|*[!0-9]*) now=0 ;; esac

# ---- git -------------------------------------------------------------------
branch=''
root=''
if [ -n "$dir" ] && [ -d "$dir" ] && command -v git >/dev/null 2>&1; then
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)

    branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
        [ "$branch" = 'HEAD' ] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    fi
fi

if [ -n "$branch" ]; then
    case "$branch" in
        main|master) c_branch=$C_GIT_MAIN ;;
        *)           c_branch=$C_GIT_OTHER ;;
    esac
else
    branch='-'
    c_branch=$DIM
fi

# ---- project name ----------------------------------------------------------
# Only the project root is shown. The full path is noise once you know where
# you are, and the repository root is what actually identifies the session.
[ -z "$root" ] && root="$dir"

if [ -n "$root" ]; then
    project=$(printf '%s' "$root" | sed 's#[\\/]*$##; s#.*[\\/]##')
    [ -z "$project" ] && project="$root"
    project=$(awk -v s="$project" -v max="$DIR_MAX" 'BEGIN{
        n = length(s)
        if (n <= max) { printf "%s", s } else { printf "…%s", substr(s, n - max + 2) }
    }')
else
    project='-'
fi

# ---- cross-session rate-limit sync -----------------------------------------
# The payload's rate_limits are a per-session snapshot frozen at that session's
# last API response, so idle terminals drift apart and disagree with the web
# usage page. Every session therefore publishes the snapshot it was handed, and
# every session renders the best snapshot published by anyone: the newest
# window wins, and within the same window the highest reading wins, because
# account usage only rises while a window is open.
#
# Cache line format (one line per session): "v1 <5h%> <5h_reset> <7d%> <7d_reset>"

round_pct() {
    case "$1" in
        *[0-9]*) awk -v v="$1" 'BEGIN{ v = v + 0; if (v < 0) v = 0; if (v > 100) v = 100; printf "%d", int(v + 0.5) }' ;;
    esac
}

to_epoch() {
    _e=${1%%.*}
    case "$_e" in
        *[!0-9]*|'') printf '' ;;
        *) printf '%s' "$_e" ;;
    esac
}

five_i=$(round_pct "$five")
five_r=$(to_epoch "$five_reset")
seven_i=$(round_pct "$seven")
seven_r=$(to_epoch "$seven_reset")

mkdir -p "$CACHE_DIR" 2>/dev/null

sid_key=$(printf '%s' "$sid" | tr -cd 'a-zA-Z0-9' | cut -c1-8)
if [ -n "$five_i" ] && [ -n "$sid_key" ] && [ -d "$CACHE_DIR" ]; then
    _tmp="$CACHE_DIR/rl-$sid_key.tmp.$$"
    printf 'v1 %s %s %s %s\n' \
        "$five_i" "${five_r:--}" "${seven_i:--}" "${seven_r:--}" >"$_tmp" &&
        mv -f "$_tmp" "$CACHE_DIR/rl-$sid_key.txt"
    # Entries from long-dead sessions stop mattering once their window closes;
    # sweep anything untouched for two days to keep the directory small.
    find "$CACHE_DIR" \( -name 'rl-*.txt' -o -name 'mascot-*.txt' \) -mmin +2880 -exec rm -f {} + 2>/dev/null
fi

best5u=$five_i; best5r=${five_r:-0}
best7u=$seven_i; best7r=${seven_r:-0}
[ -z "$best5u" ] && best5r=0
[ -z "$best7u" ] && best7r=0

for f in "$CACHE_DIR"/rl-*.txt; do
    [ -f "$f" ] || continue
    read -r _v _u5 _r5 _u7 _r7 <"$f" || continue
    [ "$_v" = 'v1' ] || continue

    case "$_u5" in
        ''|*[!0-9]*) ;;
        *)
            case "$_r5" in *[!0-9]*|'') _r5=0 ;; esac
            if [ -z "$best5u" ] || [ "$_r5" -gt "$best5r" ]; then
                best5u=$_u5; best5r=$_r5
            elif [ "$_r5" -eq "$best5r" ] && [ "$_u5" -gt "$best5u" ]; then
                best5u=$_u5
            fi
            ;;
    esac

    case "$_u7" in
        ''|*[!0-9]*) ;;
        *)
            case "$_r7" in *[!0-9]*|'') _r7=0 ;; esac
            if [ -z "$best7u" ] || [ "$_r7" -gt "$best7r" ]; then
                best7u=$_u7; best7r=$_r7
            elif [ "$_r7" -eq "$best7r" ] && [ "$_u7" -gt "$best7u" ]; then
                best7u=$_u7
            fi
            ;;
    esac
done

# ---- meters ----------------------------------------------------------------
# Renders "[◼◼◼◼◻◻◻◻◻◻] 42% 4h10m". The whole meter — brackets, filled cells
# and the outlines of empty cells — carries the load color, and the bar width
# never changes so the line does not jitter.
# The countdown is the time until the window resets, computed locally from
# resets_at — it costs nothing and is the one part that is always current.
#
# A snapshot whose resets_at has already passed is from a window that is over,
# so the number is marked with "~" and dimmed instead of given a countdown.
fmt_remaining() {
    _rem=$1
    if [ "$_rem" -ge 3600 ]; then
        printf '%dh%02dm' $((_rem / 3600)) $(( (_rem % 3600) / 60 ))
    elif [ "$_rem" -ge 60 ]; then
        printf '%dm' $((_rem / 60))
    else
        printf '<1m'
    fi
}

meter() {
    _raw=$1
    _reset=$2

    _known=1
    case "$_raw" in
        *[0-9]*) ;;
        *) _known=0 ;;
    esac

    if [ "$_known" -eq 1 ]; then
        _n=$(round_pct "$_raw")
        case "$_n" in
            ''|*[!0-9]*) _known=0 ;;
        esac
    fi

    _stale=0
    _cd=''
    case "$_reset" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$now" -gt 0 ] && [ "$_reset" -gt 0 ]; then
                if [ "$_reset" -lt "$now" ]; then
                    _stale=1
                else
                    _cd=$(fmt_remaining $((_reset - now)))
                fi
            fi
            ;;
    esac

    if [ "$_known" -eq 0 ]; then
        _filled=0
        _c=$DIM
        _cpct=$DIM
        _pct='--%'
        _cd=''
    else
        _filled=$(( (_n + 5) / 10 ))
        [ "$_filled" -gt "$BAR_LEN" ] && _filled=$BAR_LEN
        if [ "$_n" -ge "$CRIT_AT" ]; then
            _c=$C_CRIT
        elif [ "$_n" -ge "$WARN_AT" ]; then
            _c=$C_WARN
        else
            _c=$C_OK
        fi
        if [ "$_stale" -eq 1 ]; then
            _cpct=$DIM
            _pct="~${_n}%"
        else
            _cpct=$_c
            _pct="${_n}%"
        fi
    fi

    # One colour code covers the whole bar; the cells are the same colour.
    _bar=''
    _i=0
    while [ "$_i" -lt "$BAR_LEN" ]; do
        [ "$_i" -gt 0 ] && _bar="${_bar}${BAR_GAP}"
        if [ "$_i" -lt "$_filled" ]; then
            _bar="${_bar}${BAR_FULL}"
        else
            _bar="${_bar}${BAR_EMPTY}"
        fi
        _i=$((_i + 1))
    done

    _out="${_c}[${BAR_PAD}${_bar}${_c}${BAR_PAD}] ${_cpct}${_pct}${RESET}"
    [ -n "$_cd" ] && _out="${_out} ${DIM}${_cd}${RESET}"
    printf '%s' "$_out"
}

# ---- mascot ----------------------------------------------------------------
# The face is whatever the last roll produced. Rolls happen once a day and only
# when asked for (statusline.sh --roll); nothing here changes the face on its
# own. The result is signed with the machine key, so the stored tier and face
# cannot be edited into something rarer.
#
# Each face carries frames of one expression, all the same width so the line
# never jitters. The frames advance while a turn runs and settle on the first
# one when it ends. Legend wears its own colour ramp, with its outside
# decorations (the first and/or last character) in colours of their own.
#
# Faces are separated by '|' and their frames by '#'; no face contains either
# character, so cut can index them. Spoken lines use the same convention.
KAO_ERROR='（；へ；）#（；ㅅ；）'
KAO_COMMON='ฅ^•ω•^ฅ#ฅ^–ω–^ฅ|U(˶•ﻌ•˶)U#U(˶˘ﻌ˘˶)U|(˶•ө•˶)#(˶–ө–˶)|꒰˶•o•˶꒱#꒰˶˘ᴗ˘˶꒱|(๑• ﻌ •๑)#(๑– ﻌ –๑)|^(˶•(oo)•˶)^#^(˶˘(oo)˘˶)^'
KAO_UNCOMMON='૮(˶•ㅅ•˶)ა#૮(˶˘ㅅ˘˶)ა|ʕ(˶•ᴥ•˶)ʔ#ʕ(˶–ᴥ–˶)ʔ|(˶•⊖•˶)#(˶–⊖–˶)|◖(˶•●•˶)◗#◖(˶–●–˶)◗|໒꒰˶•ᴗ•˶꒱১#໒꒰˶˘ᴗ˘˶꒱১'
KAO_RARE='ʕ˶◐ᴥ◑˶ʔ#ʕ˶●ᴥ●˶ʔ|{˶ʘvʘ˶}#{˶ʘv-˶}|ʕ˶•ﻌ•˶ʔっ#ʕ˶˘ﻌ˘˶ʔっ|ฅ(˶¬ω¬˶)ฅ#ฅ(˶-ω-˶)ฅ'
KAO_UNIQUE='❀૮(˶ᵔ ᵕ ᵔ˶)ა#❀૮(˶- ᵕ -˶)ა|∪(˶ᵔ ᴥ ᵔ˶)∪♡#∪(˶ᵕ ᴥ ᵕ˶)∪♡|ε(˶•ө•˶)з♪#ε(˶˘ө˘˶)з♪'
KAO_LEGEND='༺(^˶•ᴗ•˶^)༻#༺(^˶–ᴗ–˶^)༻#༺(^˶•o•˶^)༻#༺(^˶•ᴗ•˶^)༻|ᵛ⎛⎝(˶•ⱅ•˶)⎠⎞ᵛ#ᵛ⎝⎛(˶•ⱅ•˶)⎞⎠ᵛ|ϟฅ/ᐠ˶•ﻌ•˶ᐟ\ฅϟ#ϟฅ/ᐠ˶˘ﻌ˘˶ᐟ\ฅϟ#ϟฅ/ᐠ˶–ﻌ–˶ᐟ\ฅϟ#ϟฅ/ᐠ˶˘ﻌ˘˶ᐟ\ฅϟ|♨ฅʕ •ˊ ᴥ •ˋ ʔฅ♨#♨ฅʕ ˊ• ᴥ ˋ• ʔฅ♨#♨ฅʕ •ˊ ᴥ •ˋ ʔฅ♨#♨ฅʕ ˊ• ᴥ ˋ• ʔฅ♨#♨ฅʕ ◣ˋ‸ˊ◢ꐦ ʔฅ♨|☆ฅ^˶ᓀ ω ᓂ˶^ฅ✧#☆ฅ^˶- ω -˶^ฅ✧#☆ฅ^˶◕ ω ◕˶^ฅ✧#☆ฅ^˶ᓀ ω ᓂ˶^ฅ✧'
KAO_DEV='｛・ω・｝#｛－ω－｝|⟨◕ᴗ◕⟩#⟨◠ᴗ◠⟩|［◉_◉］#［◉‸◉］|⟨◣_◢⟩#⟨◢_◣⟩'

NAME_COMMON='Kitten|Puppy|Chick|Boo|Hamster|Piglet'
NAME_UNCOMMON='Bunny|Teddy|Penguin|Koala|Sprite'
NAME_RARE='Panda|Owl|Otter|Aloof'
NAME_UNIQUE='Sakura|Sweetheart|Songbird'
NAME_LEGEND='Azure|Luna|Volt|Blaze|Mystic'
NAME_DEV='Root|Sudo|Kernel|Daemon'

# The mascot only speaks while a turn runs, right after one ends, and when
# something is waiting on you. The rest of the time it just sits there.
TALK_WORK_COMMON='영차영차, 하는 중이에요!|꼼지락꼼지락 열심히!|조금만 기다려 줘요!|코드 냠냠 먹는 중이에요'
TALK_WORK_UNCOMMON='꼬리 흔들면서 일하는 중!|집중 집중! 금방 끝낼게요|하나씩 꼭꼭 챙기고 있어요|끝나면 간식 주실 거죠?'
TALK_WORK_RARE='차근차근 살펴보는 중이에요|어디가 아픈지 꼼꼼히 보고 있어요|제일 빠른 닭은? 후다닭!|개가 사람을 가르치면? 개인지도!'
TALK_WORK_UNIQUE='반짝반짝 정리하는 중이에요!|예쁘게 마무리하고 있어요|오리를 생으로 먹으면? 회오리!|왕이 넘어지면? 킹콩!'
TALK_WORK_LEGEND='물고기의 반대말은? 불고기!|제일 빠른 새는? 눈 깜짝할 새!|가장 억울한 도형은? 원통!|소금이 죽으면? 죽염!|천천히, 그래도 확실하게!'
TALK_WORK_DEV='빌드 도는 중.|컴파일 중.|테스트 도는 중.'
TALK_DONE_COMMON='다 했어요!|짠! 끝났어요!|헤헤, 완성이에요!'
TALK_DONE_UNCOMMON='짜잔, 다 끝냈어요!|깔끔하게 해 놨어요, 칭찬해 줘요!|완성! 확인해 볼래요?'
TALK_DONE_RARE='다 됐어요, 꼼꼼히 봤어요!|해냈어요! 한번 볼래요?'
TALK_DONE_UNIQUE='다 끝냈어요, 자신 있어요!|완벽하게 해 놨어요!'
TALK_DONE_LEGEND='부탁한 거 전부 끝냈어요!|다 됐어요, 확인해 줄래요?'
TALK_DONE_DEV='빌드 통과.|커밋하시죠.|배포 준비 완료.|테스트 전부 초록불.'
TALK_NOTIFY_COMMON='저기요오, 봐 줄래요?|여기 좀 봐 줘요!'
TALK_NOTIFY_UNCOMMON='잠깐만요, 물어볼 게 있어요!|이것 좀 같이 봐 줄래요?'
TALK_NOTIFY_RARE='확인이 필요해요, 봐 줄래요?|같이 정해야 할 게 있어요!'
TALK_NOTIFY_UNIQUE='잠깐 봐 줄 수 있어요?|여기 확인이 필요해요!'
TALK_NOTIFY_LEGEND='잠깐 확인해 줄래요?|같이 봐야 할 게 있어요!'
TALK_NOTIFY_DEV='입력 대기 중.|확인 요망.'
TALK_ERROR='앗, 넘어졌어요…|으앙, 실패했어요…'

MASCOT_TIERS='common uncommon rare unique legend'

# Legend colours, generated by docs/legend/render.py. Numbered by legend
# (1-5): the body ramp (36 cells around a loop), the decoration colours
# (seven rainbow hues, or that legend’s own colours) and the colour the
# spoken line wears. One set in 24-bit colour, one snapped to the xterm cube.
LEGEND_RAMP_TRUE_1='38;2;31;95;255 38;2;33;101;255 38;2;34;107;255 38;2;36;113;255 38;2;38;119;255 38;2;39;126;255 38;2;41;132;255 38;2;43;138;255 38;2;44;144;255 38;2;45;150;255 38;2;46;155;255 38;2;47;161;255 38;2;48;167;255 38;2;49;173;255 38;2;51;179;255 38;2;53;184;255 38;2;55;190;255 38;2;58;195;255 38;2;61;201;255 38;2;63;206;255 38;2;66;211;255 38;2;68;217;255 38;2;74;221;255 38;2;83;224;255 38;2;93;227;255 38;2;102;229;255 38;2;112;232;255 38;2;121;235;255 38;2;130;238;255 38;2;135;236;255 38;2;120;216;255 38;2;105;196;255 38;2;90;176;255 38;2;76;155;255 38;2;61;135;255 38;2;46;115;255'
LEGEND_RAMP_TRUE_2='38;2;91;52;150 38;2;93;54;154 38;2;95;55;157 38;2;97;57;161 38;2;99;58;164 38;2;101;60;168 38;2;104;61;172 38;2;106;63;175 38;2;110;67;180 38;2;114;71;186 38;2;119;75;191 38;2;123;80;196 38;2;128;84;201 38;2;133;89;207 38;2;137;93;212 38;2;141;98;216 38;2;145;102;220 38;2;149;107;223 38;2;153;111;227 38;2;157;115;231 38;2;161;120;234 38;2;165;124;238 38;2;165;124;238 38;2;158;117;231 38;2;152;110;225 38;2;146;103;219 38;2;140;96;213 38;2;133;89;207 38;2;127;82;201 38;2;121;75;195 38;2;117;72;188 38;2;113;69;182 38;2;108;65;176 38;2;104;62;169 38;2;100;59;163 38;2;95;55;156'
LEGEND_RAMP_TRUE_3='38;2;255;78;46 38;2;255;83;46 38;2;255;87;46 38;2;255;92;46 38;2;255;96;46 38;2;255;101;46 38;2;255;106;46 38;2;255;110;46 38;2;255;115;47 38;2;255;120;49 38;2;255;124;51 38;2;255;129;52 38;2;255;134;54 38;2;255;138;56 38;2;255;143;57 38;2;255;148;60 38;2;255;152;64 38;2;255;156;68 38;2;255;161;72 38;2;255;165;76 38;2;255;169;80 38;2;255;173;84 38;2;255;173;84 38;2;255;166;81 38;2;255;160;77 38;2;255;153;73 38;2;255;146;69 38;2;255;139;65 38;2;255;132;61 38;2;255;126;58 38;2;255;119;56 38;2;255;112;54 38;2;255;105;53 38;2;255;98;51 38;2;255;92;49 38;2;255;85;48'
LEGEND_RAMP_TRUE_4='38;2;216;36;15 38;2;221;41;17 38;2;227;47;19 38;2;232;52;20 38;2;238;57;22 38;2;243;62;24 38;2;249;68;26 38;2;254;73;28 38;2;255;79;28 38;2;255;86;29 38;2;255;93;29 38;2;255;99;30 38;2;255;106;30 38;2;255;113;30 38;2;255;119;31 38;2;255;126;33 38;2;255;132;35 38;2;255;138;38 38;2;255;145;41 38;2;255;151;44 38;2;255;157;47 38;2;255;163;49 38;2;255;169;53 38;2;255;175;60 38;2;255;181;66 38;2;255;186;72 38;2;255;192;79 38;2;255;198;85 38;2;255;203;91 38;2;254;203;94 38;2;249;179;82 38;2;243;155;71 38;2;238;132;60 38;2;232;108;49 38;2;227;84;37 38;2;221;60;26'
LEGEND_RAMP_TRUE_5='38;2;123;77;255 38;2;115;97;248 38;2;106;118;242 38;2;98;138;235 38;2;90;159;229 38;2;81;179;222 38;2;73;200;216 38;2;65;220;209 38;2;84;211;209 38;2;111;195;209 38;2;138;178;210 38;2;164;162;211 38;2;191;145;211 38;2;218;129;212 38;2;244;113;213 38;2;239;116;213 38;2;212;132;212 38;2;186;149;211 38;2;159;165;211 38;2;132;181;210 38;2;106;198;209 38;2;79;214;208 38;2;66;216;211 38;2;75;195;217 38;2;83;175;224 38;2;91;155;230 38;2;100;134;237 38;2;108;114;243 38;2;116;93;250 38;2;123;77;255 38;2;123;77;255 38;2;123;77;255 38;2;123;77;255 38;2;123;77;255 38;2;123;77;255 38;2;123;77;255'
LEGEND_DECO_TRUE_1='38;2;251;86;86 38;2;251;227;86 38;2;133;251;86 38;2;86;251;180 38;2;86;180;251 38;2;133;86;251 38;2;251;86;227'
LEGEND_DECO_TRUE_2='38;2;139;107;214 38;2;201;176;255'
LEGEND_DECO_TRUE_3='38;2;255;240;74 38;2;255;184;0'
LEGEND_DECO_TRUE_4='38;2;255;122;31 38;2;255;180;58'
LEGEND_DECO_TRUE_5='38;2;251;86;86 38;2;251;227;86 38;2;133;251;86 38;2;86;251;180 38;2;86;180;251 38;2;133;86;251 38;2;251;86;227'
LEGEND_TALK_TRUE='38;2;51;181;255 38;2;180;140;255 38;2;255;145;58 38;2;255;90;60 38;2;157;140;255'
LEGEND_RAMP_256_1='38;5;27 38;5;27 38;5;27 38;5;27 38;5;33 38;5;33 38;5;33 38;5;33 38;5;33 38;5;33 38;5;39 38;5;39 38;5;75 38;5;75 38;5;75 38;5;75 38;5;75 38;5;81 38;5;81 38;5;81 38;5;81 38;5;81 38;5;81 38;5;81 38;5;81 38;5;81 38;5;81 38;5;123 38;5;123 38;5;123 38;5;117 38;5;81 38;5;75 38;5;75 38;5;69 38;5;33'
LEGEND_RAMP_256_2='38;5;60 38;5;60 38;5;61 38;5;61 38;5;61 38;5;61 38;5;61 38;5;61 38;5;61 38;5;61 38;5;97 38;5;98 38;5;98 38;5;98 38;5;98 38;5;98 38;5;98 38;5;98 38;5;98 38;5;140 38;5;140 38;5;141 38;5;141 38;5;140 38;5;98 38;5;98 38;5;98 38;5;98 38;5;98 38;5;98 38;5;97 38;5;61 38;5;61 38;5;61 38;5;61 38;5;61'
LEGEND_RAMP_256_3='38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;208 38;5;209 38;5;209 38;5;209 38;5;209 38;5;209 38;5;209 38;5;209 38;5;209 38;5;215 38;5;215 38;5;215 38;5;215 38;5;215 38;5;215 38;5;215 38;5;215 38;5;209 38;5;209 38;5;209 38;5;209 38;5;209 38;5;209 38;5;203 38;5;203 38;5;203 38;5;203 38;5;203'
LEGEND_RAMP_256_4='38;5;160 38;5;160 38;5;160 38;5;166 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;202 38;5;208 38;5;208 38;5;208 38;5;208 38;5;208 38;5;208 38;5;214 38;5;215 38;5;215 38;5;215 38;5;215 38;5;215 38;5;215 38;5;221 38;5;221 38;5;221 38;5;215 38;5;215 38;5;209 38;5;167 38;5;166 38;5;166'
LEGEND_RAMP_256_5='38;5;99 38;5;99 38;5;69 38;5;69 38;5;74 38;5;74 38;5;80 38;5;80 38;5;80 38;5;80 38;5;110 38;5;146 38;5;140 38;5;176 38;5;206 38;5;212 38;5;176 38;5;140 38;5;146 38;5;110 38;5;80 38;5;80 38;5;80 38;5;80 38;5;74 38;5;74 38;5;69 38;5;63 38;5;99 38;5;99 38;5;99 38;5;99 38;5;99 38;5;99 38;5;99 38;5;99'
LEGEND_DECO_256_1='38;5;203 38;5;221 38;5;119 38;5;85 38;5;75 38;5;99 38;5;206'
LEGEND_DECO_256_2='38;5;98 38;5;183'
LEGEND_DECO_256_3='38;5;227 38;5;214'
LEGEND_DECO_256_4='38;5;208 38;5;215'
LEGEND_DECO_256_5='38;5;203 38;5;221 38;5;119 38;5;85 38;5;75 38;5;99 38;5;206'
LEGEND_TALK_256='38;5;75 38;5;141 38;5;209 38;5;203 38;5;141'
LEGEND_SIDES='LR LR LR LR LR'

# The colours of legend $2 (counted from 1), one SGR parameter per cell: $1 is
# RAMP (the body) or DECO (the decorations). 24-bit or 256-colour per
# LEGEND_TRUE_COLOR.
legend_colors() {
    _lt=256
    [ "$LEGEND_TRUE_COLOR" -eq 1 ] && _lt=TRUE
    eval "printf %s \"\$LEGEND_${1}_${_lt}_$2\""
}

# The one colour legend $1 (counted from 1) speaks in.
legend_talk_color() {
    _lt=256
    [ "$LEGEND_TRUE_COLOR" -eq 1 ] && _lt=TRUE
    eval "printf %s \"\$LEGEND_TALK_${_lt}\"" | cut -d' ' -f"$1"
}

kao_count() { printf %s "$1" | awk -F'|' '{print NF}'; }
kao_at() { printf %s "$1" | cut -d'|' -f"$2"; }
kao_frames() { printf %s "$1" | awk -F'#' '{print NF}'; }
kao_frame() { printf %s "$1" | cut -d'#' -f"$2"; }

# HMAC-SHA256 as hex. openssl is the one that matches the PowerShell version
# byte for byte; the sha256 fallbacks only keep things working where openssl is
# missing, and give that machine its own results.
gacha_hmac() {
    if command -v openssl >/dev/null 2>&1; then
        printf %s "$2" | openssl dgst -sha256 -hmac "$1" 2>/dev/null | sed 's/.*= *//'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf %s "$1$2" | sha256sum 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf %s "$1$2" | shasum -a 256 2>/dev/null | cut -d' ' -f1
    fi
}

gacha_key() { cat "$CACHE_DIR/.gacha-key" 2>/dev/null | tr -d " \t\n\r"; }

# Whether this machine's key is one of the maintainer keys. Comparing hashes
# rather than keys is what lets the list ship in the open.
is_dev_key() {
    [ -n "$DEV_KEY_HASHES" ] || return 1
    _kh=''
    if command -v sha256sum >/dev/null 2>&1; then
        _kh=$(printf %s "$1" | sha256sum 2>/dev/null | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        _kh=$(printf %s "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    elif command -v openssl >/dev/null 2>&1; then
        _kh=$(printf %s "$1" | openssl dgst -sha256 2>/dev/null | sed 's/.*= *//')
    fi
    [ -n "$_kh" ] || return 1
    for _dh in $DEV_KEY_HASHES; do
        [ "$_kh" = "$_dh" ] && return 0
    done
    return 1
}

gacha_pool() {
    case "$1" in
        common)   printf %s "$KAO_COMMON" ;;
        uncommon) printf %s "$KAO_UNCOMMON" ;;
        rare)     printf %s "$KAO_RARE" ;;
        unique)   printf %s "$KAO_UNIQUE" ;;
        legend)   printf %s "$KAO_LEGEND" ;;
        dev)      printf %s "$KAO_DEV" ;;
    esac
}

name_pool() {
    case "$1" in
        common)   printf %s "$NAME_COMMON" ;;
        uncommon) printf %s "$NAME_UNCOMMON" ;;
        rare)     printf %s "$NAME_RARE" ;;
        unique)   printf %s "$NAME_UNIQUE" ;;
        legend)   printf %s "$NAME_LEGEND" ;;
        dev)      printf %s "$NAME_DEV" ;;
    esac
}

talk_pool() {
    case "$1.$2" in
        work.common)       printf %s "$TALK_WORK_COMMON" ;;
        work.uncommon)     printf %s "$TALK_WORK_UNCOMMON" ;;
        work.rare)         printf %s "$TALK_WORK_RARE" ;;
        work.unique)       printf %s "$TALK_WORK_UNIQUE" ;;
        work.legend)       printf %s "$TALK_WORK_LEGEND" ;;
        work.dev)          printf %s "$TALK_WORK_DEV" ;;
        done.common)       printf %s "$TALK_DONE_COMMON" ;;
        done.uncommon)     printf %s "$TALK_DONE_UNCOMMON" ;;
        done.rare)         printf %s "$TALK_DONE_RARE" ;;
        done.unique)       printf %s "$TALK_DONE_UNIQUE" ;;
        done.legend)       printf %s "$TALK_DONE_LEGEND" ;;
        done.dev)          printf %s "$TALK_DONE_DEV" ;;
        notify.common)     printf %s "$TALK_NOTIFY_COMMON" ;;
        notify.uncommon)   printf %s "$TALK_NOTIFY_UNCOMMON" ;;
        notify.rare)       printf %s "$TALK_NOTIFY_RARE" ;;
        notify.unique)     printf %s "$TALK_NOTIFY_UNIQUE" ;;
        notify.legend)     printf %s "$TALK_NOTIFY_LEGEND" ;;
        notify.dev)        printf %s "$TALK_NOTIFY_DEV" ;;
    esac
}

# Sets ROLL_DATE / ROLL_EPOCH / ROLL_TIER / ROLL_INDEX (counted from 0, like the
# PowerShell version, so one cache directory reads the same on both) from the stored roll, or
# returns 1 when there is none. A bad signature reads as no roll at all, so an
# edited file loses the mascot rather than granting a better one.
read_roll() {
    _rf="$CACHE_DIR/gacha.txt"
    [ -f "$_rf" ] || return 1
    _rr=$(cat "$_rf" 2>/dev/null) || return 1
    [ -n "$_rr" ] || return 1

    set -- $_rr
    [ "$#" -ge 6 ] || return 1
    [ "$1" = v1 ] || return 1

    _rkey=$(gacha_key)
    [ -n "$_rkey" ] || return 1
    _want=$(gacha_hmac "$_rkey" "roll|v1|$2|$3|$4|$5")
    [ -n "$_want" ] || return 1
    [ "$_want" = "$6" ] || return 1
    [ -n "$(gacha_pool "$4")" ] || return 1

    ROLL_DATE=$2
    ROLL_EPOCH=$3
    ROLL_TIER=$4
    ROLL_INDEX=$5
    case "$ROLL_INDEX" in ''|*[!0-9]*) return 1 ;; esac
    # A roll from a longer, older roster wraps onto the current one, so an
    # earlier draw keeps a face of its tier.
    _rn=$(kao_count "$(gacha_pool "$4")")
    [ "$_rn" -gt 0 ] || return 1
    ROLL_INDEX=$(( ROLL_INDEX % _rn ))
    case "$ROLL_EPOCH" in ''|*[!0-9]*) ROLL_EPOCH=0 ;; esac
    return 0
}

# One roll per calendar day. A stored roll stamped in the future means the clock
# moved backwards, and that does not earn another roll either.
can_roll() {
    read_roll || return 0
    _today=$(date +%Y%m%d 2>/dev/null)
    [ "$ROLL_DATE" = "$_today" ] && return 1
    if [ "$now" -gt 0 ] && [ "$ROLL_EPOCH" -gt 0 ] && [ "$now" -lt "$ROLL_EPOCH" ]; then
        return 1
    fi
    return 0
}

# Rolls once and stores the signed result. The randomness is cryptographic, so
# the outcome is not predictable from the date or from previous rolls.
# $1 = 원하는 등급(선택), $2 = 원하는 얼굴 이름이나 번호(선택).
# 0 성공 / 1 실패 / 2 권한 없음 / 3 없는 등급 / 4 없는 얼굴.
do_roll() {
    _key=$(gacha_key)
    [ -n "$_key" ] || return 1

    # Picking a tier outright is a maintainer thing - it is how the faces get
    # looked at while working on them. Any other key is turned away here.
    _want="${1:-}"
    if [ -n "$_want" ]; then
        is_dev_key "$_key" || return 2
        [ -n "$(gacha_pool "$_want")" ] || return 3
    fi

    _rand=''
    if command -v openssl >/dev/null 2>&1; then
        _rand=$(openssl rand -hex 8 2>/dev/null)
    elif [ -r /dev/urandom ]; then
        _rand=$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n\r')
    fi
    [ "${#_rand}" -ge 16 ] || return 1

    _n1=$(printf '%d' "0x$(printf %s "$_rand" | cut -c1-8)" 2>/dev/null) || return 1
    _n2=$(printf '%d' "0x$(printf %s "$_rand" | cut -c9-16)" 2>/dev/null) || return 1

    _tiers=$MASCOT_TIERS
    _odds=$MASCOT_ODDS
    if is_dev_key "$_key"; then
        _scaled=''
        _used=0
        for _odd in $MASCOT_ODDS; do
            _v=$(( _odd * (1000 - DEV_ODDS) / 1000 ))
            _scaled="$_scaled $_v"
            _used=$(( _used + _v ))
        done
        _tiers="dev $MASCOT_TIERS"
        _odds="$(( 1000 - _used ))$_scaled"
    fi

    _roll=$(( _n1 % 1000 ))
    _acc=0
    _ti=1
    ROLL_TIER=common
    for _odd in $_odds; do
        _acc=$(( _acc + _odd ))
        if [ "$_roll" -lt "$_acc" ]; then
            ROLL_TIER=$(printf %s "$_tiers" | cut -d' ' -f"$_ti")
            break
        fi
        _ti=$(( _ti + 1 ))
    done
    [ -n "$_want" ] && ROLL_TIER=$_want

    _kn=$(kao_count "$(gacha_pool "$ROLL_TIER")")
    [ "$_kn" -gt 0 ] || return 1
    ROLL_INDEX=$(( _n2 % _kn ))

    # A named face (or its 1-based number) goes with a chosen tier, so the
    # maintainer can wear each one in turn while working on them.
    _wantf="${2:-}"
    if [ -n "$_want" ] && [ -n "$_wantf" ]; then
        _pick=''
        case "$_wantf" in
            ''|*[!0-9]*)
                _pick=$(printf %s "$(name_pool "$ROLL_TIER")" | awk -F'|' -v w="$_wantf" '{ for (i = 1; i <= NF; i++) if ($i == w) { print i - 1; exit } }')
                ;;
            *)
                [ "$_wantf" -ge 1 ] && [ "$_wantf" -le "$_kn" ] && _pick=$(( _wantf - 1 ))
                ;;
        esac
        [ -n "$_pick" ] || return 4
        ROLL_INDEX=$_pick
    fi

    ROLL_DATE=$(date +%Y%m%d 2>/dev/null)
    ROLL_EPOCH=$now
    [ "$ROLL_EPOCH" -gt 0 ] || ROLL_EPOCH=$(date +%s 2>/dev/null)
    _sig=$(gacha_hmac "$_key" "roll|v1|$ROLL_DATE|$ROLL_EPOCH|$ROLL_TIER|$ROLL_INDEX")
    [ -n "$_sig" ] || return 1

    mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
    _tmp="$CACHE_DIR/gacha.tmp.$$"
    printf 'v1 %s %s %s %s %s' "$ROLL_DATE" "$ROLL_EPOCH" "$ROLL_TIER" "$ROLL_INDEX" "$_sig" \
        >"$_tmp" 2>/dev/null || return 1
    mv -f "$_tmp" "$CACHE_DIR/gacha.txt" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    return 0
}

# Flat tier color. Legend uses this only when the gradient is unavailable.
tier_color() {
    case "$1" in
        legend)   printf %s "$C_LEGEND" ;;
        dev)      printf %s "$C_DEV" ;;
        unique)   printf %s "$C_UNIQUE" ;;
        rare)     printf %s "$C_RARE" ;;
        uncommon) printf %s "$C_UNCOMMON" ;;
        *)        printf %s "$C_COMMON" ;;
    esac
}

# The gradient walks character by character, so it needs an awk that counts
# characters rather than bytes. gawk in a UTF-8 locale does; mawk and busybox
# awk do not, and there the caller falls back to one flat color.
awk_counts_chars() {
    [ "$(printf %s "¬‿" | awk '{print length($0)}' 2>/dev/null)" = 2 ]
}

# Paints the face with the whole palette ($3, one SGR parameter per cell),
# darkest at the edges and lightest in the middle, and makes a few characters
# flash the lightest colour (or the darkest where the text is already pale).
# Which ones is decided by a small integer hash of the seed ($2) and the
# position, so both implementations agree exactly. The decorations at the
# sides named in $4 (L and/or R) take the colours in $5 instead: a rainbow
# turns with the seed and its two sides sit half a turn apart, a pair (the
# bolts' yellows) stays put, one colour per side.
grad_text() {
    printf %s "$1" | awk -v seed="$2" -v esc="$ESC" -v rb="$3" -v every="$SPARKLE_EVERY" -v sides="$4" -v dc="$5" '
        BEGIN {
            n = split(rb, C, " "); lo = 0; hi = int(n / 2)
            nd = split(dc, D, " "); shift = int(nd / 2); rot = 0
            if (nd > 2) rot = seed
        }
        {
            L = length($0); slot = 0
            for (i = 1; i <= L; i++) {
                d = 2 * (i - 1) - (L - 1); if (d < 0) d = -d
                idx = hi
                if (L > 1) idx = hi - int((hi - lo) * d / (L - 1))
                code = C[idx + 1]
                if (every > 0) {
                    x = (seed * 31 + (i - 1) * 7 + 13) % 2147483647
                    x = (x * 48271) % 2147483647
                    x = (x * 48271) % 2147483647
                    if (x % every == 0) {
                        code = C[hi + 1]
                        if (substr(C[idx + 1], 1, 5) == "38;2;") {
                            split(C[idx + 1], P, ";")
                            lum = (P[3] * 299 + P[4] * 587 + P[5] * 114) / 1000
                            if (lum > 170) code = C[1]
                        }
                    }
                }
                if (nd > 0 && ((i == 1 && index(sides, "L")) || (i == L && index(sides, "R")))) {
                    code = D[(rot + slot * shift) % nd + 1]
                    slot++
                }
                printf "%s[%sm%s", esc, code, substr($0, i, 1)
            }
        }'
}

# Picks a line from a pool, seeded with the timestamp the hook recorded, so it
# holds steady across redraws and changes with the next turn.
pick_talk() {
    [ "$SHOW_MASCOT_TALK" -eq 1 ] || return 0
    _tp="$1"
    [ -n "$_tp" ] || return 0
    _tn=$(kao_count "$_tp")
    [ "$_tn" -gt 0 ] || return 0
    _th=$(( ($2 * 1103515245 + 12345) % 2147483648 ))
    [ "$_th" -lt 0 ] && _th=$(( 0 - _th ))
    kao_at "$_tp" "$(( _th % _tn + 1 ))"
}

# Draws the face for the current roll, animated by the turn state the hooks
# left for this session. Prints nothing only when nothing has been rolled yet,
# so the line then looks as it did before the mascot existed.
mascot() {
    [ "$SHOW_MASCOT" -eq 1 ] || return 0

    # The face is the machine-wide roll, so it shows in every session from the
    # first redraw. The state file only adds what the turn is doing; until the
    # hooks write one the mascot simply sits idle.
    _state=idle
    _stamp=0
    _mf="$CACHE_DIR/mascot-$sid_key.txt"
    if [ -n "$sid_key" ] && [ -f "$_mf" ]; then
        _raw=$(cat "$_mf" 2>/dev/null)
        if [ -n "$_raw" ]; then
            _state=$(printf %s "$_raw" | awk '{print $1}')
            _stamp=$(printf %s "$_raw" | awk '{print $2}')
        fi
    fi
    case "$_stamp" in ''|*[!0-9]*) _stamp=0 ;; esac

    if [ "$_state" = error ]; then
        _fn=$(kao_frames "$KAO_ERROR")
        _fr=1
        [ "$now" -gt 0 ] && _fr=$(( (now / ANIM_SECS) % _fn + 1 ))
        _line=$(pick_talk "$TALK_ERROR" "$_stamp")
        [ -n "$_line" ] && _line=" $_line"
        printf '%s' "${C_CRIT}$(kao_frame "$KAO_ERROR" "$_fr")${_line}${RESET}"
        return 0
    fi

    read_roll || return 0
    _face=$(kao_at "$(gacha_pool "$ROLL_TIER")" "$(( ROLL_INDEX + 1 ))")
    [ -n "$_face" ] || return 0

    _fn=$(kao_frames "$_face")
    _fr=1
    if [ "$_state" = working ] && [ "$now" -gt 0 ]; then
        _fr=$(( (now / ANIM_SECS) % _fn + 1 ))
    fi

    # Speaks while working, for a short while after finishing, and whenever
    # something is waiting on you. Otherwise it stays quiet.
    _line=''
    case "$_state" in
        working)
            _line=$(pick_talk "$(talk_pool work "$ROLL_TIER")" "$_stamp")
            ;;
        notify)
            _line=$(pick_talk "$(talk_pool notify "$ROLL_TIER")" "$_stamp")
            ;;
        done)
            if [ "$now" -le 0 ] || [ "$_stamp" -le 0 ] ||
               [ "$(( now - _stamp ))" -le "$TALK_WINDOW_SECS" ]; then
                _line=$(pick_talk "$(talk_pool done "$ROLL_TIER")" "$_stamp")
            fi
            ;;
    esac
    _text=$(kao_frame "$_face" "$_fr")
    # Legend wears its ramp and coloured decorations; the spoken line sits one
    # space to the right in the legend's own colour, steady.
    if [ "$ROLL_TIER" = legend ] && [ -n "$RESET" ] && awk_counts_chars; then
        _ln=$(( ROLL_INDEX + 1 ))
        _seed=0
        [ "$now" -gt 0 ] && _seed=$(( now % 1000003 ))
        _sides=$(printf %s "$LEGEND_SIDES" | cut -d' ' -f"$_ln")
        printf '%s' "$(grad_text "$_text" "$_seed" "$(legend_colors RAMP "$_ln")" "$_sides" "$(legend_colors DECO "$_ln")")${RESET}"
        [ -n "$_line" ] && printf ' %s[%sm%s%s' "$ESC" "$(legend_talk_color "$_ln")" "$_line" "$RESET"
        return 0
    fi
    [ -n "$_line" ] && _text="${_text} ${_line}"
    printf '%s' "$(tier_color "$ROLL_TIER")${_text}${RESET}"
}
# ---- subcommands -----------------------------------------------------------
# Never read stdin, so they work from a plain prompt.

# Paints one frame the way the status line would: the legend gradient when it
# is available, the flat tier colour otherwise.
paint_face() {
    if [ "$1" = legend ] && [ -n "$RESET" ] && awk_counts_chars; then
        _pl=$(( $2 + 1 ))
        _ps=$(printf %s "$LEGEND_SIDES" | cut -d' ' -f"$_pl")
        printf '%s%s' "$(grad_text "$3" 0 "$(legend_colors RAMP "$_pl")" "$_ps" "$(legend_colors DECO "$_pl")")" "$RESET"
    else
        printf '%s%s%s' "$(tier_color "$1")" "$3" "$RESET"
    fi
}

# What a freshly drawn mascot says: each face introduces itself by name.
# Generated by docs/legend/render.py (python render.py shintro).
intro_line() {
    case "$2" in
        Kitten) printf %s '"냥! 나는 Kitten, 아기 고양이예요!"' ;;
        Puppy) printf %s '"멍멍! 나는 Puppy, 강아지예요!"' ;;
        Chick) printf %s '"삐약! 나는 Chick, 병아리예요!"' ;;
        Boo) printf %s '"까꿍! 나는 Boo, 꼬마 유령이에요!"' ;;
        Hamster) printf %s '"쪼르르! 나는 Hamster, 햄스터예요!"' ;;
        Piglet) printf %s '"꿀꿀! 나는 Piglet, 아기 돼지예요!"' ;;
        Bunny) printf %s '"깡총! 나는 Bunny, 솜토끼예요!"' ;;
        Teddy) printf %s '"폭신! 나는 Teddy, 곰돌이예요!"' ;;
        Penguin) printf %s '"뒤뚱! 나는 Penguin, 펭귄이에요!"' ;;
        Koala) printf %s '"하암~ 나는 Koala, 코알라예요!"' ;;
        Sprite) printf %s '"팔랑! 나는 Sprite, 작은 정령이에요!"' ;;
        Panda) printf %s '"냠냠! 나는 Panda, 판다예요!"' ;;
        Owl) printf %s '"부엉! 나는 Owl, 부엉이예요!"' ;;
        Otter) printf %s '"퐁당! 나는 Otter, 수달이에요!"' ;;
        Aloof) printf %s '"흥, 나는 Aloof, 도도한 고양이예요."' ;;
        Sakura) printf %s '"살랑! 나는 Sakura, 벚꽃 토끼예요!"' ;;
        Sweetheart) printf %s '"두근! 나는 Sweetheart, 하트 강아지예요!"' ;;
        Songbird) printf %s '"랄랄라♪ 나는 Songbird, 노래 병아리예요!"' ;;
        Azure) printf %s '"크앙! 나는 Azure, 아기 청룡이에요!"' ;;
        Luna) printf %s '"파닥파닥! 나는 Luna, 달빛 박쥐예요!"' ;;
        Volt) printf %s '"찌릿! 나는 Volt, 번개 여우예요!"' ;;
        Blaze) printf %s '"으르렁! 나는 Blaze, 불곰이에요!"' ;;
        Mystic) printf %s '"쉿! 나는 Mystic, 마법 고양이예요!"' ;;
        *) printf '"%s. 로그인 완료."' "$2" ;;
    esac
}

# Prints one roll as "（・ω・）  Kitten  [커먼 1/12]", name and tier included.
show_draw() {
    case "$ROLL_TIER" in
        common)   _lab='커먼' ;;
        uncommon) _lab='언커먼' ;;
        rare)     _lab='레어' ;;
        unique)   _lab='유니크' ;;
        legend)   _lab='레전드' ;;
        dev)      _lab='DEV' ;;
    esac
    _f=$(kao_at "$(gacha_pool "$ROLL_TIER")" "$(( ROLL_INDEX + 1 ))")
    _nm=$(kao_at "$(name_pool "$ROLL_TIER")" "$(( ROLL_INDEX + 1 ))")
    _tot=$(kao_count "$(gacha_pool "$ROLL_TIER")")
    printf '  %s  %s  [%s %s/%s]\n' "$(paint_face "$ROLL_TIER" "$ROLL_INDEX" "$(kao_frame "$_f" 1)")" "$_nm" "$_lab" "$(( ROLL_INDEX + 1 ))" "$_tot"
    printf '  %s\n' "$(intro_line "$ROLL_TIER" "$_nm")"
    printf '  표정 %s장  %s\n' "$(kao_frames "$_f")" "$(printf %s "$_f" | tr '#' ' ')"
}

if [ "$SUBCOMMAND" = roll ]; then
    # 등급을 직접 고르는 건 메인테이너 키에서만 됩니다.
    if [ -n "$ROLL_WANT" ]; then
        do_roll "$ROLL_WANT" "$ROLL_FACE"
        case $? in
            0)
                printf '%s 등급으로 지정했습니다.\n\n  뿅!\n' "$ROLL_WANT"
                show_draw
                exit 0
                ;;
            2)
                printf '등급을 직접 고르는 건 메인테이너 키에서만 됩니다.\n'
                printf '일반 사용자는 --roll 로 하루 한 번 뽑습니다.\n'
                exit 1
                ;;
            3)
                printf '그런 등급이 없습니다: %s\n' "$ROLL_WANT"
                printf '고를 수 있는 값: common uncommon rare unique legend dev\n'
                exit 1
                ;;
            4)
                printf '그런 얼굴이 없습니다: %s
' "$ROLL_FACE"
                printf '고를 수 있는 값: %s
' "$(name_pool "$ROLL_WANT" | tr '|' ' ')"
                exit 1
                ;;
            *)
                printf '지정에 실패했습니다.\n'
                exit 1
                ;;
        esac
    fi

    if can_roll; then
        if do_roll; then
            printf '오늘의 마스코트를 뽑았습니다!\n\n  뿅!\n'
            show_draw
            printf '\n다음 뽑기는 내일부터 가능합니다.\n'
            exit 0
        fi
        printf '뽑기에 실패했습니다. 턴을 한 번 끝내 비밀키가 만들어졌는지 확인해 주세요.\n'
        exit 1
    fi
    read_roll
    printf '오늘 뽑기는 이미 사용했습니다. 내일 다시 뽑을 수 있어요.\n\n'
    show_draw
    exit 0
fi

if [ "$SUBCOMMAND" = today ]; then
    if read_roll; then
        printf '지금 마스코트  (뽑은 날 %s)\n\n' "$ROLL_DATE"
        show_draw
        printf '\n'
        if can_roll; then
            printf '오늘 뽑기가 남아 있습니다. --roll 로 새로 뽑을 수 있어요.\n'
        else
            printf '오늘 뽑기는 사용했습니다. 내일 다시 뽑을 수 있어요.\n'
        fi
    else
        printf '아직 뽑은 마스코트가 없습니다. --roll 로 뽑아 보세요.\n'
    fi
    exit 0
fi

# ---- output ----------------------------------------------------------------
SEP="${DIM} | ${RESET}"
line="${DIM}DIR${RESET} ${C_DIR}${project}${RESET}"
line="${line}${SEP}${DIM}GIT${RESET} ${c_branch}${branch}${RESET}"
line="${line}${SEP}${DIM}MODEL${RESET} ${C_MODEL}${model}${RESET}"
# Effort as its first letters: L M H XH, and U for max.
if [ "$SHOW_EFFORT" -eq 1 ]; then
    case "$effort" in
        low)    line="${line}${SEP}${DIM}EFFORT${RESET} ${C_EFF_L}L${RESET}" ;;
        medium) line="${line}${SEP}${DIM}EFFORT${RESET} ${C_EFF_M}M${RESET}" ;;
        high)   line="${line}${SEP}${DIM}EFFORT${RESET} ${C_EFF_H}H${RESET}" ;;
        xhigh)  line="${line}${SEP}${DIM}EFFORT${RESET} ${C_EFF_XH}XH${RESET}" ;;
        max)    line="${line}${SEP}${DIM}EFFORT${RESET} ${C_EFF_U}U${RESET}" ;;
    esac
fi
line="${line}${SEP}${DIM}CTX${RESET} $(meter "$ctx" '')"
line="${line}${SEP}${DIM}5H${RESET} $(meter "$best5u" "$best5r")"
if [ "$SHOW_SEVEN_DAY" -eq 1 ]; then
    line="${line}${SEP}${DIM}7D${RESET} $(meter "$best7u" "$best7r")"
fi
_mascot=$(mascot)
[ -n "$_mascot" ] && line="${line} ${_mascot}"

printf '%s\n' "$line"
exit 0
