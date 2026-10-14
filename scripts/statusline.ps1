# claude-statusline — Windows PowerShell implementation (5.1 and PowerShell 7+).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% 4h10m
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   -Roll      roll today's mascot (once a day) and exit
#   -Roll -Tier <name>   maintainer only: set the tier outright
#   -Roll -Tier <name> -Face <name|number>   maintainer only: that exact face
#   -Today     print the mascot you are currently wearing and exit
#   -Version   print the version and exit
#   -Help      print a short usage summary and exit
param(
    [switch]$Roll,
    [switch]$Today,
    [switch]$Version,
    [switch]$Help,
    [string]$Tier = '',
    [string]$Face = ''
)

$StatuslineVersion = '1.13.0'

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# This script runs on every redraw, so the hot path below avoids cmdlets
# (each costs tens of milliseconds to spin up) and uses .NET calls instead.

# ---- appearance ------------------------------------------------------------
$BarLength = 10
# U+25FC/25FB draw a near-square block with the glyph's own margins, so flush
# cells still show a hairline gap, and the empty cell renders as an outlined
# box rather than a shaded fill. Glyphs are built from code points so the file
# survives being saved in any encoding.
$BarFull = [string][char]0x25FC   # ◼ filled cell
$BarEmpty = [string][char]0x25FB  # ◻ empty cell (outlined)
$BarGap = ''                      # cells are flush; the glyph separates itself
$BarPad = ''                      # spacing just inside the brackets
$DirMax = 32                      # project name is left-truncated past this
$Ellipsis = [string][char]0x2026

$ShowSevenDay = $false  # set to $true to also show the 7-day (weekly) meter
# The reasoning effort after the model, as one or two letters (L M H XH U).
$ShowEffort = $true

# Mascot: a kaomoji at the end of the line that reflects what the session is
# doing. The companion hooks (mascot-hook.ps1) tell it the state; without them
# it still shows the face, just never animated.
$ShowMascot = $true
# The mascot speaks a line when a turn finishes; set $false for the face alone.
$ShowMascotTalk = $true
# Seconds per expression frame while a turn runs. Claude Code only redraws
# every refreshInterval (the installer sets 2), so keep the two equal.
$AnimSecs = 2
# Legend sparkle: the palette runs from its darkest colour at the edges of
# the face to its lightest in the middle, and on every redraw one character
# in SparkleEvery flashes the lightest colour (or the darkest where the text
# is already pale), picked by the clock so the twinkle wanders. 1 lights
# everything, 0 turns the twinkle off. The spoken line gets the same
# treatment on its own.
$SparkleEvery = 4
# 24-bit colour for the legend ramp. Set $false on a terminal that only knows
# 256 colours; the ramp then snaps to the nearest of those.
$LegendTrueColor = $true
# How long after a turn ends the mascot keeps talking. Past this it goes quiet
# until the next turn, so an idle terminal is not left with a stale sentence.
$TalkWindowSecs = 60
# The switches above can also be flipped without editing this file, through
# environment variables (Claude Code passes its "env" settings through):
#   STATUSLINE_MASCOT=0      hide the mascot
#   STATUSLINE_TALK=0        face only, no lines
#   STATUSLINE_SEVEN_DAY=1   show the weekly meter
#   STATUSLINE_TRUE_COLOR=0  256-colour ramps
#   STATUSLINE_EFFORT=0      hide the effort
switch ($env:STATUSLINE_MASCOT) { '0' { $ShowMascot = $false } '1' { $ShowMascot = $true } }
switch ($env:STATUSLINE_TALK) { '0' { $ShowMascotTalk = $false } '1' { $ShowMascotTalk = $true } }
switch ($env:STATUSLINE_SEVEN_DAY) { '0' { $ShowSevenDay = $false } '1' { $ShowSevenDay = $true } }
switch ($env:STATUSLINE_TRUE_COLOR) { '0' { $LegendTrueColor = $false } '1' { $LegendTrueColor = $true } }
switch ($env:STATUSLINE_EFFORT) { '0' { $ShowEffort = $false } '1' { $ShowEffort = $true } }
# The plugin draws the mascot under the prompt itself on a Claude Code that
# can, and says so here; the line then leaves its own face out.
if ($env:STATUSLINE_MASCOT_BY_MOD -eq '1') { $ShowMascot = $false }

# Rarity odds in per-mille, highest first, totalling 1000. These are fixed on
# purpose: everyone rolls against the same table, and editing them turns the roll
# into a choice, which is no roll at all.
$MascotOdds = @{ common = 250; uncommon = 300; rare = 250; unique = 150; legend = 50 }

# Maintainer tier. A key whose SHA-256 is listed here also rolls 'dev' faces;
# every other key never sees them. Only the hash is published, so the list gives
# nothing away - matching it would mean finding a preimage of SHA-256. Add your
# own hash to claim the tier on your machine: SHA-256 of the key file's text,
# trimmed of whitespace, hashed as UTF-8.
$DevKeyHashes = @(
    '64528c9f19e91ed0ca521f443a672235456aa3cdf23f45787f07482759777238'
)
# Per-mille odds of the dev tier; the ordinary tiers share what is left, keeping
# their ratio to each other.
$DevOdds = 100

# Meters turn amber at WarnAt and red at CritAt.
$WarnAt = 60
$CritAt = 90

# Rate-limit snapshots are shared between sessions through this directory so
# every terminal shows the freshest value any of them has seen.
$homeDir = $HOME
if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = $env:USERPROFILE }
$CacheDir = $env:STATUSLINE_CACHE_DIR
if ([string]::IsNullOrWhiteSpace($CacheDir)) {
    $CacheDir = "$homeDir\.claude\statusline-cache"
}

$Esc = [char]27
if ([string]::IsNullOrEmpty($env:NO_COLOR)) {
    $Reset = "$($Esc)[0m"
    $Dim = "$($Esc)[90m"
    $CDir = "$($Esc)[97m"             # bright white — project name
    $CGitMain = "$($Esc)[95m"         # magenta — main / master
    $CGitOther = "$($Esc)[96m"        # sky blue — every other branch
    $CModel = "$($Esc)[93m"           # yellow — model name
    # Effort, low -> max: grey, green, sky blue, magenta, bold yellow.
    $CEffort = @{ low = "$($Esc)[37m"; medium = "$($Esc)[92m"; high = "$($Esc)[96m"; xhigh = "$($Esc)[95m"; max = "$($Esc)[1;93m" }
    # 256-color meter palette. For 16-color-only terminals use
    # 96 / 93 / 91 in place of these three.
    $COk = "$($Esc)[38;5;46m"         # neon green — under WarnAt
    $CWarn = "$($Esc)[38;5;214m"      # amber      — WarnAt and up
    $CCrit = "$($Esc)[38;5;203m"      # red        — CritAt and up
    # Mascot rarity palette, common -> legend.
    $CCommon = "$($Esc)[38;5;253m"    # the faintest grey
    $CUncommon = "$($Esc)[38;5;120m"  # light green
    $CRare = "$($Esc)[38;5;117m"      # sky blue
    $CUnique = "$($Esc)[38;5;141m"    # purple
    $CLegend = "$($Esc)[1;38;5;208m"  # orange, bold - only when the gradient is off
    $CDev = "$($Esc)[1;38;5;51m"      # cyan, bold - maintainer only
} else {
    $Reset = ''; $Dim = ''; $CDir = ''; $CGitMain = ''; $CGitOther = ''
    $CModel = ''; $COk = ''; $CWarn = ''; $CCrit = ''
    $CEffort = @{ low = ''; medium = ''; high = ''; xhigh = ''; max = '' }
    $CCommon = ''; $CUncommon = ''; $CRare = ''; $CUnique = ''; $CLegend = ''
    $CDev = ''
}

$Now = 0
try { $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } catch { $Now = 0 }

# Rounds a raw percentage to a clamped [0,100] integer; $null when unparseable.
function Get-Pct {
    param($Raw)
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) { return $null }
    $value = 0.0
    if (-not [double]::TryParse(
            [string]$Raw,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)) { return $null }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }
    return [int][Math]::Floor($value + 0.5)
}

# Parses an epoch-seconds value; $null when unparseable.
function Get-Epoch {
    param($Raw)
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) { return $null }
    $value = 0.0
    if (-not [double]::TryParse(
            [string]$Raw,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)) { return $null }
    if ($value -le 0) { return $null }
    return [long][Math]::Floor($value)
}

function Format-Remaining {
    param([long]$Rem)
    if ($Rem -ge 3600) {
        return ('{0}h{1:d2}m' -f [int][Math]::Floor($Rem / 3600), [int][Math]::Floor(($Rem % 3600) / 60))
    }
    if ($Rem -ge 60) { return ('{0}m' -f [int][Math]::Floor($Rem / 60)) }
    return '<1m'
}

# Renders "[◼◼◼◼◻◻◻◻◻◻] 42% 4h10m". The whole meter — brackets, filled cells
# and the outlines of empty cells — carries the load color, and the bar width
# never changes so the line does not jitter.
# The countdown is the time until the window resets, computed locally from
# resets_at — it costs nothing and is the one part that is always current.
#
# A snapshot whose resets_at has already passed is from a window that is over,
# so the number is marked with "~" and dimmed instead of given a countdown.
function Get-Meter {
    param($Pct, $ResetEpoch)

    $stale = $false
    $countdown = ''
    if ($Now -gt 0 -and $null -ne $ResetEpoch -and $ResetEpoch -gt 0) {
        if ($ResetEpoch -lt $Now) { $stale = $true }
        else { $countdown = Format-Remaining ($ResetEpoch - $Now) }
    }

    if ($null -ne $Pct) {
        $n = [int]$Pct
        $filled = [int][Math]::Floor(($n + 5) / 10)
        if ($filled -gt $BarLength) { $filled = $BarLength }
        if ($filled -lt 0) { $filled = 0 }

        if ($n -ge $CritAt) { $c = $CCrit }
        elseif ($n -ge $WarnAt) { $c = $CWarn }
        else { $c = $COk }

        if ($stale) {
            $cPct = $Dim
            $pct = "~$n%"
            $countdown = ''
        } else {
            $cPct = $c
            $pct = "$n%"
        }
    } else {
        $filled = 0
        $c = $Dim
        $cPct = $Dim
        $pct = '--%'
        $countdown = ''
    }

    if ($BarGap -eq '') {
        $bar = ($BarFull * $filled) + ($BarEmpty * ($BarLength - $filled))
    } else {
        $cells = [string[]]::new($BarLength)
        for ($i = 0; $i -lt $BarLength; $i++) {
            if ($i -lt $filled) { $cells[$i] = $BarFull } else { $cells[$i] = $BarEmpty }
        }
        $bar = [string]::Join($BarGap, $cells)
    }

    $out = "$($c)[$($BarPad)$($bar)$($c)$($BarPad)] $($cPct)$($pct)$($Reset)"
    if ($countdown -ne '') { $out += " $($Dim)$($countdown)$($Reset)" }
    return $out
}

# Last path segment, left-truncated so long names lose their head, not their tail.
function Get-LeafName {
    param([string]$Path, [int]$Max)

    $trimmed = $Path -replace '[\\/]+$', ''
    if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = $Path }
    $parts = $trimmed -split '[\\/]'
    $name = $parts[$parts.Count - 1]
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $trimmed }

    if ($name.Length -gt $Max) {
        $name = $Ellipsis + $name.Substring($name.Length - $Max + 1)
    }
    return $name
}

# ---- mascot ---------------------------------------------------------------
# The face is whatever the last roll produced. Rolls happen once a day and
# only when asked for (statusline.ps1 -Roll); nothing here changes the face on
# its own. The result is signed with the machine key, so the stored tier and
# face cannot be edited into something rarer.
#
# Each face carries frames of one expression, all the same width so the line
# never jitters. The frames advance while a turn runs and settle on the first
# one when it ends. Legend wears its own colour ramp, with its outside
# decorations (the first and/or last character) in colours of their own.
#
# Faces are separated by '|' and their frames by '#', exactly as in the sh
# version; no face contains either character. This file carries a UTF-8 BOM so
# the glyphs and the Korean lines below survive any editor.

$KaoError = '（；へ；）#（；ㅅ；）'
$KaoCommon = 'ฅ^•ω•^ฅ#ฅ^–ω–^ฅ|U(˶•ﻌ•˶)U#U(˶˘ﻌ˘˶)U|(˶•ө•˶)#(˶–ө–˶)|꒰˶•o•˶꒱#꒰˶˘ᴗ˘˶꒱|(๑• ﻌ •๑)#(๑– ﻌ –๑)|^(˶•(oo)•˶)^#^(˶˘(oo)˘˶)^'
$KaoUncommon = '૮(˶•ㅅ•˶)ა#૮(˶˘ㅅ˘˶)ა|ʕ(˶•ᴥ•˶)ʔ#ʕ(˶–ᴥ–˶)ʔ|(˶•⊖•˶)#(˶–⊖–˶)|◖(˶•●•˶)◗#◖(˶–●–˶)◗|໒꒰˶•ᴗ•˶꒱১#໒꒰˶˘ᴗ˘˶꒱১'
$KaoRare = 'ʕ˶◐ᴥ◑˶ʔ#ʕ˶●ᴥ●˶ʔ|{˶ʘvʘ˶}#{˶ʘv-˶}|ʕ˶•ﻌ•˶ʔっ#ʕ˶˘ﻌ˘˶ʔっ|ฅ(˶¬ω¬˶)ฅ#ฅ(˶-ω-˶)ฅ'
$KaoUnique = '❀૮(˶ᵔ ᵕ ᵔ˶)ა#❀૮(˶- ᵕ -˶)ა|∪(˶ᵔ ᴥ ᵔ˶)∪♡#∪(˶ᵕ ᴥ ᵕ˶)∪♡|ε(˶•ө•˶)з♪#ε(˶˘ө˘˶)з♪'
$KaoLegend = 'ʚ૮(˶ˋ•ﻌ•ˊ˶)აɞ≋#ʚ૮(˶ˋ–ﻌ–ˊ˶)აɞ≋#ʚ૮(˶ˋ●ﻌ●ˊ˶)აɞ≋#ʚ૮(˶ˋ•ﻌ•ˊ˶)აɞ≋|☾꒰˶ᵔ ᴗ ᵔ˶꒱✧#☾꒰˶- ᴗ -˶꒱✧#☾꒰˶ᵔ o ᵔ˶꒱✧#☾꒰˶ᵔ ᴗ ᵔ˶꒱✧|ϟᐱ(˶•ﻌ•˶)ᐱϟ#ϟᐱ(˶˘ﻌ˘˶)ᐱϟ#ϟᐱ(˶–ﻌ–˶)ᐱϟ#ϟᐱ(˶˘ﻌ˘˶)ᐱϟ|✦ʚ꒰˶✧ᴗ✧˶꒱ɞ✧#✦ʚ꒰˶-ᴗ-˶꒱ɞ✧#✦ʚ꒰˶✧o✧˶꒱ɞ✧#✦ʚ꒰˶✧ᴗ✧˶꒱ɞ✧|/ᐠ˶ᓀ ω ᓂ˶ᐟ\⟡#/ᐠ˶ʘ ω ʘ˶ᐟ\⟡#/ᐠ˶- ω -˶ᐟ\⟡#/ᐠ˶ᓀ ω ᓂ˶ᐟ\⟡'
$KaoDev = '｛・ω・｝#｛－ω－｝|⟨◕ᴗ◕⟩#⟨◠ᴗ◠⟩|［◉_◉］#［◉‸◉］|⟨◣_◢⟩#⟨◢_◣⟩'

$NameCommon = 'Kitten|Puppy|Chick|Boo|Hamster|Piglet'
$NameUncommon = 'Bunny|Teddy|Penguin|Koala|Sprite'
$NameRare = 'Panda|Owl|Otter|Aloof'
$NameUnique = 'Sakura|Sweetheart|Songbird'
$NameLegend = 'Azure|Luna|Volt|Stella|Mystic'
$NameDev = 'Root|Sudo|Kernel|Daemon'

# Legend colours, generated by docs/legend/render.py, in legend order: the
# body ramp (36 cells around a loop), the decoration colours (seven rainbow
# hues, or the two yellows of the bolts) and the colour the spoken line
# wears. One set in 24-bit colour, one snapped to the xterm cube.
$LegendRampTrue = @('38;2;31;95;255|38;2;33;101;255|38;2;34;107;255|38;2;36;113;255|38;2;38;119;255|38;2;39;126;255|38;2;41;132;255|38;2;43;138;255|38;2;44;144;255|38;2;45;150;255|38;2;46;155;255|38;2;47;161;255|38;2;48;167;255|38;2;49;173;255|38;2;51;179;255|38;2;53;184;255|38;2;55;190;255|38;2;58;195;255|38;2;61;201;255|38;2;63;206;255|38;2;66;211;255|38;2;68;217;255|38;2;74;221;255|38;2;83;224;255|38;2;93;227;255|38;2;102;229;255|38;2;112;232;255|38;2;121;235;255|38;2;130;238;255|38;2;135;236;255|38;2;120;216;255|38;2;105;196;255|38;2;90;176;255|38;2;76;155;255|38;2;61;135;255|38;2;46;115;255', '38;2;127;109;255|38;2;131;113;255|38;2;135;118;255|38;2;140;122;255|38;2;144;126;255|38;2;148;131;255|38;2;152;135;255|38;2;156;139;255|38;2;161;145;255|38;2;167;152;255|38;2;172;158;255|38;2;177;164;255|38;2;182;171;255|38;2;188;177;255|38;2;193;183;255|38;2;198;190;255|38;2;203;197;255|38;2;208;204;255|38;2;214;211;255|38;2;219;217;255|38;2;224;224;255|38;2;229;231;255|38;2;229;233;255|38;2;220;227;255|38;2;211;221;255|38;2;202;215;255|38;2;194;209;255|38;2;185;203;255|38;2;176;197;255|38;2;168;190;255|38;2;162;178;255|38;2;156;167;255|38;2;150;155;255|38;2;145;144;255|38;2;139;132;255|38;2;133;121;255', '38;2;255;78;46|38;2;255;83;46|38;2;255;87;46|38;2;255;92;46|38;2;255;96;46|38;2;255;101;46|38;2;255;106;46|38;2;255;110;46|38;2;255;115;47|38;2;255;120;49|38;2;255;124;51|38;2;255;129;52|38;2;255;134;54|38;2;255;138;56|38;2;255;143;57|38;2;255;148;60|38;2;255;152;64|38;2;255;156;68|38;2;255;161;72|38;2;255;165;76|38;2;255;169;80|38;2;255;173;84|38;2;255;173;84|38;2;255;166;81|38;2;255;160;77|38;2;255;153;73|38;2;255;146;69|38;2;255;139;65|38;2;255;132;61|38;2;255;126;58|38;2;255;119;56|38;2;255;112;54|38;2;255;105;53|38;2;255;98;51|38;2;255;92;49|38;2;255;85;48', '38;2;255;79;158|38;2;255;85;162|38;2;255;92;165|38;2;255;98;169|38;2;255;104;172|38;2;255;110;176|38;2;255;117;180|38;2;255;123;183|38;2;255;129;187|38;2;255;135;190|38;2;255;140;193|38;2;255;146;196|38;2;255;152;199|38;2;255;158;203|38;2;255;164;206|38;2;255;169;205|38;2;255;173;201|38;2;255;178;197|38;2;255;182;194|38;2;255;186;190|38;2;255;191;186|38;2;255;195;182|38;2;255;195;181|38;2;255;187;182|38;2;255;180;184|38;2;255;172;186|38;2;255;164;187|38;2;255;157;189|38;2;255;149;191|38;2;255;141;191|38;2;255;132;186|38;2;255;123;182|38;2;255;115;177|38;2;255;106;172|38;2;255;97;167|38;2;255;88;163', '38;2;0;184;132|38;2;5;188;136|38;2;9;193;139|38;2;14;197;143|38;2;19;202;146|38;2;24;206;150|38;2;28;211;154|38;2;33;215;157|38;2;41;219;162|38;2;49;222;167|38;2;57;225;171|38;2;66;229;176|38;2;74;232;181|38;2;82;235;185|38;2;91;239;190|38;2;91;238;194|38;2;87;234;197|38;2;82;231;200|38;2;78;227;203|38;2;74;223;206|38;2;69;220;209|38;2;65;216;212|38;2;60;212;211|38;2;54;208;205|38;2;49;204;199|38;2;43;200;192|38;2;38;196;186|38;2;32;192;180|38;2;26;187;173|38;2;21;184;167|38;2;18;184;162|38;2;15;184;157|38;2;12;184;152|38;2;9;184;147|38;2;6;184;142|38;2;3;184;137')
$LegendDecoTrue = @('38;2;251;86;86|38;2;251;227;86|38;2;133;251;86|38;2;86;251;180|38;2;86;180;251|38;2;133;86;251|38;2;251;86;227', '38;2;251;86;86|38;2;251;227;86|38;2;133;251;86|38;2;86;251;180|38;2;86;180;251|38;2;133;86;251|38;2;251;86;227', '38;2;255;240;74|38;2;255;184;0', '38;2;251;86;86|38;2;251;227;86|38;2;133;251;86|38;2;86;251;180|38;2;86;180;251|38;2;133;86;251|38;2;251;86;227', '38;2;251;86;86|38;2;251;227;86|38;2;133;251;86|38;2;86;251;180|38;2;86;180;251|38;2;133;86;251|38;2;251;86;227')
$LegendTalkTrue = @('38;2;51;181;255', '38;2;185;178;255', '38;2;255;145;58', '38;2;255;143;192', '38;2;63;224;176')
$LegendRamp256 = @('38;5;27|38;5;27|38;5;27|38;5;27|38;5;33|38;5;33|38;5;33|38;5;33|38;5;33|38;5;33|38;5;39|38;5;39|38;5;75|38;5;75|38;5;75|38;5;75|38;5;75|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;123|38;5;123|38;5;123|38;5;117|38;5;81|38;5;75|38;5;75|38;5;69|38;5;33', '38;5;99|38;5;99|38;5;105|38;5;105|38;5;105|38;5;105|38;5;105|38;5;141|38;5;141|38;5;141|38;5;147|38;5;147|38;5;147|38;5;147|38;5;147|38;5;183|38;5;189|38;5;189|38;5;189|38;5;189|38;5;189|38;5;189|38;5;189|38;5;189|38;5;189|38;5;189|38;5;153|38;5;153|38;5;153|38;5;147|38;5;147|38;5;147|38;5;111|38;5;105|38;5;105|38;5;105', '38;5;202|38;5;202|38;5;202|38;5;202|38;5;202|38;5;202|38;5;202|38;5;202|38;5;208|38;5;209|38;5;209|38;5;209|38;5;209|38;5;209|38;5;209|38;5;209|38;5;209|38;5;215|38;5;215|38;5;215|38;5;215|38;5;215|38;5;215|38;5;215|38;5;215|38;5;209|38;5;209|38;5;209|38;5;209|38;5;209|38;5;209|38;5;203|38;5;203|38;5;203|38;5;203|38;5;203', '38;5;205|38;5;205|38;5;205|38;5;205|38;5;205|38;5;205|38;5;211|38;5;211|38;5;211|38;5;211|38;5;211|38;5;212|38;5;212|38;5;218|38;5;218|38;5;218|38;5;218|38;5;218|38;5;217|38;5;217|38;5;217|38;5;223|38;5;223|38;5;217|38;5;217|38;5;217|38;5;217|38;5;217|38;5;211|38;5;211|38;5;211|38;5;211|38;5;211|38;5;205|38;5;205|38;5;205', '38;5;36|38;5;36|38;5;36|38;5;42|38;5;42|38;5;42|38;5;42|38;5;43|38;5;43|38;5;79|38;5;79|38;5;79|38;5;79|38;5;85|38;5;85|38;5;85|38;5;80|38;5;80|38;5;80|38;5;80|38;5;80|38;5;80|38;5;80|38;5;80|38;5;80|38;5;43|38;5;43|38;5;37|38;5;37|38;5;37|38;5;37|38;5;37|38;5;36|38;5;36|38;5;36|38;5;36')
$LegendDeco256 = @('38;5;203|38;5;221|38;5;119|38;5;85|38;5;75|38;5;99|38;5;206', '38;5;203|38;5;221|38;5;119|38;5;85|38;5;75|38;5;99|38;5;206', '38;5;227|38;5;214', '38;5;203|38;5;221|38;5;119|38;5;85|38;5;75|38;5;99|38;5;206', '38;5;203|38;5;221|38;5;119|38;5;85|38;5;75|38;5;99|38;5;206')
$LegendTalk256 = @('38;5;75', '38;5;147', '38;5;209', '38;5;211', '38;5;79')
$LegendSides = @('R', 'LR', 'LR', 'LR', 'R')

$MascotTiers = @('common', 'uncommon', 'rare', 'unique', 'legend')

# The mascot only speaks while a turn runs, right after one ends, and when
# something is waiting on you. The rest of the time it just sits there. The
# jokes live in the working lines only, in each tier's manner of speaking.
$TalkWork = @{
    common = @('영차영차, 하는 중이에요!', '꼼지락꼼지락 열심히!', '조금만 기다려 줘요!', '코드 냠냠 먹는 중이에요')
    uncommon = @('꼬리 흔들면서 일하는 중!', '집중 집중! 금방 끝낼게요', '하나씩 꼭꼭 챙기고 있어요', '끝나면 간식 주실 거죠?')
    rare = @('차근차근 살펴보는 중이에요', '어디가 아픈지 꼼꼼히 보고 있어요', '제일 빠른 닭은? 후다닭!', '개가 사람을 가르치면? 개인지도!')
    unique = @('반짝반짝 정리하는 중이에요!', '예쁘게 마무리하고 있어요', '오리를 생으로 먹으면? 회오리!', '왕이 넘어지면? 킹콩!')
    legend = @('물고기의 반대말은? 불고기!', '제일 빠른 새는? 눈 깜짝할 새!', '가장 억울한 도형은? 원통!', '소금이 죽으면? 죽염!', '천천히, 그래도 확실하게!')
    dev = @('빌드 도는 중.', '컴파일 중.', '테스트 도는 중.')
}
$TalkDone = @{
    common = @('다 했어요!', '짠! 끝났어요!', '헤헤, 완성이에요!')
    uncommon = @('짜잔, 다 끝냈어요!', '깔끔하게 해 놨어요, 칭찬해 줘요!', '완성! 확인해 볼래요?')
    rare = @('다 됐어요, 꼼꼼히 봤어요!', '해냈어요! 한번 볼래요?')
    unique = @('다 끝냈어요, 자신 있어요!', '완벽하게 해 놨어요!')
    legend = @('부탁한 거 전부 끝냈어요!', '다 됐어요, 확인해 줄래요?')
    dev = @('빌드 통과.', '커밋하시죠.', '배포 준비 완료.', '테스트 전부 초록불.')
}
$TalkNotify = @{
    common = @('저기요오, 봐 줄래요?', '여기 좀 봐 줘요!')
    uncommon = @('잠깐만요, 물어볼 게 있어요!', '이것 좀 같이 봐 줄래요?')
    rare = @('확인이 필요해요, 봐 줄래요?', '같이 정해야 할 게 있어요!')
    unique = @('잠깐 봐 줄 수 있어요?', '여기 확인이 필요해요!')
    legend = @('잠깐 확인해 줄래요?', '같이 봐야 할 게 있어요!')
    dev = @('입력 대기 중.', '확인 요망.')
}
$TalkError = @('앗, 넘어졌어요…', '으앙, 실패했어요…')
# What a freshly drawn mascot says, in its tier's manner of speaking.
$Intro = @{
    common = '"뿅! 나 {0}!"'
    uncommon = '"안녕! 나는 {0}, 잘 부탁해!"'
    rare = '"반가워요! 제 이름은 {0}!"'
    unique = '"짜잔! {0} 등장이에요!"'
    legend = '"드디어 만났네요! 나는 {0}, 오늘 하루 잘 부탁해요!"'
    dev = '"{0}. 로그인 완료."'
}

# The face string of a tier, or $null for a tier that does not exist.
function Get-Pool {
    param([string]$Tier)
    switch ($Tier) {
        'common'   { return $KaoCommon }
        'uncommon' { return $KaoUncommon }
        'rare'     { return $KaoRare }
        'unique'   { return $KaoUnique }
        'legend'   { return $KaoLegend }
        'dev'      { return $KaoDev }
    }
    return $null
}

function Get-Names {
    param([string]$Tier)
    switch ($Tier) {
        'common'   { return $NameCommon }
        'uncommon' { return $NameUncommon }
        'rare'     { return $NameRare }
        'unique'   { return $NameUnique }
        'legend'   { return $NameLegend }
        'dev'      { return $NameDev }
    }
    return ''
}

# The faces of a tier as an array of frame strings ("frame#frame").
function Get-Faces {
    param([string]$Tier)
    $pool = Get-Pool $Tier
    if ([string]::IsNullOrEmpty($pool)) { return @() }
    return ,($pool.Split('|'))
}

function Get-Frames {
    param([string]$Face)
    return ,($Face.Split('#'))
}

# The per-machine key. mascot-hook.ps1 creates it once with a CSPRNG; no key
# means no mascot, which is also what a fresh install looks like.
function Get-GachaKey {
    try { return [System.IO.File]::ReadAllText("$CacheDir\.gacha-key").Trim() } catch { return '' }
}

# HMAC-SHA256 of a message under the machine key, as lowercase hex.
function Get-Hmac {
    param([string]$Key, [string]$Message)

    $hmac = $null
    try {
        $hmac = [System.Security.Cryptography.HMACSHA256]::new()
        $hmac.Key = [Text.Encoding]::UTF8.GetBytes($Key)
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message))
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    } catch {
        return ''
    } finally {
        if ($null -ne $hmac) { $hmac.Dispose() }
    }
}

# Whether this machine's key is one of the maintainer keys. Comparing hashes
# rather than keys is what lets the list ship in the open.
function Test-DevKey {
    param([string]$Key)

    if ($Key -eq '' -or $DevKeyHashes.Count -eq 0) { return $false }
    $sha = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key))
        $hex = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    } catch {
        return $false
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
    foreach ($h in $DevKeyHashes) {
        if ($hex -eq ([string]$h).Trim().ToLower()) { return $true }
    }
    return $false
}

# The roll on file: @{ Date; Epoch; Tier; Index } or $null when there is none.
# A bad signature reads as no roll at all, so an edited file loses the mascot
# rather than granting a better one. Index counts from 0, as in the sh version.
function Get-SavedRoll {
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText("$CacheDir\gacha.txt").Trim() } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $tok = $raw -split '\s+'
    if ($tok.Count -lt 6 -or $tok[0] -ne 'v1') { return $null }
    $key = Get-GachaKey
    if ($key -eq '') { return $null }

    $want = Get-Hmac $key "roll|v1|$($tok[1])|$($tok[2])|$($tok[3])|$($tok[4])"
    if ($want -eq '' -or $want -ne $tok[5]) { return $null }

    $faces = Get-Faces $tok[3]
    $idx = 0
    if (-not [int]::TryParse($tok[4], [ref]$idx)) { return $null }
    if ($faces.Count -eq 0 -or $idx -lt 0) { return $null }
    # A roll from a longer, older roster wraps onto the current one, so an
    # earlier draw keeps a face of its tier.
    $idx = $idx % $faces.Count

    $epoch = Get-Epoch $tok[2]
    if ($null -eq $epoch) { $epoch = 0 }
    return @{ Date = $tok[1]; Epoch = $epoch; Tier = $tok[3]; Index = $idx }
}

# One roll per calendar day. A stored roll stamped in the future means the
# clock moved backwards, and that does not earn another roll either.
function Test-CanRoll {
    param($Saved)

    if ($null -eq $Saved) { return $true }
    $today = ''
    try { $today = [DateTime]::Now.ToString('yyyyMMdd') } catch { return $false }
    if ($Saved.Date -eq $today) { return $false }
    if ($Now -gt 0 -and $Saved.Epoch -gt 0 -and $Now -lt $Saved.Epoch) { return $false }
    return $true
}

# Rolls once and stores the signed result. Returns the new roll, or $null when
# there is no key. The randomness is cryptographic, so the outcome is not
# predictable from the date or from previous rolls.
function Invoke-GachaRoll {
    param([string]$WantTier = '', [string]$WantFace = '')

    $key = Get-GachaKey
    if ($key -eq '') { return $null }

    # Picking a tier outright is a maintainer thing - it is how the faces get
    # looked at while working on them. Any other key is turned away here.
    if ($WantTier -ne '') {
        if (-not (Test-DevKey $key)) { return @{ Denied = $true } }
        if ($null -eq (Get-Pool $WantTier)) { return @{ BadTier = $true } }
    }

    $raw = [byte[]]::new(8)
    $rng = $null
    try {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($raw)
    } catch {
        return $null
    } finally {
        if ($null -ne $rng) { $rng.Dispose() }
    }

    $n1 = ([long]$raw[0] * 16777216) + ([long]$raw[1] * 65536) + ([long]$raw[2] * 256) + [long]$raw[3]
    $n2 = ([long]$raw[4] * 16777216) + ([long]$raw[5] * 65536) + ([long]$raw[6] * 256) + [long]$raw[7]

    # A maintainer key adds the dev tier in front; the ordinary tiers then share
    # what is left of the 1000, keeping their ratio to each other. Whatever the
    # rounding leaves over goes to dev, so the odds still total exactly 1000.
    $tiers = $MascotTiers
    $odds = $MascotOdds
    if (Test-DevKey $key) {
        $scaled = @{}
        $used = 0
        foreach ($t in $MascotTiers) {
            $v = [int][Math]::Floor([double]$MascotOdds[$t] * (1000 - $DevOdds) / 1000)
            $scaled[$t] = $v
            $used += $v
        }
        $scaled['dev'] = 1000 - $used
        $tiers = @('dev') + $MascotTiers
        $odds = $scaled
    }

    $roll = [int]($n1 % 1000)
    $tier = $tiers[0]
    $acc = 0
    foreach ($t in $tiers) {
        $acc += [int]$odds[$t]
        if ($roll -lt $acc) { $tier = $t; break }
    }
    if ($WantTier -ne '') { $tier = $WantTier }

    $faces = Get-Faces $tier
    $idx = 0
    if ($faces.Count -gt 0) { $idx = [int]($n2 % $faces.Count) }

    # A named face (or its 1-based number) goes with a chosen tier, so the
    # maintainer can wear each one in turn while working on them.
    if ($WantTier -ne '' -and $WantFace -ne '') {
        $names = (Get-Names $tier).Split('|')
        $pick = -1
        $num = 0
        if ([int]::TryParse($WantFace, [ref]$num)) {
            if ($num -ge 1 -and $num -le $faces.Count) { $pick = $num - 1 }
        } else {
            for ($k = 0; $k -lt $names.Count; $k++) {
                if ($names[$k] -eq $WantFace) { $pick = $k; break }
            }
        }
        if ($pick -lt 0) { return @{ BadFace = $true; Names = $names } }
        $idx = $pick
    }

    $today = [DateTime]::Now.ToString('yyyyMMdd')
    $stamp = $Now
    if ($stamp -le 0) { $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $sig = Get-Hmac $key "roll|v1|$($today)|$($stamp)|$($tier)|$($idx)"
    if ($sig -eq '') { return $null }

    try {
        [void][System.IO.Directory]::CreateDirectory($CacheDir)
        [System.IO.File]::WriteAllText("$CacheDir\gacha.txt", "v1 $($today) $($stamp) $($tier) $($idx) $($sig)")
    } catch {
        return $null
    }
    return @{ Date = $today; Epoch = $stamp; Tier = $tier; Index = $idx }
}

# Flat tier color. Legend uses this only when colors are switched off.
function Get-TierColor {
    param([string]$Tier)

    switch ($Tier) {
        'legend'   { return $CLegend }
        'dev'      { return $CDev }
        'unique'   { return $CUnique }
        'rare'     { return $CRare }
        'uncommon' { return $CUncommon }
        default    { return $CCommon }
    }
}

# The colours of a legend (counted from 0) as an array of SGR colour
# parameters, taken from the precomputed tables above (24-bit or 256-colour,
# per LegendTrueColor): Kind 'ramp' is the body, 'deco' the decorations.
$script:LegendCache = @{}
function Get-LegendColors {
    param([string]$Kind, [int]$Index)

    $k = "$Kind$Index"
    if ($script:LegendCache.ContainsKey($k)) { return $script:LegendCache[$k] }
    $table = $LegendRamp256
    if ($Kind -eq 'deco') { $table = $LegendDeco256 }
    if ($LegendTrueColor) {
        $table = $LegendRampTrue
        if ($Kind -eq 'deco') { $table = $LegendDecoTrue }
    }
    $codes = ([string]$table[$Index % $table.Count]).Split('|')
    $script:LegendCache[$k] = $codes
    return $codes
}

# The flash colour for a cell: the palette's lightest colour, or its darkest
# where the cell is already pale, so the twinkle shows without going white.
function Get-Flash {
    param([string]$Code, [string]$Darkest, [string]$Lightest)
    if ($Code.StartsWith('38;2;')) {
        $p = $Code.Split(';')
        $lum = ([int]$p[2] * 299 + [int]$p[3] * 587 + [int]$p[4] * 114) / 1000
        if ($lum -gt 170) { return $Darkest }
    }
    return $Lightest
}

# Paints a legend face with its whole palette, darkest at the edges and
# lightest in the middle, and makes a few characters flash. Which ones is
# decided by a small integer hash of the clock and the position, so both
# implementations agree exactly; Seed -1 means "now", any other seed gives a
# fixed picture. The decorations at the sides the legend names (L and/or R)
# take their own colours instead: a rainbow turns with the seed and its two
# sides sit half a turn apart, a pair (the bolts' yellows) stays put, one
# colour per side.
function Get-GradientText {
    param([string]$Text, [int]$Index, [long]$Seed = -1)

    if ([string]::IsNullOrEmpty($Reset) -or $Text.Length -eq 0) { return $Text }
    $ramp = Get-LegendColors 'ramp' $Index
    $deco = Get-LegendColors 'deco' $Index
    $sides = [string]$LegendSides[$Index % $LegendSides.Count]
    $n = $ramp.Count
    $nd = $deco.Count
    $shift = [int][Math]::Floor($nd / 2)
    $len = $Text.Length
    $lo = 0
    $hi = [int][Math]::Floor($n / 2)
    if ($Seed -lt 0) { $Seed = 0; if ($Now -gt 0) { $Seed = $Now % 1000003 } }
    $rot = 0
    if ($nd -gt 2) { $rot = $Seed }

    $slot = 0
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $len; $i++) {
        # 0 at both edges, 1 in the middle, then stretched over lo..hi
        $d = [Math]::Abs(2 * $i - ($len - 1))
        $idx = $hi
        if ($len -gt 1) { $idx = $hi - [int][Math]::Floor(($hi - $lo) * $d / ($len - 1)) }
        $code = $ramp[$idx]
        if ($SparkleEvery -gt 0) {
            $x = ($Seed * 31 + $i * 7 + 13) % 2147483647
            $x = ($x * 48271) % 2147483647
            $x = ($x * 48271) % 2147483647
            if (($x % $SparkleEvery) -eq 0) { $code = Get-Flash $code $ramp[0] $ramp[$hi] }
        }
        if ($nd -gt 0 -and (($i -eq 0 -and $sides.Contains('L')) -or ($i -eq $len - 1 -and $sides.Contains('R')))) {
            $code = $deco[($rot + $slot * $shift) % $nd]
            $slot++
        }
        [void]$sb.Append($Esc).Append('[').Append($code).Append('m').Append($Text[$i])
    }
    return $sb.ToString()
}

# Wraps a face (and an optional spoken line, one space to its right) in the
# right paint for its tier: legend wears its ramp and coloured decorations
# and speaks in its own colour, every other tier takes one flat colour. The
# line never twinkles.
function Write-TierText {
    param([string]$Tier, [string]$Text, [int]$Index = 0, [long]$Seed = -1, [string]$Talk = '')

    if ($Tier -eq 'legend' -and -not [string]::IsNullOrEmpty($Reset)) {
        $out = "$(Get-GradientText $Text $Index $Seed)$($Reset)"
        if ($Talk -ne '') {
            $talkTable = $LegendTalk256
            if ($LegendTrueColor) { $talkTable = $LegendTalkTrue }
            $out += " $($Esc)[$($talkTable[$Index % $talkTable.Count])m$($Talk)$($Reset)"
        }
        return $out
    }
    if ($Talk -ne '') { $Text += " $($Talk)" }
    return "$(Get-TierColor $Tier)$($Text)$($Reset)"
}

# Picks a line from a pool, seeded with the timestamp the hook recorded, so it
# holds steady across redraws and changes with the next turn.
function Get-Talk {
    param($Pool, [long]$Stamp)

    if (-not $ShowMascotTalk) { return '' }
    if ($null -eq $Pool -or $Pool.Count -eq 0) { return '' }
    $h = ($Stamp * 1103515245 + 12345) % 2147483648
    if ($h -lt 0) { $h = -$h }
    return $Pool[[int]($h % $Pool.Count)]
}

# Draws the face for the current roll, animated by the turn state the hooks
# left for this session. Returns '' only when nothing has been rolled yet, so
# the line then looks exactly as it did before the mascot existed.
function Get-Mascot {
    param([string]$SidKey)

    # The face is the machine-wide roll, so it shows in every session from the
    # first redraw. The state file only adds what the turn is doing; until the
    # hooks write one the mascot simply sits idle.
    $state = 'idle'
    $stamp = 0
    if (-not [string]::IsNullOrWhiteSpace($SidKey)) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText("$CacheDir\mascot-$($SidKey).txt").Trim() } catch { $raw = '' }
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $tok = $raw -split '\s+'
            $state = $tok[0]
            if ($tok.Count -ge 2) {
                $parsed = Get-Epoch $tok[1]
                if ($null -ne $parsed) { $stamp = $parsed }
            }
        }
    }

    $draw = Get-SavedRoll
    if ($state -eq 'error') {
        $frames = Get-Frames $KaoError
        $frame = 0
        if ($Now -gt 0) { $frame = [int]([Math]::Floor($Now / $AnimSecs) % $frames.Count) }
        $text = $frames[$frame]
        $talk = Get-Talk $TalkError $stamp
        if ($talk -ne '') { $text += " $($talk)" }
        return "$($CCrit)$($text)$($Reset)"
    }
    if ($null -eq $draw) { return '' }

    $working = ($state -eq 'working')
    $faces = Get-Faces $draw.Tier
    $frames = Get-Frames $faces[$draw.Index]
    $frame = 0
    if ($working -and $Now -gt 0 -and $frames.Count -gt 0) {
        $frame = [int]([Math]::Floor($Now / $AnimSecs) % $frames.Count)
    }
    $text = $frames[$frame]

    # Speaks while working, for a short while after finishing, and whenever
    # something is waiting on you. Otherwise it stays quiet.
    $talk = ''
    if ($working) {
        $talk = Get-Talk $TalkWork[$draw.Tier] $stamp
    } elseif ($state -eq 'notify') {
        $talk = Get-Talk $TalkNotify[$draw.Tier] $stamp
    } elseif ($state -eq 'done') {
        if ($Now -le 0 -or $stamp -le 0 -or ($Now - $stamp) -le $TalkWindowSecs) {
            $talk = Get-Talk $TalkDone[$draw.Tier] $stamp
        }
    }
    return (Write-TierText $draw.Tier $text $draw.Index -1 $talk)
}
# ---- subcommands -----------------------------------------------------------
# None of these read stdin, so they work from a plain prompt.

# Prints one roll as "（・ω・）  Kitten  [커먼 1/12]", name and tier included.
function Show-Draw {
    param($Draw)

    $label = @{
        common = '커먼'; uncommon = '언커먼'; rare = '레어'
        unique = '유니크'; legend = '레전드'; dev = 'DEV'
    }[$Draw.Tier]
    $faces = Get-Faces $Draw.Tier
    $frames = Get-Frames $faces[$Draw.Index]
    $names = (Get-Names $Draw.Tier).Split('|')
    $name = ''
    if ($Draw.Index -lt $names.Count) { $name = $names[$Draw.Index] }

    Write-Output ("  {0}  {1}  [{2} {3}/{4}]" -f (Write-TierText $Draw.Tier $frames[0] $Draw.Index 0),
        $name, $label, ($Draw.Index + 1), $faces.Count)
    if ($null -ne $Intro[$Draw.Tier]) { Write-Output ('  ' + ($Intro[$Draw.Tier] -f $name)) }
    Write-Output ("  표정 {0}장  {1}" -f $frames.Count, ($frames -join '  '))
}

if ($Help) {
    Write-Output "claude-statusline-astro $StatuslineVersion"
    Write-Output ''
    Write-Output '  statusline.ps1            Claude Code calls this with session JSON on stdin'
    Write-Output '  statusline.ps1 -Roll      오늘의 마스코트 뽑기 (하루 한 번)'
    Write-Output '  statusline.ps1 -Today     지금 쓰고 있는 마스코트 보기'
    Write-Output '  statusline.ps1 -Version   버전 보기'
    Write-Output '  statusline.ps1 -Help      이 도움말'
    Write-Output ''
    Write-Output '뽑기는 하루 한 번이고, 뽑기 전까지 지금 마스코트가 그대로 유지됩니다.'
    Write-Output ''
    Write-Output '  statusline.ps1 -Roll -Tier legend               등급 지정 (메인테이너 키 전용)'
    Write-Output '  statusline.ps1 -Roll -Tier legend -Face Volt    얼굴 지정 (메인테이너 키 전용)'
    exit 0
}

if ($Version) {
    Write-Output "claude-statusline-astro $StatuslineVersion"
    exit 0
}

if ($Roll) {
    # 등급을 직접 고르는 건 메인테이너 키에서만 됩니다.
    if ($Tier -ne '') {
        $forced = Invoke-GachaRoll $Tier $Face
        if ($null -eq $forced) {
            Write-Output '지정에 실패했습니다.'
            exit 1
        }
        if ($forced.Denied) {
            Write-Output '등급을 직접 고르는 건 메인테이너 키에서만 됩니다.'
            Write-Output '일반 사용자는 -Roll 로 하루 한 번 뽑습니다.'
            exit 1
        }
        if ($forced.BadTier) {
            Write-Output "그런 등급이 없습니다: $Tier"
            Write-Output '고를 수 있는 값: common uncommon rare unique legend dev'
            exit 1
        }
        if ($forced.BadFace) {
            Write-Output "그런 얼굴이 없습니다: $Face"
            Write-Output ("고를 수 있는 값: {0}" -f ($forced.Names -join ' '))
            exit 1
        }
        Write-Output "$Tier 등급으로 지정했습니다."
        Write-Output ''
        Write-Output '  뿅!'
        Show-Draw $forced
        exit 0
    }

    $saved = Get-SavedRoll
    if (-not (Test-CanRoll $saved)) {
        Write-Output '오늘 뽑기는 이미 사용했습니다. 내일 다시 뽑을 수 있어요.'
        Write-Output ''
        Show-Draw $saved
        exit 0
    }
    $new = Invoke-GachaRoll
    if ($null -eq $new) {
        Write-Output '뽑기에 실패했습니다. 턴을 한 번 끝내 비밀키가 만들어졌는지 확인해 주세요.'
        exit 1
    }
    Write-Output '오늘의 마스코트를 뽑았습니다!'
    Write-Output ''
    Write-Output '  뿅!'
    Show-Draw $new
    Write-Output ''
    Write-Output '다음 뽑기는 내일부터 가능합니다.'
    exit 0
}

if ($Today) {
    $saved = Get-SavedRoll
    if ($null -eq $saved) {
        Write-Output '아직 뽑은 마스코트가 없습니다. -Roll 로 뽑아 보세요.'
        exit 0
    }
    Write-Output ("지금 마스코트  (뽑은 날 {0})" -f $saved.Date)
    Write-Output ''
    Show-Draw $saved
    Write-Output ''
    if (Test-CanRoll $saved) {
        Write-Output '오늘 뽑기가 남아 있습니다. -Roll 로 새로 뽑을 수 있어요.'
    } else {
        Write-Output '오늘 뽑기는 사용했습니다. 내일 다시 뽑을 수 있어요.'
    }
    exit 0
}

# Records the last failure in the cache directory. Nothing may reach stderr,
# so this file is the only place a problem can be seen afterwards.
function Write-LastError {
    param($Err, [string]$Where)
    try {
        $msg = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) [$Where] $($Err.Exception.Message)`n$($Err.ScriptStackTrace)`n"
        [System.IO.File]::WriteAllText("$CacheDir\last-error.txt", $msg)
    } catch { }
}

# ---- payload fields --------------------------------------------------------
# The handful of fields this line needs are pulled with regular expressions
# rather than ConvertFrom-Json, which alone costs about 100 ms per redraw.

# A string field: the first "key": "value" in the payload, JSON escapes undone.
function Get-JsonStr {
    param([string]$Json, [string]$Key)
    $m = [regex]::Match($Json, '"' + [regex]::Escape($Key) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    if ($v.IndexOf('\') -ge 0) {
        $v = [regex]::Replace($v, '\\u([0-9a-fA-F]{4})', { param($mm) [string][char][Convert]::ToInt32($mm.Groups[1].Value, 16) })
        $v = $v.Replace('\"', '"').Replace('\/', '/').Replace('\\', '\')
    }
    return $v
}

# The body of "key": { ... }, found by scanning braces so nesting of any depth
# is fine, with the nested objects blanked out so a field lookup inside cannot
# land in one of them. A brace inside a string value (a path like "{proj}")
# would throw the scan off, so those are blanked first - only when one exists,
# since that pass is the expensive part.
function Get-JsonObj {
    param([string]$Json, [string]$Key)
    if ([regex]::IsMatch($Json, '(?<=[:,\[{]\s*)"(?:[^"\\]|\\.)*[{}](?:[^"\\]|\\.)*"')) {
        $Json = [regex]::Replace($Json, '"(?:[^"\\]|\\.)*"', { param($mm) $mm.Value.Replace('{', ' ').Replace('}', ' ') })
    }
    $at = $Json.IndexOf('"' + $Key + '"')
    if ($at -lt 0) { return $null }
    $open = $Json.IndexOf('{', $at)
    if ($open -lt 0) { return $null }
    $colon = $Json.IndexOf(':', $at)
    if ($colon -lt 0 -or $colon -gt $open) { return $null }
    $depth = 0
    $pos = $open
    while ($pos -lt $Json.Length) {
        $nextOpen = $Json.IndexOf('{', $pos)
        $nextClose = $Json.IndexOf('}', $pos)
        if ($nextClose -lt 0) { return $null }
        if ($nextOpen -ge 0 -and $nextOpen -lt $nextClose) {
            $depth++
            $pos = $nextOpen + 1
        } else {
            $depth--
            $pos = $nextClose + 1
            if ($depth -eq 0) {
                $body = $Json.Substring($open + 1, $nextClose - $open - 1)
                if ($body.IndexOf('{') -ge 0) { $body = [regex]::Replace($body, '\{[^{}]*\}', '') }
                return $body
            }
        }
    }
    return $null
}

# A numeric field inside an already extracted object body.
function Get-JsonNum {
    param([string]$Body, [string]$Key)
    if ($null -eq $Body) { return $null }
    $m = [regex]::Match($Body, '"' + [regex]::Escape($Key) + '"\s*:\s*(-?[0-9][0-9.]*)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

try {
    $raw = $null
    try { $raw = [Console]::In.ReadToEnd() } catch { $raw = $null }
    if ($null -eq $raw) { $raw = '' }

    $dir = $null
    $workspace = Get-JsonObj $raw 'workspace'
    if ($null -ne $workspace) { $dir = Get-JsonStr $workspace 'current_dir' }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-JsonStr $raw 'cwd' }

    $model = $null
    $modelObj = Get-JsonObj $raw 'model'
    if ($null -ne $modelObj) { $model = Get-JsonStr $modelObj 'display_name' }

    $effort = $null
    $effortObj = Get-JsonObj $raw 'effort'
    if ($null -ne $effortObj) { $effort = Get-JsonStr $effortObj 'level' }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = '-' }
    # The model as family and version only: "Opus 5.5 (1M context)" and
    # "claude-opus-5-5" both read opus5.5. A name with no family stays as it is.
    $low = [regex]::Replace($model.ToLowerInvariant(), '\([^)]*\)|\[[^\]]*\]', '').Replace('claude', '')
    $fam = [regex]::Match($low, '[a-z]+')
    if ($fam.Success) {
        $nums = @()
        foreach ($d in [regex]::Matches($low.Substring($fam.Index + $fam.Length), '[0-9]+')) {
            if ($nums.Count -ge 2 -or $d.Value.Length -gt 3) { break }
            $nums += $d.Value
        }
        $model = $fam.Value + ($nums -join '.')
    }

    # One git call answers everything: repository root, branch, and the short
    # hash for a detached HEAD. A missing git or a directory outside any
    # repository both fall through with nothing set.
    $branch = ''
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($dir) -and [System.IO.Directory]::Exists($dir)) {
        try {
            $lines = @(& git -C "$dir" rev-parse --show-toplevel --abbrev-ref HEAD --short HEAD 2>$null)
            if ($lines.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace([string]$lines[0])) {
                $root = ([string]$lines[0]).Trim()
            }
            if ($lines.Count -ge 2) {
                $b = ([string]$lines[1]).Trim()
                if ($b -eq 'HEAD' -and $lines.Count -ge 3) { $b = ([string]$lines[2]).Trim() }
                if (-not [string]::IsNullOrWhiteSpace($b)) { $branch = $b }
            }
        } catch { }
    }

    # Only the project root is shown. The full path is noise once you know
    # where you are, and the repository root is what identifies the session.
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $dir }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $project = '-'
    } else {
        $project = Get-LeafName -Path $root -Max $DirMax
    }

    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = '-'
        $cBranch = $Dim
    } elseif ($branch -eq 'main' -or $branch -eq 'master') {
        $cBranch = $CGitMain
    } else {
        $cBranch = $CGitOther
    }

    $ctxPct = Get-Pct (Get-JsonNum (Get-JsonObj $raw 'context_window') 'used_percentage')

    $five = Get-JsonObj $raw 'five_hour'
    $seven = Get-JsonObj $raw 'seven_day'
    $fiveU = Get-Pct (Get-JsonNum $five 'used_percentage')
    $fiveR = Get-Epoch (Get-JsonNum $five 'resets_at')
    $sevenU = Get-Pct (Get-JsonNum $seven 'used_percentage')
    $sevenR = Get-Epoch (Get-JsonNum $seven 'resets_at')

    $sessionId = Get-JsonStr $raw 'session_id'

    # ---- cross-session rate-limit sync -------------------------------------
    # The payload's rate_limits are a per-session snapshot frozen at that
    # session's last API response, so idle terminals drift apart and disagree
    # with the web usage page. Every session therefore publishes the snapshot
    # it was handed, and every session renders the best snapshot published by
    # anyone: the newest window wins, and within the same window the highest
    # reading wins, because account usage only rises while a window is open.
    #
    # Cache line format (one per session): "v1 <5h%> <5h_reset> <7d%> <7d_reset>"
    try { [void][System.IO.Directory]::CreateDirectory($CacheDir) } catch { }

    $sidKey = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$sessionId)) {
        $sidKey = ([string]$sessionId) -replace '[^a-zA-Z0-9]', ''
        if ($sidKey.Length -gt 8) { $sidKey = $sidKey.Substring(0, 8) }
    }

    if ($null -ne $fiveU -and $sidKey -ne '' -and [System.IO.Directory]::Exists($CacheDir)) {
        try {
            $fr = '-'; if ($null -ne $fiveR) { $fr = [string]$fiveR }
            $su = '-'; if ($null -ne $sevenU) { $su = [string]$sevenU }
            $sr = '-'; if ($null -ne $sevenR) { $sr = [string]$sevenR }
            [System.IO.File]::WriteAllText(
                "$CacheDir\rl-$sidKey.txt",
                "v1 $fiveU $fr $su $sr`n",
                ([System.Text.UTF8Encoding]::new($false)))
        } catch { }

        # Entries from long-dead sessions stop mattering once their window
        # closes; sweep anything untouched for two days. The sweep itself runs
        # at most once an hour, tracked by a marker file, so it costs nothing
        # on an ordinary redraw.
        try {
            $marker = "$CacheDir\.swept"
            $due = $true
            if ([System.IO.File]::Exists($marker)) {
                $due = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($marker)).TotalHours -ge 1
            }
            if ($due) {
                $cutoff = [DateTime]::UtcNow.AddHours(-48)
                foreach ($pattern in @('rl-*.txt', 'mascot-*.txt')) {
                    foreach ($f in [System.IO.Directory]::GetFiles($CacheDir, $pattern)) {
                        if ([System.IO.File]::GetLastWriteTimeUtc($f) -lt $cutoff) {
                            [System.IO.File]::Delete($f)
                        }
                    }
                }
                [System.IO.File]::WriteAllText($marker, '')
            }
        } catch { }
    }

    $best5U = $fiveU; $best5R = 0; if ($null -ne $fiveR) { $best5R = $fiveR }
    $best7U = $sevenU; $best7R = 0; if ($null -ne $sevenR) { $best7R = $sevenR }

    try {
        foreach ($f in [System.IO.Directory]::GetFiles($CacheDir, 'rl-*.txt')) {
            $parts = ''
            try { $parts = [System.IO.File]::ReadAllText($f).Trim() } catch { continue }
            $tok = $parts -split '\s+'
            if ($tok.Count -lt 5 -or $tok[0] -ne 'v1') { continue }

            $u5 = Get-Pct $tok[1]
            $r5 = Get-Epoch $tok[2]
            if ($null -eq $r5) { $r5 = 0 }
            if ($null -ne $u5) {
                if ($null -eq $best5U -or $r5 -gt $best5R) { $best5U = $u5; $best5R = $r5 }
                elseif ($r5 -eq $best5R -and $u5 -gt $best5U) { $best5U = $u5 }
            }

            $u7 = Get-Pct $tok[3]
            $r7 = Get-Epoch $tok[4]
            if ($null -eq $r7) { $r7 = 0 }
            if ($null -ne $u7) {
                if ($null -eq $best7U -or $r7 -gt $best7R) { $best7U = $u7; $best7R = $r7 }
                elseif ($r7 -eq $best7R -and $u7 -gt $best7U) { $best7U = $u7 }
            }
        }
    } catch { }

    # ---- output ------------------------------------------------------------
    $sep = "$($Dim) | $($Reset)"
    $out = "$($Dim)DIR$($Reset) $($CDir)$($project)$($Reset)"
    $out += "$($sep)$($Dim)GIT$($Reset) $($cBranch)$($branch)$($Reset)"
    $out += "$($sep)$($Dim)MODEL$($Reset) $($CModel)$($model)$($Reset)"
    # Effort as its first letters: L M H XH, and U for max.
    $effortAbbr = @{ low = 'L'; medium = 'M'; high = 'H'; xhigh = 'XH'; max = 'U' }
    if ($ShowEffort -and $null -ne $effort -and $effortAbbr.ContainsKey($effort)) {
        $out += "$($sep)$($Dim)EFFORT$($Reset) $($CEffort[$effort])$($effortAbbr[$effort])$($Reset)"
    }
    $out += "$($sep)$($Dim)CTX$($Reset) $(Get-Meter $ctxPct $null)"
    $out += "$($sep)$($Dim)5H$($Reset) $(Get-Meter $best5U $best5R)"
    if ($ShowSevenDay) {
        $out += "$($sep)$($Dim)7D$($Reset) $(Get-Meter $best7U $best7R)"
    }
    if ($ShowMascot) {
        try {
            $mascot = Get-Mascot $sidKey
            if ($mascot -ne '') { $out += " $($mascot)" }
        } catch {
            Write-LastError $_ 'mascot'
        }
    }

    [Console]::Out.WriteLine($out)
} catch {
    Write-LastError $_ 'line'
    [Console]::Out.WriteLine('DIR - | GIT - | MODEL - | CTX --% | 5H --%')
}
