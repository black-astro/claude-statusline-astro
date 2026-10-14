# Single source of truth for the mascot: faces, legend colours and effects,
# and what it says.
# Emits: sh/ps1 blocks, the plugin's mascot-data.ts, README tables, legend
# SVGs and docs/preview.html.
import sys, unicodedata, os, json

# tier -> [(name, [frames...])]
# Small, soft animals and spirits. Every face is one line, uses no combining
# marks, and keeps its ears, paws and outline in every frame; only the eyes or
# mouth change. Frame 0 is the resting face.
FACES = {
    'error': [('Oops', ['（；へ；）', '（；ㅅ；）'])],
    'common': [
        ('Kitten', ['ฅ^•ω•^ฅ', 'ฅ^–ω–^ฅ']),
        ('Puppy', ['U(˶•ﻌ•˶)U', 'U(˶˘ﻌ˘˶)U']),
        ('Chick', ['(˶•ө•˶)', '(˶–ө–˶)']),
        ('Boo', ['꒰˶•o•˶꒱', '꒰˶˘ᴗ˘˶꒱']),
        ('Hamster', ['(๑• ﻌ •๑)', '(๑– ﻌ –๑)']),
        ('Piglet', ['^(˶•(oo)•˶)^', '^(˶˘(oo)˘˶)^']),
    ],
    'uncommon': [
        ('Bunny', ['૮(˶•ㅅ•˶)ა', '૮(˶˘ㅅ˘˶)ა']),
        ('Teddy', ['ʕ(˶•ᴥ•˶)ʔ', 'ʕ(˶–ᴥ–˶)ʔ']),
        ('Penguin', ['(˶•⊖•˶)', '(˶–⊖–˶)']),
        ('Koala', ['◖(˶•●•˶)◗', '◖(˶–●–˶)◗']),
        ('Sprite', ['໒꒰˶•ᴗ•˶꒱১', '໒꒰˶˘ᴗ˘˶꒱১']),
    ],
    'rare': [
        ('Panda', ['ʕ˶◐ᴥ◑˶ʔ', 'ʕ˶●ᴥ●˶ʔ']),
        ('Owl', ['{˶ʘvʘ˶}', '{˶ʘv-˶}']),
        ('Otter', ['ʕ˶•ﻌ•˶ʔっ', 'ʕ˶˘ﻌ˘˶ʔっ']),
        ('Aloof', ['ฅ(˶¬ω¬˶)ฅ', 'ฅ(˶-ω-˶)ฅ']),
    ],
    'unique': [
        ('Sakura', ['❀૮(˶ᵔ ᵕ ᵔ˶)ა', '❀૮(˶- ᵕ -˶)ა']),
        ('Sweetheart', ['∪(˶ᵔ ᴥ ᵔ˶)∪♡', '∪(˶ᵕ ᴥ ᵕ˶)∪♡']),
        ('Songbird', ['ε(˶•ө•˶)з♪', 'ε(˶˘ө˘˶)з♪']),
    ],
    'legend': [
        ('Azure', ['༺(^˶•ᴗ•˶^)༻', '༺(^˶–ᴗ–˶^)༻', '༺(^˶•o•˶^)༻', '༺(^˶•ᴗ•˶^)༻']),
        ('Luna', ['ᵛ⎛⎝(˶•ⱅ•˶)⎠⎞ᵛ', 'ᵛ⎝⎛(˶•ⱅ•˶)⎞⎠ᵛ']),
        ('Volt', ['ϟฅ/ᐠ˶•ﻌ•˶ᐟ\ฅϟ', 'ϟฅ/ᐠ˶˘ﻌ˘˶ᐟ\ฅϟ', 'ϟฅ/ᐠ˶–ﻌ–˶ᐟ\ฅϟ', 'ϟฅ/ᐠ˶˘ﻌ˘˶ᐟ\ฅϟ']),
        ('Blaze', ['♨ฅʕ •ˊ ᴥ •ˋ ʔฅ♨', '♨ฅʕ ˊ• ᴥ ˋ• ʔฅ♨', '♨ฅʕ •ˊ ᴥ •ˋ ʔฅ♨', '♨ฅʕ ˊ• ᴥ ˋ• ʔฅ♨', '♨ฅʕ ◣ˋ‸ˊ◢ꐦ ʔฅ♨']),
        ('Mystic', ['☆ฅ^˶ᓀ ω ᓂ˶^ฅ✧', '☆ฅ^˶- ω -˶^ฅ✧', '☆ฅ^˶◕ ω ◕˶^ฅ✧', '☆ฅ^˶ᓀ ω ᓂ˶^ฅ✧']),
    ],
    'dev': [('Root', ['｛・ω・｝', '｛－ω－｝']), ('Sudo', ['⟨◕ᴗ◕⟩', '⟨◠ᴗ◠⟩']), ('Kernel', ['［◉_◉］', '［◉‸◉］']), ('Daemon', ['⟨◣_◢⟩', '⟨◢_◣⟩'])]}

# What each face is, for the README and the preview.
KIND = {
    'Kitten': '아기 고양이', 'Puppy': '강아지', 'Chick': '병아리', 'Boo': '꼬마 유령', 'Hamster': '햄스터', 'Piglet': '아기 돼지',
    'Bunny': '솜토끼', 'Teddy': '곰돌이', 'Penguin': '펭귄', 'Koala': '코알라', 'Sprite': '작은 정령',
    'Panda': '판다', 'Owl': '부엉이', 'Otter': '수달', 'Aloof': '도도한 고양이',
    'Sakura': '벚꽃 토끼', 'Sweetheart': '하트 강아지', 'Songbird': '노래 병아리',
    'Azure': '아기 청룡', 'Luna': '달빛 박쥐', 'Volt': '번개 여우', 'Blaze': '불곰', 'Mystic': '마법 고양이',
}

TIER_ORDER = ['common', 'uncommon', 'rare', 'unique', 'legend']
TIER_KO = {'common': '커먼', 'uncommon': '언커먼', 'rare': '레어', 'unique': '유니크', 'legend': '레전드'}

# Each legend, in FACES order. `ramp` is the body's colour family (the status
# line's gradient and the in-app body), `sides` says where its outside
# decorations sit (first and/or last character), and `effect` names how the
# in-app mascot animates it, each one different:
#   azure   water ripples, and every 3 s a rainbow breath sweeps the body
#   bat     dark with only red eyes; each thunder flash lights the whole bat;
#           the wings flap fast (⎛⎝ ⎠⎞ <-> ⎝⎛ ⎞⎠)
#   volt    the bolts strike like thunder in yellows, turning bold (ϟ -> Ϟ)
#           while they flash; the body flashes with them
#   blaze   every letter burns on its own flickering flame; a flare rolls
#           through the body every few seconds
#   aurora  violet, teal and pink waves weave through each other
# Faces with paws (ฅ) also lift one paw or both now and then.
# `deco` are the colours of the outside decorations when not the rainbow
# (volt's two yellow bolts, the bat swarm, the hot springs).
LEGEND_FX = [
    {'effect': 'azure', 'name': '무지개 숨결', 'theme': '#33b5ff', 'sides': 'LR',
     'ramp': ['#1f5fff', '#2b8bff', '#33b5ff', '#46dcff', '#8af0ff']},
    {'effect': 'bat', 'name': '번개 속 박쥐', 'theme': '#b48cff', 'sides': 'LR',
     'ramp': ['#5b3496', '#6a3fb0', '#8b5fd6', '#a77ff0', '#7a4cc4'], 'deco': ['#8b6bd6', '#c9b0ff']},
    {'effect': 'volt', 'name': '천둥 번개', 'theme': '#ff913a', 'sides': 'LR',
     'ramp': ['#ff4e2e', '#ff6f2e', '#ff913a', '#ffb056', '#ff7f3a'], 'deco': ['#fff04a', '#ffb800']},
    {'effect': 'blaze', 'name': '활활 불꽃', 'theme': '#ff5a3c', 'sides': 'LR',
     'ramp': ['#d8240f', '#ff4a1c', '#ff7a1f', '#ffa733', '#ffd060'], 'deco': ['#ff7a1f', '#ffb43a']},
    {'effect': 'aurora', 'name': '오로라', 'theme': '#9d8cff', 'sides': 'LR',
     'ramp': ['#7b4dff', '#3fe0d0', '#ff6ad5', '#3fe0d0', '#7b4dff']},
]
LEGEND_DESC = {
    'azure': '파란 몸에 물결이 일렁이고, 3초마다 무지개 숨결이 몸을 훑고 지나갑니다',
    'bat': '어둠 속에 빨간 눈만 빛나다가 천둥이 칠 때마다 박쥐와 양옆 박쥐 떼가 드러나고, 날개가 빠르게 파닥입니다',
    'volt': '양옆 번개가 노랗게 불규칙하게 치고, 칠 때마다 굵은 번개 Ϟ 로 바뀌며 몸이 하얗게 번쩍입니다. 가끔 발바닥을 들어 올립니다',
    'blaze': '글자마다 불꽃이 일렁이고 몇 초마다 불길이 몸을 훑고 지나갑니다. 가끔 발바닥을 들어 올립니다',
    'aurora': '보라, 청록, 분홍 물결이 서로 엮이며 흐릅니다. 가끔 발바닥을 들어 올립니다',
}
GRADIENT_STEPS = 36

# Plain tiers wear one colour each, as xterm-256 cells.
FLAT_CELLS = {'common': 253, 'uncommon': 120, 'rare': 117, 'unique': 141, 'dev': 51, 'error': 203}


def ramp(keys, n=GRADIENT_STEPS):
    """n cells around a closed loop through the keyframes."""
    m = len(keys)
    rgb = [tuple(int(k.lstrip('#')[i:i + 2], 16) for i in (0, 2, 4)) for k in keys]
    out = []
    for s in range(n):
        pos = s * m / n
        seg = int(pos)
        t = pos - seg
        a, b = rgb[seg], rgb[(seg + 1) % m]
        out.append('#%02x%02x%02x' % tuple(int(a[c] + (b[c] - a[c]) * t + 0.5) for c in range(3)))
    return out


def cw(ch, amb):
    e = unicodedata.east_asian_width(ch)
    if e in ('W', 'F'):
        return 2
    if e == 'A':
        return amb
    return 1


def width(s, amb=1):
    return sum(cw(c, amb) for c in s)


def validate():
    ok = True
    for tier, faces in FACES.items():
        for name, frames in faces:
            for f in frames:
                assert '|' not in f and '#' not in f and "'" not in f, (tier, name)
                assert all(ord(c) <= 0xFFFF for c in f), (tier, name, 'non-BMP')
                if any(unicodedata.combining(c) for c in f):
                    ok = False
                    print('COMBINING', tier, name, f)
            w1 = {width(f, 1) for f in frames}
            w2 = {width(f, 2) for f in frames}
            if len(w1) != 1 or len(w2) != 1:
                ok = False
                print('JITTER', tier, name, [(width(f, 1), width(f, 2)) for f in frames])
    names = [n for t in FACES for n, _ in FACES[t]]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        ok = False
        print('DUPLICATE NAMES', dup)
    for t in TIER_ORDER:
        for n, _ in FACES[t]:
            if n not in INTRO:
                ok = False
                print('NO INTRO', n)
    if len(LEGEND_FX) != len(FACES['legend']):
        ok = False
        print('LEGEND_FX does not match the legends')
    return ok


# ---- colour ------------------------------------------------------------------

def _rgb2hsl(r, g, b):
    r, g, b = r / 255, g / 255, b / 255
    M, m = max(r, g, b), min(r, g, b)
    h = s = 0.0
    l = (M + m) / 2
    if M != m:
        d = M - m
        s = d / (2 - M - m) if l > .5 else d / (M + m)
        if M == r:
            h = (g - b) / d + (6 if g < b else 0)
        elif M == g:
            h = (b - r) / d + 2
        else:
            h = (r - g) / d + 4
        h *= 60
    return h, s, l


def _hsl2hex(h, s, l):
    h = h % 360
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs((h / 60) % 2 - 1))
    m = l - c / 2
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(h // 60) % 6]
    return '#%02x%02x%02x' % tuple(max(0, min(255, int((v + m) * 255 + 0.5))) for v in (r, g, b))


# Seven rainbow hues for the status line's decorations; the in-app mascot
# turns the full wheel instead.
RAINBOW = [_hsl2hex(k * 360 / 7, 0.95, 0.66) for k in range(7)]


def deco_colors(fx):
    return fx.get('deco') or RAINBOW


def cube_index(r, g, b):
    """Nearest cell of the xterm 6x6x6 cube, same rule as the scripts' fallback."""
    def q(v):
        if v < 48:
            return 0
        if v < 115:
            return 1
        return int((v - 35) / 40)
    return 16 + 36 * q(r) + 6 * q(g) + q(b)


def codes_of(hexes, true_color):
    out = []
    for h in hexes:
        r, g, b = int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)
        out.append('38;2;%d;%d;%d' % (r, g, b) if true_color else '38;5;%d' % cube_index(r, g, b))
    return out


XTERM = None


def xterm_hex(n):
    global XTERM
    if XTERM is None:
        base = ['000000', '800000', '008000', '808000', '000080', '800080', '008080', 'c0c0c0',
                '808080', 'ff0000', '00ff00', 'ffff00', '0000ff', 'ff00ff', '00ffff', 'ffffff']
        XTERM = ['#' + b for b in base]
        steps = [0, 95, 135, 175, 215, 255]
        for r in steps:
            for g in steps:
                for b in steps:
                    XTERM.append('#%02x%02x%02x' % (r, g, b))
        for i in range(24):
            v = 8 + i * 10
            XTERM.append('#%02x%02x%02x' % (v, v, v))
    return XTERM[n]


# ---- talk ------------------------------------------------------------------
# A soft baby-animal friend that talks well: short, warm lines, a little
# more articulate with each tier. Legends tell riddles straight away.

# What the status line scripts say, by tier.
SCRIPT_TALK = {
    'work': {
        'common': ['영차영차, 하는 중이에요!', '꼼지락꼼지락 열심히!', '조금만 기다려 줘요!', '코드 냠냠 먹는 중이에요'],
        'uncommon': ['꼬리 흔들면서 일하는 중!', '집중 집중! 금방 끝낼게요', '하나씩 꼭꼭 챙기고 있어요', '끝나면 간식 주실 거죠?'],
        'rare': ['차근차근 살펴보는 중이에요', '어디가 아픈지 꼼꼼히 보고 있어요', '제일 빠른 닭은? 후다닭!', '개가 사람을 가르치면? 개인지도!'],
        'unique': ['반짝반짝 정리하는 중이에요!', '예쁘게 마무리하고 있어요', '오리를 생으로 먹으면? 회오리!', '왕이 넘어지면? 킹콩!'],
        'legend': ['물고기의 반대말은? 불고기!', '제일 빠른 새는? 눈 깜짝할 새!', '가장 억울한 도형은? 원통!', '소금이 죽으면? 죽염!', '천천히, 그래도 확실하게!'],
        'dev': ['빌드 도는 중.', '컴파일 중.', '테스트 도는 중.'],
    },
    'done': {
        'common': ['다 했어요!', '짠! 끝났어요!', '헤헤, 완성이에요!'],
        'uncommon': ['짜잔, 다 끝냈어요!', '깔끔하게 해 놨어요, 칭찬해 줘요!', '완성! 확인해 볼래요?'],
        'rare': ['다 됐어요, 꼼꼼히 봤어요!', '해냈어요! 한번 볼래요?'],
        'unique': ['다 끝냈어요, 자신 있어요!', '완벽하게 해 놨어요!'],
        'legend': ['부탁한 거 전부 끝냈어요!', '다 됐어요, 확인해 줄래요?'],
        'dev': ['빌드 통과.', '커밋하시죠.', '배포 준비 완료.', '테스트 전부 초록불.'],
    },
    'notify': {
        'common': ['저기요오, 봐 줄래요?', '여기 좀 봐 줘요!'],
        'uncommon': ['잠깐만요, 물어볼 게 있어요!', '이것 좀 같이 봐 줄래요?'],
        'rare': ['확인이 필요해요, 봐 줄래요?', '같이 정해야 할 게 있어요!'],
        'unique': ['잠깐 봐 줄 수 있어요?', '여기 확인이 필요해요!'],
        'legend': ['잠깐 확인해 줄래요?', '같이 봐야 할 게 있어요!'],
        'dev': ['입력 대기 중.', '확인 요망.'],
    },
}
SCRIPT_TALK_ERROR = ['앗, 넘어졌어요…', '으앙, 실패했어요…']

# What a freshly drawn mascot says: each one introduces itself in a word of
# its own and its name. Dev faces keep the terse tier line ({0} is the name).
INTRO = {
    'Kitten': '"냥! 나는 Kitten, 아기 고양이예요!"',
    'Puppy': '"멍멍! 나는 Puppy, 강아지예요!"',
    'Chick': '"삐약! 나는 Chick, 병아리예요!"',
    'Boo': '"까꿍! 나는 Boo, 꼬마 유령이에요!"',
    'Hamster': '"쪼르르! 나는 Hamster, 햄스터예요!"',
    'Piglet': '"꿀꿀! 나는 Piglet, 아기 돼지예요!"',
    'Bunny': '"깡총! 나는 Bunny, 솜토끼예요!"',
    'Teddy': '"폭신! 나는 Teddy, 곰돌이예요!"',
    'Penguin': '"뒤뚱! 나는 Penguin, 펭귄이에요!"',
    'Koala': '"하암~ 나는 Koala, 코알라예요!"',
    'Sprite': '"팔랑! 나는 Sprite, 작은 정령이에요!"',
    'Panda': '"냠냠! 나는 Panda, 판다예요!"',
    'Owl': '"부엉! 나는 Owl, 부엉이예요!"',
    'Otter': '"퐁당! 나는 Otter, 수달이에요!"',
    'Aloof': '"흥, 나는 Aloof, 도도한 고양이예요."',
    'Sakura': '"살랑! 나는 Sakura, 벚꽃 토끼예요!"',
    'Sweetheart': '"두근! 나는 Sweetheart, 하트 강아지예요!"',
    'Songbird': '"랄랄라♪ 나는 Songbird, 노래 병아리예요!"',
    'Azure': '"크앙! 나는 Azure, 아기 청룡이에요!"',
    'Luna': '"파닥파닥! 나는 Luna, 달빛 박쥐예요!"',
    'Volt': '"찌릿! 나는 Volt, 번개 여우예요!"',
    'Blaze': '"으르렁! 나는 Blaze, 불곰이에요!"',
    'Mystic': '"쉿! 나는 Mystic, 마법 고양이예요!"',
}
INTRO_DEV = '"{0}. 로그인 완료."'

# What the in-app mascot says, by tier. The higher the tier, the more it has
# to say. Rare and above also say what the turn is doing (reading, editing,
# running...), and while a turn runs the line changes every ten seconds, with
# a riddle now and then whose answer follows a few seconds later.
#   work      lines while a turn runs
#   quiz      (question, answer) riddles mixed into the work lines
#   activity  what the latest tool call is doing, by kind
#   done      right after the turn ends (one minute)
#   notify    when something waits on the person
#   error     when the turn failed
MOD_TALK = {
    'common': {
        'work': ['영차영차!', '꼼지락꼼지락', '조금만 기다려 줘요!', '코드 냠냠 먹는 중', '으쌰, 거의 다 왔어요!'],
        'quiz': [],
        'activity': {},
        'done': ['다 했어요!', '짠! 끝났어요!', '헤헤, 완성!'],
        'notify': ['저기요오?', '여기 좀 봐 줘요!'],
        'error': ['앗, 넘어졌어요…', '으앙…'],
    },
    'uncommon': {
        'work': ['꼬리 흔들면서 일하는 중!', '집중 집중! 금방 끝낼게요', '하나씩 꼭꼭 챙기고 있어요', '끝나면 간식 주실 거죠?', '거의 다 왔어요, 조금만!'],
        'quiz': [('소가 웃으면?', '우하하!'), ('바나나가 웃으면?', '바나나킥!'), ('왕이 넘어지면?', '킹콩!')],
        'activity': {},
        'done': ['짜잔, 다 끝냈어요!', '깔끔하게 해 놨어요, 칭찬해 줘요!', '완성! 확인해 볼래요?'],
        'notify': ['잠깐만요, 물어볼 게 있어요!', '이것 좀 같이 봐 줄래요?'],
        'error': ['앗, 실수했어요…', '으앗, 다시 해 볼까요?'],
    },
    'rare': {
        'work': ['차근차근 살펴보는 중이에요', '어디가 아픈지 꼼꼼히 보고 있어요', '잘 되고 있어요, 걱정 마요!', '하나씩 맞춰 보는 중이에요'],
        'quiz': [('제일 빠른 닭은?', '후다닭!'), ('개가 사람을 가르치면?', '개인지도!'), ('소금이 죽으면?', '죽염!'), ('미소의 반대말은?', '당기소!')],
        'activity': {
            'read': '파일을 꼼꼼히 읽어 보는 중이에요', 'search': '어디 있는지 찾아보는 중이에요', 'edit': '코드를 살살 고치고 있어요',
            'run': '직접 돌려 보는 중이에요', 'web': '웹에서 찾아보고 있어요', 'agent': '친구한테 조금 맡겨 뒀어요',
        },
        'done': ['다 됐어요, 꼼꼼히 봤어요!', '해냈어요! 한번 볼래요?', '끝났어요, 마음에 들면 좋겠어요!'],
        'notify': ['확인이 필요해요, 봐 줄래요?', '같이 정해야 할 게 있어요!'],
        'error': ['앗, 잘 안 됐어요… 같이 봐 줄래요?', '실패했어요. 다시 방법을 찾아볼게요'],
    },
    'unique': {
        'work': ['반짝반짝 정리하는 중이에요!', '예쁘게 마무리하고 있어요', '지금 흐름이 아주 좋아요!', '조금만요, 거의 다 왔어요!'],
        'quiz': [('오리를 생으로 먹으면?', '회오리!'), ('왕이 넘어지면?', '킹콩!'), ('세상에서 가장 뜨거운 과일은?', '천도복숭아!'),
                 ('진짜 문제투성이인 것은?', '시험지!')],
        'activity': {
            'read': '관련 파일을 하나하나 읽고 있어요!', 'search': '필요한 곳을 콕 찾아내는 중이에요!', 'edit': '코드를 예쁘게 다듬는 중이에요!',
            'run': '직접 돌려서 확인하고 있어요!', 'web': '웹에서 자료를 모으는 중이에요!', 'agent': '친구들한테 일을 나눠 맡겼어요!',
        },
        'done': ['다 끝냈어요, 자신 있어요!', '완벽하게 해 놨어요!', '마무리했어요, 결과 한번 봐 줄래요?'],
        'notify': ['잠깐 봐 줄 수 있어요?', '여기 확인이 필요해요!', '골라 줘야 할 게 있어요!'],
        'error': ['막혀 버렸어요… 원인을 같이 봐 줄래요?', '실패했어요, 다른 방법을 찾아볼게요!'],
    },
    'legend': {
        'work': ['천천히, 그래도 확실하게!', '하나도 빠짐없이 챙기는 중이에요', '맡겨 준 일, 정성껏 하고 있어요', '흐름 좋아요, 곧 끝나요!'],
        'quiz': [('물고기의 반대말은?', '불고기!'), ('제일 빠른 새는?', '눈 깜짝할 새!'), ('가장 억울한 도형은?', '원통!'),
                 ('사과가 웃으면?', '풋사과!'), ('칼이 정색하면?', '검정색!')],
        'activity': {
            'read': '관련 파일을 차례차례 읽고 있어요', 'search': '단서를 쏙쏙 찾는 중이에요', 'edit': '코드를 정성껏 다듬고 있어요',
            'run': '직접 돌려서 결과를 확인하고 있어요', 'web': '웹에서 새 자료를 살펴보는 중이에요', 'agent': '친구들과 나눠서 함께 하고 있어요',
        },
        'done': ['부탁한 거 전부 끝냈어요!', '다 됐어요, 확인해 줄래요?', '마무리했어요! 더 필요한 거 있으면 말해 줘요'],
        'notify': ['잠깐 확인해 줄래요?', '같이 봐야 할 게 있어요!'],
        'error': ['문제가 생겼어요… 같이 살펴봐 줄래요?', '중간에 멈췄어요, 확인해 줄래요?'],
    },
    'dev': {
        'work': ['빌드 도는 중.', '컴파일 중.', '테스트 도는 중.'],
        'quiz': [],
        'activity': {'read': 'grep 중.', 'search': 'grep 중.', 'edit': '패치 적용 중.', 'run': '실행 중.', 'web': 'fetch 중.', 'agent': '워커 띄움.'},
        'done': ['빌드 통과.', '커밋하시죠.', '배포 준비 완료.', '테스트 전부 초록불.'],
        'notify': ['입력 대기 중.', '확인 요망.'],
        'error': ['빌드 실패.', '로그 확인 요망.'],
    },
}

SCRIPT_TIERS = ['common', 'uncommon', 'rare', 'unique', 'legend', 'dev']


# ---- script blocks ---------------------------------------------------------

def sh_faces():
    out = []
    for tier in ['error', 'common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        out.append("KAO_%s='%s'" % (tier.upper(), '|'.join('#'.join(fr) for _, fr in FACES[tier])))
    out.append('')
    for tier in SCRIPT_TIERS:
        out.append("NAME_%s='%s'" % (tier.upper(), '|'.join(n for n, _ in FACES[tier])))
    return '\n'.join(out)


def sh_talk():
    out = []
    for kind in ['work', 'done', 'notify']:
        for tier in SCRIPT_TIERS:
            out.append("TALK_%s_%s='%s'" % (kind.upper(), tier.upper(), '|'.join(SCRIPT_TALK[kind][tier])))
    out.append("TALK_ERROR='%s'" % '|'.join(SCRIPT_TALK_ERROR))
    return '\n'.join(out)


def sh_legend():
    out = ['# Legend colours, generated by docs/legend/render.py. Numbered by legend',
           '# (1-5): the body ramp (36 cells around a loop), the decoration colours',
           '# (seven rainbow hues, or that legend’s own colours) and the colour the',
           '# spoken line wears. One set in 24-bit colour, one snapped to the xterm cube.']
    for tc, tag in ((True, 'TRUE'), (False, '256')):
        for i, fx in enumerate(LEGEND_FX):
            out.append("LEGEND_RAMP_%s_%d='%s'" % (tag, i + 1, ' '.join(codes_of(ramp(fx['ramp']), tc))))
        for i, fx in enumerate(LEGEND_FX):
            out.append("LEGEND_DECO_%s_%d='%s'" % (tag, i + 1, ' '.join(codes_of(deco_colors(fx), tc))))
        out.append("LEGEND_TALK_%s='%s'" % (tag, ' '.join(codes_of([fx['theme'] for fx in LEGEND_FX], tc))))
    out.append("LEGEND_SIDES='%s'" % ' '.join(fx['sides'] for fx in LEGEND_FX))
    return '\n'.join(out)


def ps_faces():
    out = []
    for tier in ['error', 'common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        out.append("$Kao%s = '%s'" % (tier.capitalize(), '|'.join('#'.join(fr) for _, fr in FACES[tier])))
    out.append('')
    for tier in SCRIPT_TIERS:
        out.append("$Name%s = '%s'" % (tier.capitalize(), '|'.join(n for n, _ in FACES[tier])))
    return '\n'.join(out)


def _ps_list(items):
    return '@(%s)' % ', '.join("'%s'" % s for s in items)


def ps_talk():
    out = []
    for kind, var in (('work', 'TalkWork'), ('done', 'TalkDone'), ('notify', 'TalkNotify')):
        out.append('$%s = @{' % var)
        for tier in SCRIPT_TIERS:
            out.append('    %s = %s' % (tier, _ps_list(SCRIPT_TALK[kind][tier])))
        out.append('}')
    out.append('$TalkError = %s' % _ps_list(SCRIPT_TALK_ERROR))
    return '\n'.join(out)


def ps_legend():
    out = ['# Legend colours, generated by docs/legend/render.py, in legend order: the',
           '# body ramp (36 cells around a loop), the decoration colours (seven rainbow',
           '# hues, or that legend’s own colours) and the colour the spoken line',
           '# wears. One set in 24-bit colour, one snapped to the xterm cube.']
    for tc, tag in ((True, 'True'), (False, '256')):
        out.append('$LegendRamp%s = %s' % (tag, _ps_list('|'.join(codes_of(ramp(fx['ramp']), tc)) for fx in LEGEND_FX)))
        out.append('$LegendDeco%s = %s' % (tag, _ps_list('|'.join(codes_of(deco_colors(fx), tc)) for fx in LEGEND_FX)))
        out.append('$LegendTalk%s = %s' % (tag, _ps_list(codes_of([fx['theme'] for fx in LEGEND_FX], tc))))
    out.append('$LegendSides = %s' % _ps_list(fx['sides'] for fx in LEGEND_FX))
    return '\n'.join(out)


def ps_intro():
    out = ['$Intro = @{']
    for tier in TIER_ORDER:
        for name, _ in FACES[tier]:
            out.append("    %s = '%s'" % (name, INTRO[name]))
    out.append('}')
    out.append("$IntroDev = '%s'" % INTRO_DEV)
    return '\n'.join(out)


def sh_intro():
    out = ['intro_line() {', '    case "$2" in']
    for tier in TIER_ORDER:
        for name, _ in FACES[tier]:
            out.append("        %s) printf %%s '%s' ;;" % (name, INTRO[name]))
    out.append("        *) printf '%s' \"$2\" ;;" % INTRO_DEV.replace('{0}', '%s'))
    out += ['    esac', '}']
    return '\n'.join(out)


# ---- plugin data -----------------------------------------------------------

def mod_data():
    """hooks/mascot-data.ts: what the in-app mascot draws and says."""
    tiers = ['common', 'uncommon', 'rare', 'unique', 'legend', 'dev']
    faces = {t: [{'name': n, 'frames': f} for n, f in FACES[t]] for t in tiers}
    flat = {t: xterm_hex(c) for t, c in FLAT_CELLS.items()}
    fx = [{k: v for k, v in f.items() if k in ('effect', 'theme', 'sides', 'ramp', 'deco')} for f in LEGEND_FX]
    talk = {t: {**MOD_TALK[t], 'quiz': [{'q': q, 'a': a} for q, a in MOD_TALK[t]['quiz']]} for t in tiers}
    dump = lambda v: json.dumps(v, ensure_ascii=False, indent=2)
    return '\n'.join([
        '// Generated by docs/legend/render.py (python render.py mod <out>): edit it there.',
        '',
        "export type Tier = 'common' | 'uncommon' | 'rare' | 'unique' | 'legend' | 'dev'",
        "export type Activity = 'read' | 'search' | 'edit' | 'run' | 'web' | 'agent'",
        "export type Effect = 'azure' | 'bat' | 'volt' | 'blaze' | 'aurora'",
        'export type Riddle = { q: string; a: string }',
        'export type TierTalk = {',
        '  work: string[]',
        '  quiz: Riddle[]',
        '  activity: Partial<Record<Activity, string>>',
        '  done: string[]',
        '  notify: string[]',
        '  error: string[]',
        '}',
        '// How a legend is drawn: its effect, its body colours, where its outside',
        '// decorations sit (first and/or last character), the colour its line',
        '// wears, and the colours of its decorations when they are not the rainbow.',
        "export type LegendFx = { effect: Effect; theme: string; sides: string; ramp: string[]; deco?: string[] }",
        '',
        'export const FACES: Record<Tier, { name: string; frames: string[] }[]> = ' + dump(faces),
        '',
        'export const ERROR_FRAMES: string[] = ' + dump(FACES['error'][0][1]),
        '',
        'export const LEGEND_FX: LegendFx[] = ' + dump(fx),
        '',
        'export const FLAT: Record<string, string> = ' + dump(flat),
        '',
        'export const TALK: Record<Tier, TierTalk> = ' + dump(talk),
        '',
    ])


# ---- docs ------------------------------------------------------------------

def legend_cells(text, i):
    """The status line's still picture of a legend: the body ramp darkest at
    the edges and lightest in the middle, decorations in their own colours."""
    fx = LEGEND_FX[i]
    r = ramp(fx['ramp'])
    deco = deco_colors(fx)
    hi = len(r) // 2
    L = len(text)
    out = []
    slot = 0
    for k, ch in enumerate(text):
        side = ('L' if k == 0 else '') + ('R' if k == L - 1 else '')
        if side and any(s in fx['sides'] for s in side):
            out.append((ch, deco[(slot * (len(deco) // 2)) % len(deco)]))
            slot += 1
            continue
        d = abs(2 * k - (L - 1))
        out.append((ch, r[hi - (hi * d // (L - 1)) if L > 1 else hi]))
    return out


def svg(cells):
    fs = 22
    unit = 13.6  # approx advance of one narrow cell at 22px
    x = 10.0
    parts = []
    for ch, col in cells:
        text = ch.replace('&', '&amp;').replace('<', '&lt;')
        parts.append('<text x="%.1f" y="22.0" fill="%s">%s</text>' % (x, col, text))
        x += unit * (2 if cw(ch, 1) == 2 else 1) * (0.81 if cw(ch, 1) == 2 else 1)
    w = int(x + 8)
    head = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="42" viewBox="0 0 %d 42" role="img">\n'
            '<rect width="100%%" height="100%%" rx="6" fill="#0d1117"/>\n'
            '<g font-family="\'Segoe UI Symbol\',\'Malgun Gothic\',\'Noto Sans CJK KR\',\'Apple SD Gothic Neo\','
            '\'Noto Sans Symbols 2\',\'DejaVu Sans\',monospace" font-size="%d" dominant-baseline="middle">\n'
            % (w, w, fs))
    return head + '\n'.join(parts) + '\n</g></svg>\n'


def swatch_svg(hexes):
    """Ten squares coloured along a ramp."""
    cell, gap, pad = 22, 4, 4
    n = len(hexes)
    w = pad * 2 + cell * 10 + gap * 9
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img">' % (w, cell + pad * 2, w, cell + pad * 2),
             '<rect width="100%" height="100%" rx="6" fill="#0d1117"/>']
    for i in range(10):
        col = hexes[int(round(i * (n - 1) / 9))]
        parts.append('<rect x="%d" y="%d" width="%d" height="%d" rx="4" fill="%s"/>' % (pad + i * (cell + gap), pad, cell, cell, col))
    parts.append('</svg>')
    return chr(10).join(parts) + chr(10)


def _code(face):
    # A face holding a backtick needs a double-backtick code span.
    return '`` %s ``' % face if '`' in face else '`%s`' % face


def readme_tables():
    out = []
    for tier in TIER_ORDER:
        if tier == 'legend':
            out.append('| 이름 | 모습 | 얼굴 | 효과 |')
            out.append('| --- | --- | --- | --- |')
            for i, (name, frames) in enumerate(FACES[tier]):
                fx = LEGEND_FX[i]
                out.append('| **%s** %s | ![%s](docs/legend/legend-%d.svg) | %s | **%s** · %s |' % (
                    name, KIND[name], name, i + 1, ' · '.join(_code(f) for f in dict.fromkeys(frames)), fx['name'], LEGEND_DESC[fx['effect']]))
        else:
            out.append('| 이름 | 얼굴 | 표정 |')
            out.append('| --- | --- | --- |')
            for name, frames in FACES[tier]:
                out.append('| **%s** %s | `%s` | %s |' % (name, KIND[name], frames[0], ' · '.join('`%s`' % f for f in frames[1:])))
        out.append('')
    return '\n'.join(out)


def html_page():
    tiers = [{'tier': t, 'label': TIER_KO[t], 'faces': [{'name': n, 'kind': KIND[n], 'frames': f} for n, f in FACES[t]]} for t in TIER_ORDER]
    legend = [[legend_cells(fr, i) for fr in frames] for i, (_, frames) in enumerate(FACES['legend'])]
    data = {
        'tiers': tiers,
        'legend': legend,
        'legendTalk': [fx['theme'] for fx in LEGEND_FX],
        'flat': {t: xterm_hex(FLAT_CELLS[t]) for t in ('common', 'uncommon', 'rare', 'unique')},
        'talk': {t: SCRIPT_TALK['done'][t][0] for t in TIER_ORDER},
    }
    return """<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>statusline preview</title>
<style>
body{margin:0;padding:24px;background:#0d1117;color:#c9d1d9;font:14px/1.6 'Cascadia Mono','D2Coding','JetBrains Mono','Consolas','Malgun Gothic',monospace}
h1{font-size:18px;margin:0 0 4px}
p.note{color:#8b949e;margin:0 0 24px;font-size:13px}
h2{font-size:15px;margin:28px 0 10px;color:#8b949e;font-weight:normal;border-bottom:1px solid #21262d;padding-bottom:4px}
table{border-collapse:collapse}
td{padding:6px 14px 6px 0;vertical-align:middle;white-space:nowrap}
td.name{color:#8b949e;width:170px}
td.face{font-size:22px}
td.line{font-size:15px}
</style></head><body>
<h1>claude-statusline-astro 미리보기</h1>
<p class="note">상태줄 끝에 그려지는 모습입니다. 표정은 2초마다 바뀌고, 말은 얼굴 오른쪽에 한 칸 띄워 한 가지 색으로 나옵니다. 레전드의 움직이는 효과는 플러그인을 설치하면 프롬프트 아래에서 0.1초마다 그려집니다.</p>
<div id="root"></div>
<script>
const D = """ + json.dumps(data, ensure_ascii=False) + """;
const esc = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;');
function render(){
  const frame = Math.floor(Date.now() / 2000);
  let html = '';
  D.tiers.forEach(t => {
    html += '<h2>' + t.label + ' · ' + t.faces.length + '종</h2><table>';
    t.faces.forEach((f, fi) => {
      const k = frame % f.frames.length;
      let face, color;
      if (t.tier === 'legend') { face = D.legend[fi][k].map(([ch, c]) => '<span style="color:' + c + '">' + esc(ch) + '</span>').join(''); color = D.legendTalk[fi]; }
      else { color = D.flat[t.tier]; face = '<span style="color:' + color + '">' + esc(f.frames[k]) + '</span>'; }
      html += '<tr><td class="name">' + f.name + ' · ' + f.kind + '</td><td class="face">' + face + '</td><td class="line" style="color:' + color + '">' + D.talk[t.tier] + '</td></tr>';
    });
    html += '</table>';
  });
  document.getElementById('root').innerHTML = html;
}
render(); setInterval(render, 2000);
</script></body></html>
"""


if __name__ == '__main__':
    if not validate():
        sys.exit('validation failed')
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if cmd == 'sh':
        print(sh_faces())
    elif cmd == 'shtalk':
        print(sh_talk())
    elif cmd == 'shlegend':
        print(sh_legend())
    elif cmd == 'ps':
        print(ps_faces())
    elif cmd == 'pstalk':
        print(ps_talk())
    elif cmd == 'pslegend':
        print(ps_legend())
    elif cmd == 'shintro':
        print(sh_intro())
    elif cmd == 'psintro':
        print(ps_intro())
    elif cmd == 'html':
        with open(sys.argv[2], 'w', encoding='utf-8', newline=chr(10)) as fh:
            fh.write(html_page())
        print('wrote', sys.argv[2])
    elif cmd == 'readme':
        print(readme_tables())
    elif cmd == 'svg':
        outdir = sys.argv[2]
        os.makedirs(outdir, exist_ok=True)
        for i, (name, frames) in enumerate(FACES['legend']):
            with open(os.path.join(outdir, 'legend-%d.svg' % (i + 1)), 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(svg(legend_cells(frames[0], i)))
            with open(os.path.join(outdir, 'swatch-%d.svg' % (i + 1)), 'w', encoding='utf-8', newline=chr(10)) as fh:
                fh.write(swatch_svg(ramp(LEGEND_FX[i]['ramp'])))
        print('wrote', len(FACES['legend']), 'legend svgs + swatches')
    elif cmd == 'mod':
        with open(sys.argv[2], 'w', encoding='utf-8', newline=chr(10)) as fh:
            fh.write(mod_data())
        print('wrote', sys.argv[2])
    elif cmd == 'count':
        for t in TIER_ORDER:
            print(t, len(FACES[t]))
        print('total', sum(len(FACES[t]) for t in TIER_ORDER))
    else:
        print('ok')
