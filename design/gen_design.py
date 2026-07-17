#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the Dorf Company design-system bundle for Claude Design.

Every screen is a pixel-faithful recreation of the shipped Godot scene at its true
720x1280 portrait viewport, using the real coordinates/colors/strings pulled from
scripts/{menu,combat,overworld}/*.gd. That makes the workspace a real design surface:
a change you make here maps 1:1 back to a Godot coordinate.
"""
import os, math, textwrap

OUT = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- palette (from the .gd consts)
BG        = "#17171f"   # COL_BG      Color(0.09,0.09,0.12)
HUD       = "#1f1f29"   # COL_HUD     Color(0.12,0.12,0.16)
PANEL     = "#212129"   # lobby panel Color(0.13,0.13,0.17)
GREEN     = "#4dd16b"   # C_GREEN
AMBER     = "#f2bd33"   # C_AMBER
RED       = "#eb4242"   # C_RED
COIN      = "#f5d142"   # C_COIN
ORB       = "#f5d640"   # card cost orb Color(0.96,0.84,0.25)
SEL       = "#fff273"   # selected card border Color(1.0,0.95,0.45)
DIM       = "#b3b3c7"   # Color(0.7,0.7,0.78)
FAINT     = "#6b6b7a"   # Color(0.42,0.42,0.48)

TINT = {"attack": "#752424", "power": "#572b75", "skill": "#21426b"}
CLASS_COL = {"warrior": "#9ea3ad", "cleric": "#f2cc4d", "sorcerer": "#9e66d9"}
DANGER_BG = {"low": "#295733", "med": "#66521a", "high": "#662121"}
DANGER_BANNER = {"low": GREEN, "med": AMBER, "high": RED}
SKULLS = {"low": "\U0001f480", "med": "\U0001f480\U0001f480", "high": "\U0001f480\U0001f480\U0001f480"}
COIN_STACK = {"low": 2, "med": 4, "high": 6}
HEXFILL = {"wall": "#1c1f24", "cur": "#4d7094", "objective": "#755c21",
           "resolved": "#2b362e", "combat": "#57362b", "reward": "#334f2b",
           "event": "#453654", "empty": "#3b423b"}
INTENT_COL = {"attack": "#ff8c80", "multi": "#ff8c80", "attack_all": "#ff8c80",
              "block": "#9ed9ff", "guard_all": "#9ed9ff",
              "rage_all": "#fac759", "expose": "#d99eff"}
THREAT = "rgba(242,77,77,.65)"

# ---------------------------------------------------------------- the card library (card_db.gd)
# body = Db.describe(def, null, 0, 0) — the neutral face, no live buffs applied.
C = lambda cid, name, cost, emoji, ctype, target, body, tip, tags="": dict(
    cid=cid, name=name, cost=cost, emoji=emoji, type=ctype, target=target,
    body=body, tip=tip, tags=tags)

CHASSIS = [
    C("strike", "Strike", 1, "\U0001f5e1️", "attack", "enemy", ["Deal 6"],
      "Your bread-and-butter swing — the unit everything else is read against."),
    C("guard", "Guard", 1, "\U0001f6e1️", "skill", "self", ["Gain 5 block"],
      "Raise your shield. Block soaks the next hits this turn, then it's gone.", "fortifiable"),
    C("cleave", "Cleave", 2, "\U0001fa93", "attack", "all_enemies", ["Deal 11 to ALL"],
      "A heavy swing that catches every enemy at once."),
    C("wall", "Wall", 2, "\U0001f9f1", "skill", "self", ["Gain 12 block"],
      "Brace hard — a wall of block to weather a big incoming turn."),
]
POOL = [
    C("power_through", "Power Through", 1, "\U0001f4aa", "skill", "self", ["Gain 8 block", "Draw 1"],
      "Gain 8 Block. Draw 1."),
    C("precise_jab", "Precise Jab", 0, "\U0001f5e1️", "attack", "enemy", ["Deal 4", "Gain 1 ⚡"],
      "Deal 4, then refund 1 Energy — nearly free tempo."),
    C("whetstone", "Whetstone", 0, "\U0001faa8", "skill", "self", ["Next attack +4"],
      "Your next attack this turn deals +4."),
    C("guard_break", "Guard Break", 1, "\U0001f4a5", "attack", "enemy",
      ["Deal 7", "Apply Vulnerable \U0001f4a5 (+50%)"],
      "Deal 7 and apply Vulnerable (target takes +50% for a turn). Applies AFTER this hit."),
    C("field_dressing", "Field Dressing", 1, "\U0001fa79", "skill", "self", ["Heal yourself 7"],
      "Heal yourself 7."),
    C("bracing_stance", "Bracing Stance", 1, "\U0001f9f1", "skill", "self",
      ["Gain 10 block", "Block keeps next turn"], "Gain 10 Block that does NOT expire on your next turn."),
    C("opportunist", "Opportunist", 1, "\U0001f3af", "attack", "enemy",
      ["Deal 6", "If \U0001f3af Marked: +6 dmg"], "Deal 6, +6 more if the target is Marked."),
    C("rally", "Rally", 1, "\U0001f4e3", "skill", "party", ["All allies +3 block", "Draw 1"],
      "All allies gain 3 Block. Draw 1."),
    C("trophy_hunter", "Trophy Hunter", 2, "\U0001f3c6", "attack", "enemy",
      ["Deal 12", "On kill: +2 ⚡"], "Deal 12. If it kills the target, gain 2 Energy."),
]
WARRIOR_SIG = [
    C("taunt", "Taunt", 1, "\U0001f621", "skill", "self", ["All enemies hit Warrior", "Gain 8 block"],
      "Force enemies within range to swing at you next turn, and gain 8 block to survive it. Can't be played two turns in a row.", "no_repeat"),
    C("retaliate", "Retaliate", 1, "⚡", "skill", "self", ["Reflect 4 when hit"],
      "Punish them for taking the bait — every hit you eat this turn hits back for 4."),
    C("fortify", "Fortify", 1, "\U0001f527", "skill", "self", ["Next Guard +5; Retaliate +2"],
      "Reinforce — your NEXT Guard this turn grants +5 block, and Retaliate deals +2 while active."),
]
WARRIOR_REW = [
    C("reckless_swing", "Reckless Swing", 1, "\U0001fa93", "attack", "enemy", ["Deal 14", "Lose 3 HP"],
      "Deal 14. Take 3. Leans you Bloodied — pairs with cards that reward it."),
    C("second_wind", "Second Wind", 1, "\U0001f6e1️", "skill", "self",
      ["Gain 6 block", "Bloodied: +6 block"], "Gain 6 Block. +6 more while Bloodied (at or below half HP)."),
    C("momentum_strike", "Momentum Strike", 1, "⚔️", "attack", "enemy",
      ["Deal 6", "+3 per ⚔️ Momentum"],
      "Deal 6, +3 per Momentum (attacks you've already played this turn). Play it late."),
]
CLERIC_SIG = [
    C("channel_shield", "Channel Shield", 1, "\U0001f530", "skill", "ally", ["Ally: -3 dmg per hit"],
      "Wrap an ally in protection — every blow against them this turn is softened by 3."),
    C("mend_or_smite", "Mend or Smite", 1, "⚖️", "skill", "ally_or_enemy",
      ["Heal 5 ally / Deal 5 enemy"], "Mercy or judgment — tap an ally to heal 5, or an enemy to deal 5."),
    C("aura_of_valor", "Aura of Valor", 2, "\U0001f4e3", "power", "self", ["All allies +2 attack"],
      "Inspire the company — allies within range deal +2 attack this turn. A real commitment (2 energy)."),
]
CLERIC_REW = [
    C("lay_on_hands", "Lay on Hands", 1, "\U0001f64c", "skill", "ally", ["Heal ally 10"], "Heal a chosen ally 10."),
    C("consecrate", "Consecrate", 1, "\U0001f56f️", "skill", "party", ["All allies +4 block"],
      "All allies gain 4 Block."),
    C("divine_smite", "Divine Smite", 2, "\U0001f31f", "attack", "enemy",
      ["Deal 10", "Spend \U0001f64f (0): +8 dmg"], "Deal 10, +8 more if you spend 1 Devotion (built by playing skills)."),
]
SORC_SIG = [
    C("mark", "Mark", 1, "\U0001f3af", "skill", "enemy", ["Mark: +25% dmg taken"],
      "Paint the target — it takes +25% from ALL sources this turn. Your whole party benefits."),
    C("channel", "Channel", 1, "\U0001f300", "power", "self", ["Next 2 attacks +3"],
      "Gather power — your next 2 attack cards this turn deal +3 each."),
    C("arcane_finisher", "Arcane Finisher", 2, "\U0001f4a5", "attack", "enemy",
      ["Deal 5", "(+3 per attack · 0 so far)"], "Unleash everything — deal 5 +3 per attack already played this turn. Play it LAST."),
]
SORC_REW = [
    C("arc_lightning", "Arc Lightning", 2, "⚡", "attack", "enemy", ["Deal 9", "Deal 4 to ALL"],
      "Deal 9 to the target, then 4 to ALL enemies."),
    C("empower", "Empower", 0, "✨", "power", "self", ["Next card ×2"],
      "Your next card's numbers are doubled. Set up a big hit."),
    C("kindle", "Kindle", 1, "\U0001f525", "attack", "enemy", ["Deal 5", "Apply 3 \U0001f525 Burn"],
      "Deal 5, then apply 3 Burn (ticks at the start of each enemy turn, ignores block)."),
]

# ---------------------------------------------------------------- html plumbing
BASE_CSS = """
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:#0b0b0e;color:#e6e7ea;
  font-family:"Segoe UI",system-ui,-apple-system,"Noto Sans",sans-serif}
.wrap{padding:20px;display:flex;flex-direction:column;align-items:center;gap:12px}
.cap{width:720px;display:flex;align-items:baseline;gap:10px;font-size:13px;color:#8b8b99}
.cap b{color:#e6e7ea;font-size:15px;font-weight:600;letter-spacing:.02em}
.cap code{font-family:ui-monospace,Consolas,monospace;font-size:11px;color:#6b6b7a;margin-left:auto}
.stage{position:relative;width:720px;height:1280px;background:%s;overflow:hidden;
  border:1px solid #2c2c38;border-radius:4px}
.stage *{position:absolute}
.l{display:flex;align-items:flex-start;line-height:1.15;white-space:pre-wrap}
.c{justify-content:center;text-align:center}
.r{justify-content:flex-end;text-align:right}
/* Godot 4 default Button, approximated */
.btn{display:flex;align-items:center;justify-content:center;text-align:center;
  background:#33373f;border:1px solid #4a4f5a;border-radius:3px;color:#e4e6ea;
  line-height:1.2;white-space:pre-line}
.btn.on{background:#3f5a46;border-color:#5f8a6b}
.btn.off{background:#26282e;border-color:#34363d;color:#6e7078}
.le{display:flex;align-items:center;justify-content:center;background:#2a2c33;
  border:1px solid #43464f;border-radius:3px;color:#7c7f88}
""" % BG

def page(title, src, group, body, css="", stage_h=1280, note=""):
    """One preview file. The @dsCard marker MUST be the first line."""
    return (
        '<!-- @dsCard group="%s" -->\n' % group +
        "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
        "<title>%s</title>\n<style>%s\n.stage{height:%dpx}\n%s</style></head>\n<body>\n"
        '<div class="wrap">\n<div class="cap"><b>%s</b><span>%s</span><code>%s</code></div>\n'
        "%s\n</div>\n</body></html>\n" % (title, BASE_CSS, stage_h, css, title, note, src, body)
    )

def lbl(text, x, y, w, h, size, color="#ffffff", align="c", extra=""):
    a = {"c": "l c", "r": "l r", "l": "l"}[align]
    return ('<div class="%s" style="left:%gpx;top:%gpx;width:%gpx;height:%gpx;'
            'font-size:%gpx;color:%s;%s">%s</div>\n' % (a, x, y, w, h, size, color, extra, text))

def emoji(text, cx, cy, bw, bh, size, extra=""):
    """_mkemoji: a box of (bw,bh) CENTERED on (cx,cy), glyph centered inside."""
    return ('<div class="l c" style="left:%gpx;top:%gpx;width:%gpx;height:%gpx;'
            'font-size:%gpx;line-height:%gpx;justify-content:center;align-items:center;%s">%s</div>\n'
            % (cx - bw / 2, cy - bh / 2, bw, bh, size, bh, extra, text))

def rect(x, y, w, h, color, extra=""):
    return ('<div style="left:%gpx;top:%gpx;width:%gpx;height:%gpx;background:%s;%s"></div>\n'
            % (x, y, w, h, color, extra))

def btn(text, x, y, w, h, size, cls="btn", extra=""):
    return ('<div class="%s" style="left:%gpx;top:%gpx;width:%gpx;height:%gpx;font-size:%gpx;%s">%s</div>\n'
            % (cls, x, y, w, h, size, extra, text))

# ---------------------------------------------------------------- the card asset (card.gd)
def card_html(c, x=None, y=None, scale=1.0, selected=False, playable=True, cooldown=False, rot=0.0, lift=0.0):
    """130x188, radius 12, 2px border. Mirrors scripts/ui/card.gd exactly."""
    tint = TINT[c["type"]]
    bg = tint if playable else "color-mix(in srgb, %s 50%%, #000)" % tint
    border = ("4px solid %s" % SEL) if selected else "2px solid rgba(255,255,255,.22)"
    body = "<br>".join(c["body"])
    pos = ""
    if x is not None:
        pos = "position:absolute;left:%gpx;top:%gpx;" % (x, y - lift)
    tr = "transform:rotate(%gdeg) scale(%g);transform-origin:50%% 100%%;" % (rot, scale)
    op = "" if playable else "opacity:.72;"
    name = ("⏳ " if cooldown else "") + c["name"]
    return (
        '<div class="card" style="%s%s%swidth:130px;height:188px;background:%s;border:%s;'
        'border-radius:12px;">'
        '<div class="orb">%s</div>'
        '<div class="cemo">%s</div>'
        '<div class="cname">%s</div>'
        '<div class="cbody">%s</div>'
        "</div>" % (pos, tr, op, bg, border, c["cost"], c["emoji"], name, body)
    )

CARD_CSS = """
.card{position:relative;flex:0 0 auto;box-shadow:0 6px 18px rgba(0,0,0,.45)}
.card>*{position:absolute}
.orb{left:6px;top:6px;width:34px;height:34px;border-radius:17px;background:%s;color:#1f190d;
  display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:700}
.cemo{left:0;top:24px;width:130px;height:58px;display:flex;align-items:center;justify-content:center;font-size:38px}
.cname{left:4px;top:88px;width:122px;height:22px;text-align:center;font-size:15px;color:#fff}
.cbody{left:6px;top:112px;width:118px;height:74px;text-align:center;font-size:12px;
  color:#e6ebf5;line-height:1.25}
.tipp{width:236px;background:rgba(13,13,20,.97);border:1px solid rgba(255,255,255,.30);
  border-radius:8px;padding:6px 8px;font-size:12px;color:#e6e7ea;line-height:1.3}
""" % ORB

# ================================================================ SCREENS
def s_main_menu():
    b = ""
    b += rect(0, 0, 720, 1280, BG)
    b += lbl("DORF COMPANY", 0, 210, 720, 64, 46)
    b += lbl("- a quarterly raid -", 0, 286, 720, 30, 20, DIM)
    b += lbl("\U0001f6e1️   ⛑️   \U0001f9d9", 0, 344, 720, 64, 44)
    b += btn("Solo Play", 210, 560, 300, 64, 24)
    b += btn("Host Room", 210, 650, 300, 64, 24)
    b += btn("Join Room", 210, 740, 300, 64, 24)
    b += ('<div class="le" style="left:210px;top:832px;width:300px;height:52px;font-size:22px">'
          "ROOM CODE</div>\n")
    b += lbl("enter a room code, then press Enter", 0, 908, 720, 28, 16, "#e6cc73")
    b += lbl("build 276b578", 0, 1224, 720, 22, 13, FAINT)
    return page("Main Menu", "scenes/menu/main_menu.tscn", "Screens", '<div class="stage">%s</div>' % b,
                note="Solo · Host · Join — shown in the Join state")

def s_lobby():
    b = rect(0, 0, 720, 1280, BG)
    b += lbl("ROOM", 0, 60, 720, 26, 18, DIM)
    b += lbl("K7QM", 0, 90, 720, 70, 60, "#fff", extra="letter-spacing:.12em")
    b += lbl("PLAYERS", 40, 200, 300, 24, 16, DIM, "l")
    b += rect(40, 230, 640, 250, PANEL, "border-radius:8px")
    seats = [("\U0001f6e1️", "Thrain", "Warrior", "  (host)  (you)", True),
             ("⛑️", "Bruni", "Cleric", "", True),
             ("\U0001f9d9", "Vela", "Sorcerer", "", False)]
    for i, (e, n, cl, tag, ready) in enumerate(seats):
        col = "#99ff99" if ready else "#ffffff"
        chk = "  ✅" if ready else ""
        b += lbl("%s  %s  %s%s%s" % (e, n, cl, tag, chk), 56, 242 + i * 56, 600, 40, 22, col, "l")
    b += lbl("YOUR DORFS  (pick one)", 40, 500, 400, 24, 16, DIM, "l")
    b += rect(40, 530, 640, 220, PANEL, "border-radius:8px")
    roster = [("\U0001f6e1️", "Thrain", "Warrior"), ("⛑️", "Kael", "Cleric"),
              ("\U0001f9d9", "Torvi", "Sorcerer"), ("\U0001f6e1️", "Brom", "Warrior")]
    for i, (e, n, cl) in enumerate(roster):
        b += btn("%s %s\n%s" % (e, n, cl), 56 + i * 154, 546, 146, 120, 17,
                 "btn on" if i == 0 else "btn")
    b += btn("Unready", 40, 800, 310, 60, 22)
    b += btn("Start Fight", 370, 800, 310, 60, 22, "btn off")
    b += btn("\U0001f3f0  Start Campaign", 40, 876, 640, 64, 22, "btn off")
    b += lbl("one company · one purse · one rising rent", 0, 944, 720, 22, 14, "#a8a8b8")
    b += lbl("waiting for everyone to ready up", 0, 976, 720, 26, 16, "#e6cc73")
    b += btn("Leave", 40, 1200, 140, 44, 16)
    return page("Lobby", "scenes/menu/lobby.tscn", "Screens", '<div class="stage">%s</div>' % b,
                note="Room code · seats · dorf pick · Start Fight / Start Campaign")

def s_combat():
    EN = [(170, 200), (360, 200), (550, 200)]
    PC = [(170, 700), (360, 700), (550, 700)]
    enemies = [
        dict(name="Brute", emo="\U0001f479", hp="45/45", intent="\U0001f5e1️9>Thr", kind="attack", stat=""),
        dict(name="Assassin", emo="\U0001f977", hp="30/30", intent="\U0001f4a5>Bru", kind="expose", stat=""),
        dict(name="\U0001f3af Caster", emo="\U0001f52e", hp="18/28", intent="\U0001f6e1️6", kind="block",
             stat="\U0001f6e1️6 \U0001f525"),
    ]
    party = [
        dict(name="✅ Thrain", emo="\U0001f6e1️", hp="31/36", stat="\U0001f6e1️5 \U0001f501" + "4",
             en="⚡0/3", active=False),
        dict(name="Bruni", emo="⛑️", hp="28/28", stat="\U0001f530" + "3", en="⚡2/3", active=False),
        dict(name="Vela", emo="\U0001f9d9", hp="22/22", stat="\U0001f300" + "2", en="⚡1/3", active=True),
    ]
    b = rect(0, 0, 720, 1280, BG)
    b += lbl("— THE QUARTERLY RAID —", 60, 24, 600, 26, 18)
    # intent explainer panel (hover/tap an enemy) — the y 40..132 band
    b += rect(120, 40, 480, 92, "rgba(18,18,26,.97)", "border-bottom:1px solid rgba(255,255,255,.14)")
    b += lbl("\U0001f52e Caster — \U0001f6e1️ Ward 6", 130, 44, 460, 20, 15, "#fff", "l")
    b += lbl("Shields itself — the ward soaks your next hits.", 130, 67, 460, 18, 12, "#c7c7d1", "l")
    b += lbl("Next: \U0001f4a2 Bolt 10", 130, 87, 460, 18, 12, "#f2cc73", "l")
    b += lbl("Snipes the weakest — targets whoever has the lowest current HP.", 130, 108, 460, 18, 11, "#9eb3cc", "l")
    # threat arrows (enemy -> preferred target), drawn under the cards
    arrows = [(EN[0], PC[0]), (EN[1], PC[1]), (EN[2], PC[2])]
    svg = '<svg style="left:0;top:0;width:720px;height:1280px;pointer-events:none">'
    for (ax, ay), (bx, by) in arrows:
        ay2, by2 = ay + 46, by - 44
        dx, dy = bx - ax, by2 - ay2
        ln = math.hypot(dx, dy) or 1
        ux, uy = dx / ln, dy / ln
        sx, sy = bx - ux * 16, by2 - uy * 16
        px, py = -uy * 9, ux * 9
        svg += ('<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="3"/>'
                % (ax, ay2, sx, sy, THREAT))
        svg += ('<polygon points="%g,%g %g,%g %g,%g" fill="%s"/>'
                % (bx, by2, sx + px, sy + py, sx - px, sy - py, THREAT))
    svg += "</svg>"
    b += svg
    for i, (x, y) in enumerate(EN):
        e = enemies[i]
        b += emoji(e["emo"], x, y, 96, 76, 50)
        b += lbl(e["name"], x - 80, y - 74, 160, 20, 14)
        b += lbl(e["intent"], x - 80, y - 52, 160, 22, 18, INTENT_COL[e["kind"]])
        b += lbl(e["hp"], x - 80, y + 40, 160, 20, 16)
        if e["stat"]:
            b += lbl(e["stat"], x - 80, y + 60, 160, 18, 14)
    for i, (x, y) in enumerate(PC):
        p = party[i]
        if p["active"]:
            b += rect(x - 64, y - 60, 128, 150, "rgba(255,217,51,.16)")
        sc = "transform:scale(1.12)" if p["active"] else ""
        b += emoji(p["emo"], x, y, 110, 70, 50, sc)
        b += lbl(p["name"], x - 80, y - 58, 160, 20, 14)
        b += lbl(p["hp"], x - 80, y + 38, 160, 20, 16)
        b += lbl(p["stat"], x - 80, y + 58, 160, 18, 14)
        b += lbl(p["en"], x - 80, y + 76, 160, 18, 14)
    # mini-hands for the two non-active dwarves (y 798..848)
    for i, (x, y) in enumerate(PC):
        if party[i]["active"]:
            continue
        for j in range(4):
            b += rect(x - 89 + j * 44, 798, 38, 50, TINT["skill" if j % 2 else "attack"],
                      "border-radius:4px;border:1px solid rgba(255,255,255,.18);opacity:.72")
    b += lbl("VELA — ⚡ 1 / 3", 20, 852, 680, 26, 20, "#fff")
    b += lbl("tap a card, then tap an enemy", 20, 880, 680, 22, 15, "#c7c7d1")
    # the hand: a Spire fan of the sorcerer's cards
    hand = [SORC_SIG[0], SORC_SIG[1], CHASSIS[0], CHASSIS[0], SORC_SIG[2]]
    sel = 0
    n = len(hand)
    b += '<div style="left:0;top:905px;width:720px;height:220px">'
    for i, c in enumerate(hand):
        t = (i - (n - 1) / 2)
        x = 360 + t * 118 - 65
        rot = t * 5.0
        arc = abs(t) ** 2 * 7.0
        playable = c["cost"] <= 1
        b += card_html(c, x=x, y=26 + arc, rot=rot, selected=(i == sel), playable=playable,
                       lift=46 if i == sel else 0, scale=1.18 if i == sel else 1.0)
    b += "</div>"
    # tooltip for the selected card (Mark)
    # card.gd pins the tooltip 118px above the card. The leftmost card pushes it to the edge — this is
    # the known "tooltip can overflow the rightmost/leftmost card" issue, shown honestly.
    b += ('<div class="tipp" style="left:8px;top:752px;z-index:9">Mark: +25% dmg taken<br>'
          "— Paint the target — it takes +25% from ALL sources this turn. "
          "Your whole party benefits.</div>")
    b += btn("End Turn", 540, 1184, 165, 52, 20)
    b += lbl("Thrain played Guard — +5 block.", 16, 1244, 688, 30, 15, "#c7c7d1", "l")
    return page("Combat", "scenes/combat/combat.tscn", "Screens",
                '<div class="stage">%s</div>' % b, CARD_CSS,
                note="Co-op, simultaneous — Thrain ✅ has ended; Vela is mid-turn with Mark armed")

def dwarf_token(d, cx, cy):
    col = CLASS_COL[d["cls"]]
    emo = {"warrior": "\U0001f6e1️", "cleric": "⛑️", "sorcerer": "\U0001f9d9"}[d["cls"]]
    cname = {"warrior": "Warrior", "cleric": "Cleric", "sorcerer": "Sorcerer"}[d["cls"]]
    st = d["status"]
    b = rect(cx - 58, cy - 74, 116, 176, "color-mix(in srgb, %s 22%%, transparent)" % col)
    mod = ""
    if st == "wounded":
        mod = "filter:sepia(.5) brightness(.85)"
    elif st == "lost":
        mod = "filter:grayscale(1) brightness(.4)"
    b += emoji(emo, cx, cy - 16, 110, 84, 54, mod)
    dot = {"ready": GREEN, "wounded": AMBER, "lost": "#66666f"}[st]
    b += rect(cx + 26, cy - 60, 20, 20, dot)
    b += lbl(d["name"], cx - 58, cy + 42, 116, 22, 15)
    b += lbl(cname, cx - 58, cy + 64, 116, 18, 12, "#bfbfcc")
    if st == "wounded":
        b += emoji("\U0001fa79", cx - 30, cy - 44, 36, 36, 22)
        b += lbl("wounded", cx - 58, cy + 84, 116, 16, 11, AMBER)
        for j in range(d["recover"]):
            b += rect(cx - 14 + j * 18, cy + 104, 14, 14, AMBER)
    elif st == "lost":
        b += emoji("⚰️", cx - 30, cy - 44, 36, 36, 22)
        b += lbl("lost", cx - 58, cy + 84, 116, 16, 11, "#999")
    else:
        frac = d["hp"] / d["max"]
        hpc = GREEN if frac > .6 else (AMBER if frac > .3 else RED)
        b += rect(cx - 42, cy + 88, 84, 9, "#404050")
        b += rect(cx - 42, cy + 88, 84 * frac, 9, hpc)
        if d["hp"] < d["max"]:
            b += lbl("%d/%d" % (d["hp"], d["max"]), cx - 58, cy + 100, 116, 16, 11, hpc)
    return b

def hud(treasury=80, fee=55, month=1, jobs=3):
    b = rect(0, 0, 720, 158, HUD)
    b += rect(0, 156, 720, 2, "rgba(255,255,255,.08)")
    b += emoji("\U0001f4b0", 56, 62, 80, 76, 44)
    band = GREEN if treasury >= 2 * fee else (AMBER if treasury >= fee else RED)
    b += lbl("%dg" % treasury, 104, 30, 240, 60, 44, band, "l")
    b += rect(106, 100, 180, 10, band)
    b += emoji("\U0001f479", 668, 48, 72, 64, 40)
    b += lbl("RENT  %dg" % fee, 360, 24, 268, 28, 20, "#e6e6e6" if treasury >= fee else RED, "r")
    b += lbl("next  %dg" % (fee + 10), 360, 56, 268, 20, 13, "#e6e6e6", "r")
    for j in range(3):
        b += rect(500 + j * 26, 86, 20, 18, GREEN if j < jobs else "#404050")
    b += lbl("jobs left", 490, 108, 140, 16, 11, "#b3b3bf", "l")
    b += lbl("Month %d / 8" % month, 260, 120, 200, 24, 15)
    return b

def s_dashboard():
    b = rect(0, 0, 720, 1280, BG) + hud()
    b += lbl("— DORF & CO. —", 0, 190, 720, 30, 24)
    b += lbl("Your crew. Send them to make rent — or lose them.", 0, 226, 720, 20, 14, "#ccccd9")
    b += lbl("3 campaigns left this month · rent 55g due at month end", 0, 256, 720, 20, 14, "#b8d6f2")
    crew = [dict(name="Thrain", cls="warrior", status="ready", hp=36, max=36),
            dict(name="Bruni", cls="cleric", status="ready", hp=19, max=28),
            dict(name="Vela", cls="sorcerer", status="wounded", recover=2, hp=8, max=22),
            dict(name="Gimli", cls="warrior", status="lost", hp=0, max=36)]
    for i, d in enumerate(crew):
        b += dwarf_token(d, [96, 272, 448, 624][i], 470)
    b += btn("⏭️ End Month", 24, 1150, 180, 70, 17)
    b += btn("\U0001f4dc  View Contracts", 210, 1150, 320, 70, 22)
    return page("Company Dashboard", "scripts/overworld/overworld.gd · _build_dashboard", "Screens",
                '<div class="stage">%s</div>' % b,
                note="The roster — ready / wounded / lost, and the rent clock overhead")

def contract_card(c, x, selected=False):
    tier = c["tier"]
    b = ""
    y = 224 if selected else 236
    if selected:
        b += rect(x - 4, y - 4, 224, 628, DANGER_BANNER[tier])
    b += rect(x, y, 216, 620, DANGER_BG[tier])
    b += rect(x, y, 216, 46, DANGER_BANNER[tier])
    b += lbl("%s  %s" % (tier.upper(), SKULLS[tier]), x, y + 10, 216, 26, 18, "#1a1a1a")
    b += emoji(c["loc_emoji"], x + 108, y + 96, 120, 60, 40)
    b += lbl(c["title"], x + 6, y + 132, 204, 26, 17)
    b += lbl(c["loc_name"], x + 6, y + 160, 204, 20, 13, "#ccccd9")
    if c.get("mod"):
        b += lbl("%s %s" % (c["mod"][0], c["mod"][1]), x + 6, y + 194, 204, 22, 15, "#ffd966")
    for j in range(COIN_STACK[tier]):
        b += rect(x + 63, y + 330 - j * 15, 90, 12, COIN)
    b += lbl("%dg" % c["pay"], x + 6, y + 340, 204, 30, 22, COIN)
    b += lbl("crew", x + 6, y + 392, 204, 18, 12, "#ccccd9")
    cs = c["crew"]
    for j in range(cs):
        b += rect(x + 108 - cs * 15 + j * 30, y + 414, 24, 24, "#1a1a21")
    b += lbl("1 of 3 campaigns", x + 6, y + 460, 204, 18, 12, "#adadb8")
    if c.get("fight"):
        b += lbl("⚔️ REAL FIGHT", x + 6, y + 508, 204, 22, 15, "#ffd966")
    if selected:
        b += lbl("tap again to %s" % ("FIGHT" if c.get("fight") else "embark"),
                 x + 6, y + 540, 204, 22, 14, GREEN)
    else:
        b += lbl("tap to select", x + 6, y + 540, 204, 22, 13, "#d9d9e6")
    return b

def s_contracts():
    b = rect(0, 0, 720, 1280, BG) + hud()
    b += lbl("— CONTRACTS —", 0, 176, 720, 26, 20)
    b += lbl("Pick one job. Weigh payout against danger and time.", 0, 206, 720, 20, 14, "#ccccd9")
    cs = [
        dict(tier="low", title="Rat Cull", loc_emoji="\U0001f573️", loc_name="the Warrens",
             pay=25, crew=1),
        dict(tier="med", title="Haunted Mine", loc_emoji="⛰️", loc_name="the Deeproads",
             pay=136, crew=3, fight=True, mod=("\U0001f4b0", "Lucrative")),
        dict(tier="high", title="Lich's Ledger", loc_emoji="\U0001f3f0", loc_name="the Keep",
             pay=130, crew=3, fight=True, mod=("\U0001f451", "Elite")),
    ]
    for i, c in enumerate(cs):
        b += contract_card(c, [12, 252, 492][i], selected=(i == 1))
    # shop
    b += lbl("— SHOP —  buying trades against the rent clock", 0, 866, 720, 20, 14, COIN)
    shop = [("\U0001f3af", "Card", "Opportunist", 35, True),
            ("\U0001fa79", "Field Medic", "a dwarf to full HP", 25, True),
            ("⛑️", "Recruit", "Hilda · Cleric", 50, True)]
    for i, (e, t, d, cost, aff) in enumerate(shop):
        x = [24, 264, 504][i]
        b += rect(x, 896, 192, 108, "#3b473b" if i == 0 else "#292933")
        b += emoji(e, x + 96, 896 + 30, 80, 48, 28)
        b += lbl(t, x, 896 + 54, 192, 18, 13, "#d9d9e6")
        b += lbl(d, x + 4, 896 + 72, 184, 16, 11, "#bfbfcc")
        b += lbl("%dg" % cost, x, 896 + 88, 192, 18, 14, COIN if aff else RED)
    b += btn("◀ Back", 30, 1150, 150, 64, 18)
    return page("Contract Board + Shop", "scripts/overworld/overworld.gd · _build_contracts", "Screens",
                '<div class="stage">%s</div>' % b,
                note="Three jobs, one shop — every buy trades against the rent")

HEX_R = 50.0
HEX_W = HEX_R * math.sqrt(3.0)

def hex_px(cc, rr):
    x0 = 360.0 - HEX_W * (6 + 0.5) * 0.5 + HEX_W * 0.5
    return (x0 + HEX_W * (cc + 0.5 * (rr & 1)), 300.0 + HEX_R * 1.5 * rr)

def hex_tile(cc, rr, kind, danger=0, cur=False, reachable=False, resolved=False):
    cx, cy = hex_px(cc, rr)
    w, h = HEX_W, HEX_R * 2
    flat = kind == "wall"
    fill = HEXFILL["cur"] if cur else HEXFILL[kind if not resolved or kind in ("wall", "objective") else "resolved"]
    glyph = {"wall": "\U0001f3d4️", "objective": "\U0001f3c1", "combat": "⚔️",
             "reward": "\U0001f381", "event": "❓", "empty": "·"}[kind]
    if cur:
        glyph = "\U0001f6a9"
    elif resolved and kind not in ("wall", "objective"):
        glyph = "✔️"
    ring = ""
    if kind == "objective":
        ring = COIN
    elif reachable:
        ring = AMBER
    clip = "polygon(50% 0%, 100% 25%, 100% 75%, 50% 100%, 0% 75%, 0% 25%)"
    b = '<div style="left:%gpx;top:%gpx;width:%gpx;height:%gpx">' % (cx - w / 2, cy - h / 2, w, h)
    if not flat:
        b += ('<div style="left:0;top:6px;width:%gpx;height:%gpx;background:#17171c;'
              'clip-path:%s"></div>' % (w, h, clip))
    b += ('<div style="left:0;top:0;width:%gpx;height:%gpx;background:%s;clip-path:%s;'
          'opacity:%s"></div>' % (w, h, fill, clip, ".55" if flat else "1"))
    if ring:
        b += ('<div style="left:2px;top:2px;width:%gpx;height:%gpx;clip-path:%s;'
              'background:%s;opacity:.85"></div>'
              '<div style="left:5px;top:5px;width:%gpx;height:%gpx;clip-path:%s;background:%s"></div>'
              % (w - 4, h - 4, clip, ring, w - 10, h - 10, clip, fill))
    gy = -8 if (kind == "combat" and not resolved and not cur) else 0
    b += ('<div class="l c" style="left:0;top:%gpx;width:%gpx;height:%gpx;font-size:26px;'
          'align-items:center;justify-content:center;opacity:%s">%s</div>'
          % (gy, w, h, ".55" if flat else "1", glyph))
    if kind == "combat" and not resolved and not cur:
        b += ('<div class="l c" style="left:0;top:%gpx;width:%gpx;height:16px;font-size:12px;'
              'color:#f28080">%s</div>' % (h / 2 + 12, w, "☠" * danger))
    return b + "</div>"

def exp_crew_token(d, cx, cy):
    col = CLASS_COL[d["cls"]]
    emo = {"warrior": "\U0001f6e1️", "cleric": "⛑️", "sorcerer": "\U0001f9d9"}[d["cls"]]
    b = rect(cx - 66, cy - 66, 132, 168, "color-mix(in srgb, %s 16%%, transparent)" % col)
    mod = "filter:sepia(.5) brightness(.85)" if d.get("downed") else ""
    b += emoji(emo, cx, cy - 28, 96, 70, 44, mod)
    b += lbl(d["name"], cx - 66, cy + 16, 132, 20, 14)
    if d.get("downed"):
        b += lbl("DOWNED — save:", cx - 66, cy + 38, 132, 18, 11, RED)
        for j in range(3):
            b += rect(cx - 40 + j * 16, cy + 58, 12, 12, GREEN if j < d["ok"] else "#384d38")
        for j in range(3):
            b += rect(cx - 40 + j * 16, cy + 74, 12, 12, RED if j < d["bad"] else "#4d3838")
    else:
        frac = d["hp"] / d["max"]
        hpc = GREEN if frac > .6 else (AMBER if frac > .3 else RED)
        b += rect(cx - 42, cy + 44, 84, 9, "#404050")
        b += rect(cx - 42, cy + 44, 84 * frac, 9, hpc)
        b += lbl("%d/%d" % (d["hp"], d["max"]), cx - 66, cy + 56, 132, 16, 11, hpc)
    return b

def crew_bar(y=1006, ring=None, seats=None):
    seats = seats or [("\U0001f6e1️", "Thrain", True, True), ("⛑️", "Bruni", True, False),
                      ("\U0001f9d9", "Vela", True, False)]
    b = '<div style="left:0;top:%gpx;width:720px;height:74px">' % y
    b += rect(0, 0, 720, 74, "rgba(26,26,36,.94)")
    b += rect(0, 0, 720, 2, "rgba(255,255,255,.07)")
    if ring:
        head = "%s proposes: %s   (%d/%d)" % ring
        b += lbl(head, 12, 5, 560, 18, 13, AMBER, "l")
    else:
        b += lbl("the crew — the company only commits when everyone agrees", 12, 5, 560, 18, 13,
                 "#99999f", "l")
    for i, (e, n, present, ayed) in enumerate(seats):
        if not present:
            mark, col = "\U0001f4a4", "#73737f"
        elif ring:
            mark, col = ("✅", GREEN) if ayed else ("⏳", "#e0e0eb")
        else:
            mark, col = "•", "#e0e0eb"
        tag = "  (you)" if i == 0 else ""
        b += lbl("%s %s %s%s" % (e, n, mark, tag), 12 + i * 138, 28, 136, 22, 13, col, "l")
    if ring:
        if seats[0][3]:
            b += lbl("waiting…", 578, 30, 130, 20, 14, "#d9cc80")
        else:
            b += btn("✅ Agree", 582, 8, 126, 58, 16)
    return b + "</div>"

def s_expedition():
    b = rect(0, 0, 720, 1280, BG) + hud(treasury=104, fee=55)
    b += lbl("— EXPEDITION —", 0, 168, 720, 26, 20)
    b += lbl("Haunted Mine  ·  the Deeproads  ·  \U0001f4b0 Lucrative", 0, 196, 720, 20, 14, "#ccccd9")
    b += lbl("Route to \U0001f3c1 the captive. Icons hint the tile; ☠ = how tough. "
             "Detour for loot if you dare.", 0, 220, 720, 18, 12, "#b3b3bf")
    b += rect(48, 240, 624, 432, "#0d0f14")
    for (x, y, w, h) in [(48, 240, 624, 2), (48, 670, 624, 2), (48, 240, 2, 432), (670, 240, 2, 432)]:
        b += rect(x, y, w, h, "rgba(184,148,77,.30)")
    board = {
        (1, 1): ("combat", 2), (2, 1): ("reward", 0), (3, 1): ("empty", 0), (4, 1): ("objective", 0),
        (1, 2): ("event", 0), (2, 2): ("combat", 1), (3, 2): ("combat", 3), (4, 2): ("reward", 0),
        (1, 3): ("entry", 0), (2, 3): ("combat", 1), (3, 3): ("empty", 0), (4, 3): ("event", 0),
    }
    for rr in range(5):
        for cc in range(6):
            if cc in (0, 5) or rr in (0, 4):
                b += hex_tile(cc, rr, "wall")
    for (cc, rr), (kind, dg) in board.items():
        cur = kind == "entry"
        reach = (cc, rr) in [(1, 2), (2, 3)]
        b += hex_tile(cc, rr, "empty" if cur else kind, danger=dg, cur=cur, reachable=reach,
                      resolved=(cc, rr) == (2, 2))
    b += lbl("crew", 0, 716, 720, 18, 12, "#ccccd9")
    crew = [dict(name="Thrain", cls="warrior", hp=31, max=36),
            dict(name="Bruni", cls="cleric", hp=12, max=28),
            dict(name="Vela", cls="sorcerer", downed=True, ok=2, bad=1, hp=0, max=22)]
    for i, d in enumerate(crew):
        b += exp_crew_token(d, 120 + i * 240, 800)
    # Bruni proposed, so Bruni has ALREADY ayed (proposing is your aye). Vela agreed. You (Thrain)
    # have not — so the ✅ Agree button is live. 2 of 3.
    b += crew_bar(1006, ring=("Bruni", "move to ⚔️ a hex (☠☠)", 2, 3),
                  seats=[("\U0001f6e1️", "Thrain", True, False), ("⛑️", "Bruni", True, True),
                         ("\U0001f9d9", "Vela", True, True)])
    b += lbl("loot bag  +36g  ·  \U0001f3c1 the rescue pays the real money", 24, 1112, 430, 18, 12,
             "#d9cc8c", "l")
    b += btn("\U0001f3f3️ Extract (+36g)", 430, 1146, 266, 70, 18)
    return page("Expedition (hex crawl)", "scripts/overworld/overworld.gd · _build_hexcrawl", "Screens",
                '<div class="stage">%s</div>' % b,
                note="Co-op, with an open ring of ayes — Vela is down and rolling death saves")

def s_spoils():
    b = rect(0, 0, 720, 1280, BG) + hud(treasury=104)
    b += lbl("— SPOILS —", 0, 200, 720, 28, 22)
    b += lbl("One card leaves this room. Claim it and it joins YOUR deck — first tap wins.",
             0, 238, 720, 20, 14, "#ccccd9")
    loot = [POOL[3], POOL[8], SORC_REW[2]]
    for i, c in enumerate(loot):
        x = [40, 268, 496][i]
        sel = i == 1
        y = 288 if sel else 300
        if sel:
            b += rect(x - 3, y - 3, 190, 306, GREEN)
        b += rect(x, y, 184, 300, TINT[c["type"]])
        b += rect(x + 8, y + 8, 40, 40, COIN)
        b += lbl(str(c["cost"]), x + 8, y + 14, 40, 28, 22, "#1a1a1a")
        b += emoji(c["emoji"], x + 92, y + 84, 100, 76, 46)
        b += lbl(c["name"], x + 4, y + 138, 176, 26, 18)
        b += lbl("<br>".join(c["body"]), x + 8, y + 178, 168, 114, 13, "#e6e6eb")
    b += crew_bar(1006)
    b += btn("Leave it", 285, 1150, 150, 62, 18)
    return page("Spoils (card claim)", "scripts/overworld/overworld.gd · _build_hex_reward", "Screens",
                '<div class="stage">%s</div>' % b,
                note="Co-op: one card leaves the room, first tap wins")

def s_event():
    b = rect(0, 0, 720, 1280, BG) + hud(treasury=104)
    b += lbl("— A CHOICE —", 0, 300, 720, 28, 22)
    b += lbl("A sealed door, and a faint cry beyond it.", 0, 344, 720, 22, 15, "#d9d9e6")
    b += btn("\U0001f6aa Play it safe\n(+8g loot)", 90, 560, 240, 120, 18)
    b += btn("\U0001f5dd️ Force it open\n(risk)", 390, 560, 240, 120, 18)
    b += crew_bar(1006, ring=("Thrain", "\U0001f5dd️ force the door (risk)", 1, 3))
    return page("Event", "scripts/overworld/overworld.gd · _build_hex_event", "Screens",
                '<div class="stage">%s</div>' % b,
                note="A shared-risk choice — it is a ring proposal, not one player's call")

def s_outcome():
    b = rect(0, 0, 720, 1280, BG) + hud(treasury=104, fee=55)
    b += lbl("— OUTCOME —", 0, 210, 720, 28, 22)
    b += lbl("✅  CAPTIVE RESCUED", 0, 300, 720, 44, 30, GREEN)
    b += lbl("Haunted Mine — \U0001f3c1 rescue 136g  +  loot 36g", 0, 360, 720, 24, 15, "#d9d9e6")
    b += lbl("+172g", 0, 430, 720, 52, 40, COIN)
    b += crew_bar(1006)
    b += btn("Continue ▶", 240, 1150, 240, 70, 22, "btn off")
    return page("Outcome", "scripts/overworld/overworld.gd · _build_expedition_outcome", "Screens",
                '<div class="stage">%s</div>' % b,
                note="Rescued / Extracted / Wiped out — then the coins fly to the treasury")

# ================================================================ CARD PAGES
GRID_CSS = CARD_CSS + """
.wrap{align-items:flex-start;padding:28px 32px}
.cap{width:auto}
h2{font-size:15px;font-weight:600;letter-spacing:.10em;text-transform:uppercase;color:#8b8b99;
  margin:26px 0 4px;width:100%}
h2 span{color:#5c5c68;letter-spacing:0;text-transform:none;font-weight:400;margin-left:8px}
.row{display:flex;flex-wrap:wrap;gap:16px;width:100%;max-width:1180px}
.slot{width:130px}
.slot .why{font-size:11px;color:#7a7a88;line-height:1.35;margin-top:6px;text-align:center}
.blank{width:130px;height:188px;border:2px dashed #3d3d4a;border-radius:12px;background:#1a1a22;
  display:flex;align-items:center;justify-content:center;color:#43434f;font-size:26px}
.key{display:flex;flex-wrap:wrap;gap:8px;margin-top:6px}
.chip{font-size:11px;padding:3px 9px;border-radius:99px;border:1px solid #34343f;color:#a8a8b8;
  background:#1c1c24}
.chip.a{border-color:#752424;color:#e08f8f}
.chip.s{border-color:#21426b;color:#8fb4e0}
.chip.p{border-color:#572b75;color:#c295e0}
table{border-collapse:collapse;font-size:12px;margin-top:8px;width:100%;max-width:1180px}
td,th{border:1px solid #2c2c38;padding:5px 9px;text-align:left;vertical-align:top}
th{background:#1c1c24;color:#a8a8b8;font-weight:600}
td code{font-family:ui-monospace,Consolas,monospace;color:#e0b96b}
.note{font-size:12px;color:#7a7a88;line-height:1.5;max-width:900px;margin-top:6px}
"""

def card_row(cards, why=None):
    b = '<div class="row">'
    for c in cards:
        b += '<div class="slot">%s' % card_html(c)
        if why:
            b += '<div class="why">%s</div>' % c["target"].replace("_", " ")
        b += "</div>"
    return b + "</div>"

def cards_page(title, src, group, sections, note, lead=""):
    b = ""
    if lead:
        b += '<div class="note">%s</div>' % lead
    for head, sub, cards in sections:
        b += "<h2>%s<span>%s</span></h2>" % (head, sub)
        b += card_row(cards, why=True)
    return page(title, src, group, b, GRID_CSS, stage_h=0, note=note)

def s_cards_neutral():
    return cards_page(
        "Cards — Neutral", "scripts/combat/card_db.gd · REWARD_POOL", "Cards",
        [("Chassis", "in every starting deck · the unit everything is read against", CHASSIS),
         ("Reward pool", "any dwarf can learn these — REWARD_POOL, offered on loot tiles", POOL)],
        "13 cards — the shared chassis + the universal reward pool",
        "<b>Neutral</b> = role-agnostic. The four chassis cards seed every deck; the nine pool cards are "
        "what a dwarf can <i>learn</i> from a spoils tile, regardless of class. Anything you add here "
        "must be castable by a Warrior, a Cleric and a Sorcerer without reading strangely.")

def s_cards_class():
    return cards_page(
        "Cards — Class", "scripts/combat/card_db.gd · CLASSES + CLASS_REWARDS", "Cards",
        [("\U0001f6e1️ Warrior — signature", "ships in the deck · tank, 36 hp, 3 energy", WARRIOR_SIG),
         ("\U0001f6e1️ Warrior — reward", "CLASS_REWARDS · offered only if a Warrior is on the tile", WARRIOR_REW),
         ("⛑️ Cleric — signature", "ships in the deck · support, 28 hp, 3 energy", CLERIC_SIG),
         ("⛑️ Cleric — reward", "CLASS_REWARDS · Devotion / Oath line", CLERIC_REW),
         ("\U0001f9d9 Sorcerer — signature", "ships in the deck · dps, 22 hp, 3 energy", SORC_SIG),
         ("\U0001f9d9 Sorcerer — reward", "CLASS_REWARDS · Surge / Wild Magic line", SORC_REW)],
        "18 cards — role-locked, 6 per class",
        "<b>Class</b> cards are role-locked: they never enter REWARD_POOL, and a spoils tile only offers "
        "them when a dwarf of that class is standing on it. This is the axis that makes two runs of the "
        "same party feel different — keep each class's three signatures pointed at its pillar "
        "(Warrior = bait &amp; punish, Cleric = keep the party up, Sorcerer = multiply one big hit).")

def s_card_lab():
    ops = [
        ("dmg / damage", "v", "Deal v to the target enemy. Marks the card as an attack."),
        ("dmg_all", "v", "Deal v to EVERY enemy."),
        ("dmg_per_momentum", "v", "+v per attack already played by this dwarf this turn."),
        ("damage_scaling", "attacks_this_turn, base, per", "base + per × party-wide attacks this turn."),
        ("block", "v", "Active dwarf gains v block (+5 if Fortify is pending and the card is <code>fortifiable</code>)."),
        ("party_block", "v", "Every ally gains v block."),
        ("retain_block", "—", "This block does NOT expire next turn."),
        ("heal_self / heal_ally", "v", "Restore v HP to self / a chosen ally."),
        ("heal_or_damage", "v", "Tap an ally → heal v; tap an enemy → deal v."),
        ("self_dmg / self_damage", "v", "Active dwarf loses v HP (Bloodied enabler)."),
        ("draw", "n", "Active dwarf draws n."),
        ("gain_energy", "n", "Refund n energy."),
        ("apply", "\"burn\", n", "\U0001f525 n Burn — ticks at enemy-turn start, ignores block, decays 1."),
        ("apply", "\"vulnerable\", n", "\U0001f4a5 Vulnerable — target takes ×1.5, decays 1/turn."),
        ("apply_status", "\"marked\"", "\U0001f3af Mark — +25%. The ONLY multiplier. Stacks × with Vulnerable."),
        ("buff_next_attack", "v", "This dwarf's next attack this turn deals +v."),
        ("next_card_double", "—", "✨ The next card's numbers are doubled."),
        ("temp", "\"channel\", per, charges", "\U0001f300 The next <i>charges</i> attacks deal +per each."),
        ("temp", "\"retaliate\", v", "\U0001f501 Reflect v to anything that hits you (through the enemy phase)."),
        ("temp", "\"fortify\"", "\U0001f527 Next Guard +5 block; Retaliate +2 while active."),
        ("shield_ally", "v", "\U0001f530 Chosen ally takes −v per hit (flat, through the enemy phase)."),
        ("party_buff", "\"attack\", v", "\U0001f4e3 Every ally's attacks deal +v this turn."),
        ("force_target_all", "\"warrior\"", "\U0001f621 All enemies re-target the Warrior next enemy phase."),
        ("if_bloodied", "[ops]", "Run ops only if the dwarf is at or below half HP."),
        ("if_target_marked", "[ops]", "Run ops only if the target carries \U0001f3af Mark."),
        ("spend_devotion", "[ops]", "Run ops if 1 \U0001f64f Devotion can be spent (built by playing skills)."),
        ("on_kill", "[ops]", "Run ops only if this card killed the target."),
    ]
    b = ('<div class="note">This is the bench. Drop a new card into a blank slot, then wire it from the '
         "vocabulary below — <b>every op here already exists</b> in <code>combat.gd::_run_ops</code>, so a "
         "card built only from these needs <i>zero</i> new engine code: it is a pure data addition to "
         "<code>card_db.gd::CARDS</code>.</div>")
    b += "<h2>Blank slots<span>neutral — must read cleanly on all three classes</span></h2>"
    b += '<div class="row">' + '<div class="slot"><div class="blank">+</div>'\
         '<div class="why">neutral</div></div>' * 5 + "</div>"
    b += "<h2>Blank slots<span>class — role-locked, must point at that class's pillar</span></h2>"
    b += '<div class="row">'
    for cl, emo, pill in [("warrior", "\U0001f6e1️", "bait &amp; punish"),
                          ("cleric", "⛑️", "keep them up"),
                          ("sorcerer", "\U0001f9d9", "multiply one hit")]:
        for _ in range(2):
            b += ('<div class="slot"><div class="blank" style="border-color:%s">%s</div>'
                  '<div class="why">%s</div></div>' % (CLASS_COL[cl], emo, pill))
    b += "</div>"
    b += "<h2>Frame tint = card type<span>the tint IS the promise — never mix it</span></h2>"
    b += ('<div class="key">'
          '<span class="chip a">attack · #752424 · deals damage, feeds Channel/Aura/Momentum</span>'
          '<span class="chip s">skill · #21426b · everything else, builds Devotion</span>'
          '<span class="chip p">power · #572b75 · changes the rules of this turn</span>'
          "</div>")
    b += "<h2>Op vocabulary<span>combat.gd::_run_ops — the whole executable surface</span></h2>"
    b += "<table><tr><th>op</th><th>args</th><th>what it does</th></tr>"
    for o, a, d in ops:
        b += "<tr><td><code>%s</code></td><td><code>%s</code></td><td>%s</td></tr>" % (o, a, d)
    b += "</table>"
    b += "<h2>House rules<span>break these and the card will not read</span></h2>"
    b += ('<div class="note"><b>1. Mark is the only multiplier.</b> \U0001f3af +25% (and enemy-side '
          "\U0001f4a5 Vulnerable ×1.5). Everything else is flat, or the numbers stop being legible.<br>"
          "<b>2. Resolution order is fixed:</b> base → +flat (Channel, Aura, Whetstone) → "
          "×Mark → block → hp → Retaliate. Write the card so it reads correctly in that order.<br>"
          "<b>3. Cost is the honest brake.</b> 0 = tempo, 1 = the norm, 2 = a real commitment. There is no 3.<br>"
          "<b>4. Live numbers on the face.</b> <code>Db.describe()</code> renders the body — if your card's "
          "value changes with state, it must show the <i>current</i> value, in green, on the card.<br>"
          "<b>5. Neutral must be class-blind.</b> If it only makes sense on one dwarf, it belongs in "
          "CLASS_REWARDS, not REWARD_POOL.</div>")
    return page("Card Lab — blank workspace", "scripts/combat/card_db.gd", "Card Lab", b, GRID_CSS,
                stage_h=0, note="Bench + the full op vocabulary — build a card, add zero engine code")

# ================================================================ TANK ROLE (draft direction, 2026-07-15)
# Two-layer model: role = shared substrate (Guard), class = one signature that bends it.
STRIKE = CHASSIS[0]
BARB = [
    C("reckless_swing", "Reckless Swing", 1, "\U0001fa93", "attack", "enemy", ["Deal 12", "Lose 3 HP"], ""),
    C("blood_for_blood", "Blood for Blood", 1, "\U0001fa78", "attack", "enemy", ["Deal 7", "Bloodied: 14"], ""),
    C("thick_hide", "Thick Hide", 1, "\U0001f417", "skill", "self", ["Gain 6 Guard", "Bloodied: +6"], ""),
    C("bellow", "Bellow", 1, "\U0001f4e2", "skill", "self", ["Enemies target you", "Gain 4 Guard"], ""),
    C("rampage", "Rampage", 2, "\U0001f44a", "attack", "all_enemies", ["Deal 8 to ALL"], ""),
    STRIKE,
]
FIGHTER = [
    C("shield_up", "Shield Up", 1, "\U0001f6e1️", "skill", "self", ["Gain 8 Guard"], ""),
    C("sidestep", "Sidestep", 1, "↩️", "skill", "self", ["Gain 5 Guard", "Draw 1"], ""),
    C("riposte", "Riposte", 1, "⚡", "skill", "self", ["Reflect 5 when hit"], ""),
    C("shield_bash", "Shield Bash", 1, "\U0001f528", "attack", "enemy", ["Deal 6", "+1 / 4 Guard"], ""),
    C("reforge", "Reforge", 0, "\U0001f50b", "skill", "self", ["Next card: pay", "with Guard, not ⚡"], ""),
    C("whirlwind", "Whirlwind", "X", "\U0001f32a️", "attack", "all_enemies", ["Deal X to ALL", "X = ⚡ spent"], ""),
    C("hold_the_line", "Hold the Line", 2, "\U0001f9f1", "skill", "party", ["All allies +4 Guard"], ""),
    STRIKE,
]
PALADIN = [
    C("lay_on_hands", "Lay on Hands", 1, "\U0001f64c", "skill", "ally", ["Heal ally 8", "Bank \U0001f64f"], ""),
    C("consecrate", "Consecrate", 1, "\U0001f56f️", "skill", "party", ["All allies +4 block", "Bank \U0001f64f"], ""),
    C("aura_of_valor", "Aura of Valor", 2, "\U0001f4e3", "power", "self", ["All allies +2 attack"], ""),
    C("shield_of_faith", "Shield of Faith", 1, "\U0001f530", "skill", "ally", ["Ally −3 / hit", "Bank \U0001f64f"], ""),
    C("vow_of_wrath", "Vow of Wrath", 1, "⚔️", "skill", "self", ["Gain 4 Guard", "Next Smite +4"], ""),
    STRIKE,
]

def s_cards_roles():
    css = GRID_CSS + """
.sub{width:100%;max-width:1180px;margin:26px 0 4px;border-radius:12px;padding:16px 20px;
  background:linear-gradient(135deg,#2a2620,#181820);border:1px solid #4a3f2a}
.sub h3{font-size:17px;letter-spacing:.03em;color:#f2bd33;margin-bottom:5px}
.sub p{font-size:12.5px;color:#c7c3b8;line-height:1.55;max-width:1010px}
.sub code{font-family:ui-monospace,Consolas,monospace;color:#e0b96b;font-size:11.5px}
.sub .rk{display:inline-block;font-size:10.5px;letter-spacing:.08em;color:#e6c98a;
  border:1px solid #6a5a38;border-radius:99px;padding:2px 10px;margin-top:9px}
.cls{width:100%;max-width:1180px;background:#16161d;border:1px solid #2c2c38;border-radius:12px;
  padding:16px 18px 18px;margin:12px 0;display:flex;flex-direction:column;gap:13px}
.cls .hd{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
.cls .hd .e{font-size:30px;position:relative;top:5px}
.cls .hd b{font-size:19px;color:#fff}
.cls .hd span{color:#8b8b99;font-size:12px}
.res2{font-size:12.5px;color:#a8a8b8;line-height:1.5;max-width:1010px}
.res2 b{color:#c7c7d1}
.mid{display:flex;gap:22px;flex-wrap:wrap;align-items:flex-start}
.wg{width:252px;background:#12121a;border:1px solid #2c2c38;border-radius:8px;padding:11px 13px}
.wgl{font-size:11px;letter-spacing:.10em;color:#8b8b99;margin-bottom:7px}
.bar{height:14px;border-radius:7px;background:#2a2a34;overflow:hidden}
.bar .fill{height:100%}
.wgt{font-size:11.5px;color:#c7c7d1;margin-top:8px;line-height:1.45}
.pips{font-size:20px;letter-spacing:4px}
.soon{opacity:.62}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:9px}
.cc{font-size:12px;padding:4px 11px;border-radius:99px;border:1px solid #34343f;color:#c7c7d1;background:#1c1c24}
.cc b{color:#e6e7ea}
/* the class ACTIVE (hero-power-style clickable) */
.active{width:100%;border-radius:10px;padding:13px 15px;background:linear-gradient(135deg,#241d2e,#17131d);
  border:1px solid #5a3f6a;display:flex;gap:15px;align-items:center}
.aorb{width:58px;height:58px;border-radius:50%;flex:0 0 auto;display:flex;align-items:center;justify-content:center;
  font-size:29px;background:radial-gradient(circle at 40% 33%,#43335a,#1a1420);border:2px solid #9a7ab8;
  box-shadow:0 0 16px rgba(150,100,200,.4)}
.ainfo{flex:1;min-width:0}
.an{font-size:16px;color:#e9dcf7;font-weight:600}
.an .lbl{font-size:10.5px;letter-spacing:.10em;color:#9a7ab8;margin-right:8px}
.an .gate{font-size:11px;color:#c7a8dd;font-weight:400;margin-left:8px;border:1px solid #6a4f7a;
  border-radius:99px;padding:2px 9px}
.ae{font-size:12.5px;color:#c9bdd6;line-height:1.5;margin-top:5px}
.fire{font-size:11px;color:#9a86b0;margin-top:6px}
/* skill-tree teaser: the active is the root node */
.tree{display:flex;align-items:center;gap:0;flex-wrap:wrap}
.troot{font-size:12.5px;color:#e9dcf7;background:#2a2038;border:1px solid #7a5a90;border-radius:8px;
  padding:7px 12px;font-weight:600}
.tconn{width:24px;height:2px;background:#4a3f5a}
.tbranch{display:flex;flex-direction:column;gap:6px}
.tnode{font-size:11.5px;color:#a89ab8;background:#161320;border:1px dashed #4a3f5a;border-radius:8px;padding:6px 11px}
.tnode .lk{margin-right:6px;opacity:.7}
.tnode b{color:#cbb8e0;font-weight:600}
.treelbl{font-size:10.5px;letter-spacing:.08em;color:#8b8b99;margin:2px 0 -2px}
/* combat portrait mock with the Class Power orb */
.combatrow{display:flex;gap:24px;flex-wrap:wrap;margin-top:11px}
.port{width:152px;text-align:center;background:#12121a;border:1px solid #2c2c38;border-radius:10px;padding:13px 8px 11px;position:relative}
.port .pe{font-size:44px;line-height:1}
.port .pn{font-size:13px;color:#e6e7ea;margin-top:3px}
.port .po{margin:9px auto 0;width:46px;height:46px;border-radius:50%;display:flex;align-items:center;justify-content:center;
  font-size:22px;background:radial-gradient(circle at 40% 33%,#43335a,#1a1420);border:2px solid #9a7ab8;
  box-shadow:0 0 12px rgba(150,100,200,.45)}
.port .pg{font-size:10.5px;color:#c0a0d8;margin-top:6px;line-height:1.4}
"""
    def block(e, name, kit, sub, active, feeds, cards, widget):
        h = '<div class="cls"><div class="hd"><span class="e">%s</span><b>%s</b>' % (e, name)
        h += '<span>&nbsp;·&nbsp; %s &nbsp;·&nbsp; %s</span></div>' % (kit, sub)
        # the CLASS POWER — the class's clickable signature
        h += '<div class="active"><div class="aorb">%s</div><div class="ainfo">' % active["icon"]
        h += '<div class="an"><span class="lbl">CLASS POWER</span>%s<span class="gate">%s</span></div>' % (active["name"], active["gate"])
        h += '<div class="ae">%s</div>' % active["effect"]
        h += '<div class="fire">▸ tap your dwarf’s Class Power in combat to fire it</div></div></div>'
        # what feeds the Class Power (the resource / passive)
        h += '<div class="res2"><b>Feeds it:</b> %s</div>' % feeds
        # skill-tree teaser: the Class Power is the root
        h += '<div class="treelbl">SKILL TREE (post-MVP) — the Class Power is the root node</div><div class="tree">'
        h += '<div class="troot">✦ %s</div><div class="tconn"></div><div class="tbranch">' % active["name"]
        for t in active["tree"]:
            h += '<div class="tnode"><span class="lk">\U0001f512</span>%s</div>' % t
        h += '</div></div>'
        # cards + fuel-gauge widget
        h += '<div class="mid"><div class="row" style="max-width:770px">'
        for c in cards:
            h += '<div class="slot">%s</div>' % card_html(c)
        h += '</div>%s</div></div>' % widget
        return h

    b = ('<div class="note"><b>Draft direction (2026-07-15).</b> Every class has a <b>Class Power</b> — a '
         "clickable ability you fire by tapping your dwarf, separate from playing a card. Three layers: the "
         "<b>role</b> is a shared <i>substrate</i> (a resource), the <b>class</b> is one <i>Class Power</i> "
         "(gated by a <b>cooldown</b>) that spends or triggers it, and a <b>skill tree</b> (post-MVP) upgrades "
         "that power. Same engine per role, distinct verb per class. This is the <b>Tank</b> sheet — "
         "<b>Support</b> and <b>DPS</b> each have their own sheet now. Numbers are unsimmed placeholders.</div>")

    b += ('<div class="sub"><h3>\U0001f6e1️ TANK — the Guard substrate</h3>'
          "<p><b>Guard</b> is a stacking resource every tank builds by playing cards. It <b>soaks</b> like "
          "block and <b>pulls threat</b> — enemies already target the tankiest dwarf, so stacking Guard is how "
          "a tank volunteers to eat the hit. The cards <i>build</i> the resource; the <b>Class Power spends "
          "it</b>, differently per class: the Barbarian trades it for a rage stance (block → damage-resistance), "
          "the Fighter cashes a tempo burst, the Paladin discharges banked holy charge. Guard/Devotion live on "
          "the party dict, host-side, so both the meter and the power ride the snapshot.</p>"
          "<span class=\"rk\">BUILT — draft, unsimmed</span></div>")

    b += ('<div class="sub" style="background:#181622;border-color:#3a2f4a"><h3 style="color:#c295e0">'
          "\U0001f7e3 In combat: the Class Power</h3>"
          "<p>Each dwarf carries its <b>Class Power</b> as an orb on its portrait — a Hearthstone-style hero "
          "power. Tap your own dwarf to fire it; the orb shows the gate (its cooldown, or the resource it "
          "spends). This is a <b>second lever</b> beside the hand: cards build the resource, the Class Power "
          "spends it. In co-op you only ever fire your own.</p>"
          '<div class="combatrow">'
          '<div class="port"><div class="pe">\U0001fa93</div><div class="pn">Barbarian</div>'
          '<div class="po">\U0001f624</div><div class="pg">Enrage<br>stance · attack to keep</div></div>'
          '<div class="port"><div class="pe">\U0001f6e1️</div><div class="pn">Fighter</div>'
          '<div class="po">⏱️</div><div class="pg">Action Surge<br>4-turn cooldown</div></div>'
          '<div class="port"><div class="pe">\U0001f31f</div><div class="pn">Paladin</div>'
          '<div class="po">\U0001f31f</div><div class="pg">Divine Smite<br>3-turn cooldown</div></div>'
          "</div></div>")

    b += block(
        "\U0001fa93", "Barbarian", "Reaver's Kit", "34 hp · 3 energy",
        {"icon": "\U0001f624", "name": "Enrage", "gate": "stance · attack each turn to hold · long cooldown if it drops",
         "effect": "Enter a rage. While raging you take <b>HALF damage</b>, deal <b>+4 while Bloodied</b> "
                   "(under half HP), and can <b>no longer gain Guard</b> — resistance replaces your block. "
                   "Rage holds only while you attack at least once each turn; skip a turn and it drops, locked "
                   "out for <b>4 turns</b>.",
         "tree": ["<b>Unbridled</b> — half damage from ALL sources, not just attacks",
                  "<b>Bloodthirst</b> — the low-HP bonus rises to +8; a kill re-arms the upkeep",
                  "<b>Tireless Rage</b> — a missed attack no longer drops rage"]},
        "Guard, built by cards <b>when you’re not raging</b> — your turtle stance and threat-pull. Enrage flips "
        "to the fury stance: Guard is suspended, but half-damage resistance and the low-HP bonus take over. "
        "The game is bouncing between the two.",
        BARB,
        '<div class="wg"><div class="wgl">CLASS POWER — ENRAGE</div>'
        '<div class="pips" style="font-size:15px"><span style="color:#eb4242">\U0001f525 RAGING</span></div>'
        '<div class="wgt">½ damage taken · +4 while Bloodied · no Guard gain<br>'
        '<span style="color:#f2bd33">⚠ attack each turn or it drops → 4-turn cooldown</span></div></div>')

    b += block(
        "\U0001f6e1️", "Fighter", "Shieldwall Kit", "38 hp · 3 energy",
        {"icon": "⏱️", "name": "Action Surge", "gate": "4-turn cooldown · free",
         "effect": "<b>+2 energy this turn and draw 1</b> — the tempo burst that empties your hand in one turn "
                   "and breaks a stall, then a 4-turn cooldown before the wall can surge again.",
         "tree": ["<b>Overdrive</b> — +3 energy instead of +2",
                  "<b>Second Wind</b> — Surge also grants 8 Guard",
                  "<b>Relentless</b> — dropping below half HP resets the cooldown"]},
        "Guard, built by cards and <b>spent</b>, never hoarded — <b>Shield Bash</b> cashes it as damage, and "
        "<b>Reforge</b> turns it into mana for your next card (pour it into an <b>X-cost Whirlwind</b> to hit "
        "the whole board). Action Surge is the tempo release valve.",
        FIGHTER,
        '<div class="wg"><div class="wgl">GUARD — spend it, don’t hoard</div>'
        '<div class="bar"><div class="fill" style="width:74%;background:#5f8ad9"></div></div>'
        '<div class="wgt">\U0001f6e1️ soaks this turn · spend as damage (Shield Bash) or mana (Reforge → Whirlwind)<br>'
        '<span style="color:#4dd16b">⏱️ Action Surge ready</span></div></div>')

    b += block(
        "\U0001f31f", "Paladin", "Oath Kit", "34 hp · 3 energy",
        {"icon": "\U0001f31f", "name": "Divine Smite", "gate": "3-turn cooldown · spends banked \U0001f64f · target an enemy",
         "effect": "Deal <b>6 + 4 per Devotion</b> spent to an enemy, and all allies gain 3 block. On a "
                   "<b>3-turn cooldown</b> — so bank Devotion hard between casts and the smite you save up hits "
                   "for more.",
         "tree": ["<b>Radiant</b> — Smite also applies Vulnerable \U0001f4a5",
                  "<b>Zeal</b> — Smite also heals the party 4",
                  "<b>Conviction</b> — every skill banks 2 \U0001f64f"]},
        "Devotion \U0001f64f — every skill banks 1. The <b>pips are your Smite charge</b>. The 3-turn cooldown "
        "sets the rhythm; how much you banked in between sets the size.",
        PALADIN,
        '<div class="wg"><div class="wgl">DEVOTION — Smite charge</div>'
        '<div class="pips"><span style="color:#f2bd33">\U0001f64f\U0001f64f\U0001f64f</span>'
        '<span style="color:#3a3a46">○○</span></div>'
        '<div class="wgt">\U0001f31f Divine Smite → spend 3 for 18 · then 3-turn cooldown</div></div>')

    b += ('<div class="sub" style="background:#181820;border-color:#34343f"><h3 style="color:#a8a8b8">'
          "\U0001f4ff SUPPORT · ⚔️ DPS — now their own sheets</h3>"
          "<p>The other two roles are built out on their own spec sheets, same shape as this one:</p>"
          '<div class="chips">'
          '<span class="cc"><b>\U0001f4ff Support</b> — Communion → Cleric <i>Channel Divinity</i> · Bard '
          '<i>Bardic Performance</i> · Druid <i>Wild Shape</i> &nbsp;→&nbsp; <code>cards/support.html</code></span>'
          '<span class="cc"><b>⚔️ DPS</b> — the party charges it → Sorcerer <i>Metamagic</i> · Rogue '
          '<i>Assassin’s Mark</i> · Monk <i>Flurry of Blows</i> &nbsp;→&nbsp; <code>cards/dps.html</code>'
          "</span></div>"
          "<p style=\"margin-top:9px;color:#8b8b99\">Ranger (Hunter’s Mark) and Wizard are held as future "
          "signatures — the substrate carries them when they’re built.</p></div>")

    b += ('<div class="sub" style="background:#141821;border-color:#2c3340"><h3 style="color:#8fb4e0">'
          "The build cost — what Tank adds to combat</h3>"
          "<p><b>The Class Power is the one genuinely new system:</b> a per-dwarf <code>power</code> + "
          "<code>power_cd</code> (turns remaining) on the party dict — it rides the snapshot, and the host "
          "ticks every cooldown down one at the start of each player phase. A tap-your-portrait input routes "
          "to a host-side <code>_fire_power(seat)</code> that checks the cooldown and resolves; in co-op the "
          "tap is an intent the host validates, exactly like a card play.<br><br>"
          "<b>Enrage is a stance, so it needs a bit more:</b> a <code>raging</code> flag (halves incoming "
          "damage, blocks <code>gain_guard</code>, adds the Bloodied bonus) and an <b>upkeep check</b> at "
          "end of turn — if <code>attacked_this_turn</code> is false, rage drops and <code>power_cd</code> "
          "jumps to 4. Action Surge and Divine Smite just set <code>power_cd</code> on use (4 and 3).<br><br>"
          "<b>New ops:</b> <code>gain_guard v</code> (Guard joins the threat/targeting read) · "
          "<code>dmg_per_guard</code> (Fighter Shield Bash) · <code>pay_with_guard</code> (Reforge: the next "
          "card’s cost is drawn from Guard, not energy) · <b>X-cost</b> support (cost <code>\"X\"</code> spends "
          "all energy — or all Guard, via Reforge — and Whirlwind deals that much to every enemy) · plus the "
          "three power effects (<code>enrage</code> / <code>action_surge</code> / <code>smite</code>). "
          "<b>Reused as-is:</b> dmg, "
          "block, self_dmg, if_bloodied, draw, gain_energy, temp/retaliate, party_block, party_buff, "
          "shield_ally, spend_devotion, force_target_all. Promoting Frenzy / Action Surge / Divine Smite from "
          "cards to powers kept the card packs lean.</p></div>")

    return page("Cards — Class · class powers + skill trees", "card_db.gd · STARTER_PACKS (draft)", "Cards", b, css,
                stage_h=0, note="Each class a Class Power (Enrage / Action Surge / Divine Smite) + a skill-tree root")

# ================================================================ SUPPORT + DPS ROLES (2026-07-15)
# Same two-layer model as the Tank sheet, extracted to module level so all three role sheets share it.
ROLE_CSS = GRID_CSS + """
.sub{width:100%;max-width:1180px;margin:26px 0 4px;border-radius:12px;padding:16px 20px;
  background:linear-gradient(135deg,#2a2620,#181820);border:1px solid #4a3f2a}
.sub h3{font-size:17px;letter-spacing:.03em;color:#f2bd33;margin-bottom:5px}
.sub p{font-size:12.5px;color:#c7c3b8;line-height:1.55;max-width:1010px}
.sub code{font-family:ui-monospace,Consolas,monospace;color:#e0b96b;font-size:11.5px}
.sub .rk{display:inline-block;font-size:10.5px;letter-spacing:.08em;color:#e6c98a;
  border:1px solid #6a5a38;border-radius:99px;padding:2px 10px;margin-top:9px}
.cls{width:100%;max-width:1180px;background:#16161d;border:1px solid #2c2c38;border-radius:12px;
  padding:16px 18px 18px;margin:12px 0;display:flex;flex-direction:column;gap:13px}
.cls .hd{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
.cls .hd .e{font-size:30px;position:relative;top:5px}
.cls .hd b{font-size:19px;color:#fff}
.cls .hd span{color:#8b8b99;font-size:12px}
.res2{font-size:12.5px;color:#a8a8b8;line-height:1.5;max-width:1010px}
.res2 b{color:#c7c7d1}
.mid{display:flex;gap:22px;flex-wrap:wrap;align-items:flex-start}
.wg{width:252px;background:#12121a;border:1px solid #2c2c38;border-radius:8px;padding:11px 13px}
.wgl{font-size:11px;letter-spacing:.10em;color:#8b8b99;margin-bottom:7px}
.bar{height:14px;border-radius:7px;background:#2a2a34;overflow:hidden}
.bar .fill{height:100%}
.wgt{font-size:11.5px;color:#c7c7d1;margin-top:8px;line-height:1.45}
.pips{font-size:20px;letter-spacing:4px}
.soon{opacity:.62}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:9px}
.cc{font-size:12px;padding:4px 11px;border-radius:99px;border:1px solid #34343f;color:#c7c7d1;background:#1c1c24}
.cc b{color:#e6e7ea}
.active{width:100%;border-radius:10px;padding:13px 15px;background:linear-gradient(135deg,#241d2e,#17131d);
  border:1px solid #5a3f6a;display:flex;gap:15px;align-items:center}
.aorb{width:58px;height:58px;border-radius:50%;flex:0 0 auto;display:flex;align-items:center;justify-content:center;
  font-size:29px;background:radial-gradient(circle at 40% 33%,#43335a,#1a1420);border:2px solid #9a7ab8;
  box-shadow:0 0 16px rgba(150,100,200,.4)}
.ainfo{flex:1;min-width:0}
.an{font-size:16px;color:#e9dcf7;font-weight:600}
.an .lbl{font-size:10.5px;letter-spacing:.10em;color:#9a7ab8;margin-right:8px}
.an .gate{font-size:11px;color:#c7a8dd;font-weight:400;margin-left:8px;border:1px solid #6a4f7a;
  border-radius:99px;padding:2px 9px}
.ae{font-size:12.5px;color:#c9bdd6;line-height:1.5;margin-top:5px}
.fire{font-size:11px;color:#9a86b0;margin-top:6px}
.tree{display:flex;align-items:center;gap:0;flex-wrap:wrap}
.troot{font-size:12.5px;color:#e9dcf7;background:#2a2038;border:1px solid #7a5a90;border-radius:8px;
  padding:7px 12px;font-weight:600}
.tconn{width:24px;height:2px;background:#4a3f5a}
.tbranch{display:flex;flex-direction:column;gap:6px}
.tnode{font-size:11.5px;color:#a89ab8;background:#161320;border:1px dashed #4a3f5a;border-radius:8px;padding:6px 11px}
.tnode .lk{margin-right:6px;opacity:.7}
.tnode b{color:#cbb8e0;font-weight:600}
.treelbl{font-size:10.5px;letter-spacing:.08em;color:#8b8b99;margin:2px 0 -2px}
.combatrow{display:flex;gap:24px;flex-wrap:wrap;margin-top:11px}
.port{width:152px;text-align:center;background:#12121a;border:1px solid #2c2c38;border-radius:10px;padding:13px 8px 11px;position:relative}
.port .pe{font-size:44px;line-height:1}
.port .pn{font-size:13px;color:#e6e7ea;margin-top:3px}
.port .po{margin:9px auto 0;width:46px;height:46px;border-radius:50%;display:flex;align-items:center;justify-content:center;
  font-size:22px;background:radial-gradient(circle at 40% 33%,#43335a,#1a1420);border:2px solid #9a7ab8;
  box-shadow:0 0 12px rgba(150,100,200,.45)}
.port .pg{font-size:10.5px;color:#c0a0d8;margin-top:6px;line-height:1.4}
"""

def role_block(e, name, kit, sub, active, feeds, cards, widget):
    """One class panel: Class Power + skill-tree teaser + card row + fuel gauge. Shared by all roles."""
    h = '<div class="cls"><div class="hd"><span class="e">%s</span><b>%s</b>' % (e, name)
    h += '<span>&nbsp;·&nbsp; %s &nbsp;·&nbsp; %s</span></div>' % (kit, sub)
    h += '<div class="active"><div class="aorb">%s</div><div class="ainfo">' % active["icon"]
    h += '<div class="an"><span class="lbl">CLASS POWER</span>%s<span class="gate">%s</span></div>' % (
        active["name"], active["gate"])
    h += '<div class="ae">%s</div>' % active["effect"]
    h += '<div class="fire">▸ tap your dwarf\'s Class Power in combat to fire it</div></div></div>'
    h += '<div class="res2"><b>Feeds it:</b> %s</div>' % feeds
    h += '<div class="treelbl">SKILL TREE (post-MVP) — the Class Power is the root node</div><div class="tree">'
    h += '<div class="troot">✦ %s</div><div class="tconn"></div><div class="tbranch">' % active["name"]
    for t in active["tree"]:
        h += '<div class="tnode"><span class="lk">\U0001f512</span>%s</div>' % t
    h += '</div></div>'
    h += '<div class="mid"><div class="row" style="max-width:770px">'
    for c in cards:
        h += '<div class="slot">%s</div>' % card_html(c)
    h += '</div>%s</div></div>' % widget
    return h

def combat_row_box(portraits, accent="#c295e0", fuel=None):
    """The 'In combat: the Class Power' explainer + a row of portrait orbs.

    fuel overrides the sentence describing what the orb's gate reads. The default assumes
    a cooldown or a spent resource, which is true on Tank and Support and false on DPS.
    """
    if fuel is None:
        fuel = ("the orb shows the gate (its cooldown, or the resource it spends). Cards build the "
                "resource, the Class Power spends it.")
    h = ('<div class="sub" style="background:#181622;border-color:#3a2f4a"><h3 style="color:%s">'
         "\U0001f7e3 In combat: the Class Power</h3>"
         "<p>Each dwarf carries its <b>Class Power</b> as an orb on its portrait — a Hearthstone-style hero "
         "power. Tap your own dwarf to fire it; %s In co-op you only ever fire your "
         "own.</p><div class=\"combatrow\">") % (accent, fuel)
    for pe, pn, po, pg in portraits:
        h += ('<div class="port"><div class="pe">%s</div><div class="pn">%s</div>'
              '<div class="po">%s</div><div class="pg">%s</div></div>' % (pe, pn, po, pg))
    return h + "</div></div>"

# ---- Support card kits (Communion substrate) ----
S_CLERIC = [
    # heal-side casts (skills/powers feed the aura's MERCY charge)
    C("mend", "Mend", 1, "\U0001f64c", "skill", "ally", ["Heal ally 8", "\U0001f64f mercy cast"], ""),
    C("bless", "Bless", 1, "✨", "skill", "party", ["All allies +3 block", "\U0001f64f mercy cast"], ""),
    C("sanctuary", "Sanctuary", 1, "\U0001f530", "skill", "ally", ["Ally −3 / hit", "\U0001f64f mercy cast"], ""),
    # smite-side casts (attacks feed the aura's SMITE charge)
    C("censure", "Censure", 1, "\U0001f4a5", "attack", "enemy", ["Deal 6", "\U0001f525 smite cast"], ""),
    C("searing_word", "Searing Word", 1, "☀️", "attack", "enemy", ["Deal 5", "Apply 2 \U0001f525"], ""),
    STRIKE,
]
S_BARD = [
    C("mockery", "Vicious Mockery", 1, "\U0001f3ad", "attack", "enemy", ["Deal 4", "Apply Vulnerable \U0001f4a5"], ""),
    C("inspiration", "Inspiration", 1, "\U0001f3b5", "skill", "ally", ["Ally’s next card +4", "Bank \U0001f4ff"], ""),
    C("crescendo", "Crescendo", 1, "\U0001f3b6", "power", "party", ["All allies +2 attack", "Bank \U0001f4ff"], ""),
    C("refrain", "Refrain", 0, "\U0001f501", "skill", "self", ["Draw 1", "Free 3rd target"], ""),
    C("ballad", "Ballad", 2, "\U0001f4ef", "skill", "party", ["Heal all allies 5", "Bank \U0001f4ff"], ""),
    STRIKE,
]
S_DRUID = [
    C("forage", "Forage", 1, "\U0001f330", "skill", "self", ["Shuffle 1 back", "Draw 2", "Bank \U0001f4ff"], ""),
    C("regrowth", "Regrowth", 1, "\U0001f343", "skill", "ally", ["Heal ally 6", "+4 next turn"], ""),
    C("barkskin", "Barkskin", 1, "\U0001f333", "skill", "party", ["All allies +4 block", "Bank \U0001f4ff"], ""),
    C("entangle", "Entangle", 1, "\U0001f578️", "attack", "all_enemies", ["Deal 4 to ALL", "Apply Vulnerable"], ""),
    C("maul", "Maul", 1, "\U0001f43b", "attack", "enemy", ["Deal 6", "\U0001f43a Wolf: 10"], ""),
    STRIKE,
]
# ---- DPS card kits (Momentum substrate) ----
D_SORC = [
    C("mark_d", "Mark", 1, "\U0001f3af", "skill", "enemy", ["Mark: +25% dmg taken", "\U0001f9ff spell"], ""),
    C("channel_d", "Channel", 1, "\U0001f300", "power", "self", ["Next 2 attacks +3", "\U0001f9ff spell"], ""),
    C("bolt", "Bolt", 1, "⚡", "attack", "enemy", ["Deal 6", "\U0001f9ff spell"], ""),
    C("arc_lightning_d", "Arc Lightning", 2, "\U0001f329️", "attack", "enemy",
      ["Deal 9", "Deal 4 to ALL", "\U0001f9ff spell"], ""),
    C("finisher_d", "Arcane Finisher", 2, "\U0001f4a5", "attack", "enemy",
      ["Deal 5", "+3 per attack", "\U0001f9ff spell"], ""),
    STRIKE,
]
D_ROGUE = [
    C("backstab", "Backstab", 1, "\U0001f5e1️", "attack", "enemy", ["Deal 6", "Marked: +6", "⚔️ physical"], ""),
    C("shiv", "Shiv", 0, "\U0001f52a", "attack", "enemy", ["Deal 3", "Marked: +2 tick", "⚔️ physical"], ""),
    C("shadowstep", "Shadowstep", 0, "\U0001f4a8", "skill", "self", ["Gain 1 ⚡", "Next attack +4"], ""),
    C("poison_blade", "Poison Blade", 1, "\U0001f9ea", "attack", "enemy",
      ["Deal 4", "Apply 3 \U0001f525", "⚔️ physical"], ""),
    C("fan_of_knives", "Fan of Knives", 2, "\U0001f52a", "attack", "all_enemies",
      ["Deal 6 to ALL", "⚔️ physical"], ""),
    STRIKE,
]
D_MONK = [
    C("jab", "Jab", 0, "\U0001f44a", "attack", "enemy", ["Deal 3", "Gain 1 ⚡", "⚔️ physical"], ""),
    C("stunning_strike", "Stunning Strike", 1, "\U0001f4ab", "attack", "enemy",
      ["Deal 4", "Apply Stun \U0001f4ab", "⚔️ physical"], ""),
    C("deflect", "Deflect", 1, "\U0001f300", "skill", "self", ["Gain 5 block", "Reflect 4"], ""),
    C("chill_touch", "Chill Touch", 1, "❄️", "attack", "enemy",
      ["Deal 4", "Apply Chill ❄️", "\U0001f9ff spell"], ""),
    C("quivering_palm", "Quivering Palm", 2, "☝️", "attack", "enemy",
      ["Deal 8", "On kill: +2 ⚡", "⚔️ physical"], ""),
    STRIKE,
]

def s_cards_support():
    b = ('<div class="note"><b>Draft direction (2026-07-15).</b> The <b>Support</b> role, same three-layer '
         "shape as the Tank sheet: the <b>role</b> is a shared <i>substrate</i> (Communion), each <b>class</b> "
         "is one <b>Class Power</b> that channels it, and a <b>skill tree</b> (post-MVP) upgrades that power. "
         "Numbers are unsimmed placeholders."
         "<br><br><b>Rev 2026-07-16 — the two stances were reworked.</b> The <b>Bard</b>’s song no longer "
         "burns Communion to stay up; it’s held by <b>touching 3 distinct targets a turn</b> (an AoE counts "
         "as <b>1</b>), and comes up short → it breaks. The <b>Druid</b> is rebuilt around <b>deck "
         "manipulation</b>: pick <b>\U0001f43b Bear / \U0001f985 Hawk / \U0001f43a Wolf</b>, <b>hand 2 cards "
         "back to your deck</b> to pay for it, and get paid — hard — for the card types you <i>draw</i> "
         "rather than the ones you play. Both changes pull the same lever: <b>the cost moved out of a meter "
         "and into how you play</b>. The Bard pays in <i>reach</i>, the Druid pays in <i>cards</i>."
         "</div>")

    b += ('<div class="sub" style="background:linear-gradient(135deg,#1c2622,#151c19);border-color:#2f4a3a">'
          '<h3 style="color:#4dd16b">\U0001f4ff SUPPORT — the Communion substrate</h3>'
          "<p><b>Communion</b> is the party’s shared reserve of faith and morale. Every support builds it by "
          "<b>helping an ally</b> — a heal, a shield, a buff banks 1 \U0001f4ff — and support cards read off "
          "it. The cards <i>build</i> the resource; the <b>Class Power channels it</b>, differently per class: "
          "the Cleric runs a <b>passive aura</b> that auto-discharges every 5 casts (heal-all + smite-all, "
          "scaled by your cast streak), the Bard <b>spends a lump</b> to strike up a party-wide song, the "
          "Druid <b>spends a lump</b> to shift into a beast. <i>(The Cleric’s aura reads cast types directly "
          "instead of banking Communion — it’s the always-on member of the trio.)</i></p>"
          "<p><b>Communion is the ignition, never the upkeep.</b> It buys the Bard’s song and the Druid’s "
          "shift, and then it’s out of the way — neither power drains a meter to stay alive. What holds them "
          "up is <b>how you play</b>: the Bard must <b>spread its turn across 3 distinct targets</b>, the "
          "Druid must <b>draw the card types its form pays for</b>. That keeps the failure state legible "
          "(you can see it in your own hand) instead of hiding it in a bar ticking toward zero.</p>"
          "<p>Communion lives on the party dict, host-side, so both the meter and the power ride the "
          "snapshot.</p><span class=\"rk\">DRAFT — unsimmed</span></div>")

    b += combat_row_box([
        ("⛑️", "Cleric", "✨", "Channel Divinity<br>passive · auto every 5"),
        ("\U0001f3bb", "Bard", "\U0001f3b6", "Bardic Performance<br>stance · 3 targets / turn"),
        ("\U0001f43b", "Druid", "\U0001f43e", "Wild Shape<br>pick a form · pay 2 cards"),
    ], accent="#7ad19a")

    b += role_block(
        "⛑️", "Cleric", "Channel Kit", "28 hp · 3 energy",
        {"icon": "✨", "name": "Channel Divinity",
         "gate": "passive aura · no tap · auto-discharges every 5 casts",
         "effect": "A channelled aura that fires <b>itself</b> — no tap. Every card the Cleric plays charges "
                   "it, read by <b>type</b>: attacks feed the <b>\U0001f525 smite</b> side, heals &amp; "
                   "shields feed the <b>\U0001f64f mercy</b> side. Cast the same type back-to-back and the "
                   "aura <b>intensifies</b> — each repeat in a streak adds more than the last. On <b>every "
                   "5th cast it discharges automatically</b>: heal ALL allies for the mercy charge, damage "
                   "ALL enemies for the smite charge. A pure run (5 attacks, or 5 heals) pays out far more "
                   "than alternating — <b>commit to a line</b>.",
         "tree": ["<b>Overflow</b> — mercy that overheals lands as Guard on the party",
                  "<b>Zealotry</b> — a pure 5-streak also applies Vulnerable \U0001f4a5 (smite) or cleanses a debuff (mercy)",
                  "<b>Deeper Faith</b> — the aura discharges every 4 casts instead of 5"]},
        "Its own casts — the aura reads the Cleric’s card <b>types</b> as they’re played; there’s no "
        "resource to bank or button to press. The <b>streak</b> is the skill: "
        "\U0001f525\U0001f525\U0001f525 in a row builds a bigger smite than \U0001f525\U0001f64f"
        "\U0001f525\U0001f64f ever could, and \U0001f64f\U0001f64f\U0001f64f a bigger heal. Pick a side, "
        "stay on it.",
        S_CLERIC,
        '<div class="wg"><div class="wgl">CHANNEL — auto every 5 casts</div>'
        '<div class="pips"><span style="color:#eb6b6b">\U0001f525\U0001f525\U0001f525</span>'
        '<span style="color:#3a3a46">○○</span></div>'
        '<div class="wgt">3 / 5 · streak \U0001f525×3 → smite building · the 5th cast discharges: '
        'heal allies &amp; hit all enemies</div></div>')

    b += role_block(
        "\U0001f3bb", "Bard", "Performance Kit", "26 hp · 3 energy",
        {"icon": "\U0001f3b6", "name": "Bardic Performance",
         "gate": "stance · hold it by touching <b>3 distinct targets</b> each turn · come up short and it breaks",
         "effect": "Strike up a song (a <b>stance</b>). While performing, every ally deals <b>+2</b> and gains "
                   "<b>+2 block</b> at the start of their turn. Holding it costs <b>no resource</b> — it costs "
                   "<b>reach</b>. Each turn you must touch <b>3 distinct targets</b>, and an <b>AoE counts as "
                   "one</b> no matter how many it hits. Mend a dwarf, Ballad the whole party, Strike an "
                   "enemy — that’s 3, and the music plays on. Mend the <i>same</i> dwarf three times and "
                   "that’s <b>1</b>: the song <b>breaks</b> and goes on a <b>3-turn cooldown</b>.",
         "tree": ["<b>Virtuoso</b> — the aura rises to +3 attack / +3 block",
                  "<b>Countersong</b> — allies also gain Retaliate 2 while you perform",
                  "<b>Encore</b> — the first turn you come up short doesn’t break the song (once per fight)"]},
        "Communion \U0001f4ff — banked by helping an ally. The Bard spends a <b>lump</b> to strike the song "
        "up, and then Communion is <b>done</b>: it never touches the song again. The upkeep is <b>breadth</b>. "
        "A turn spent poking one dwarf over and over is a turn the music stops — which is the whole point, "
        "because a support that tunnels on one target isn’t supporting.",
        S_BARD,
        '<div class="wg"><div class="wgl">PERFORMANCE — 3 distinct targets to hold</div>'
        '<div class="pips"><span style="color:#4dd16b">\U0001f3af\U0001f3af</span>'
        '<span style="color:#3a3a46">○</span></div>'
        '<div class="wgt">\U0001f3b6 performing · \U0001f64c Mend → the tank · \U0001f4ef Ballad → party '
        '(AoE = <b>1</b>) · one more target or the song breaks</div></div>')

    b += role_block(
        "\U0001f43b", "Druid", "Wildshape Kit", "30 hp · 3 energy",
        {"icon": "\U0001f43e", "name": "Wild Shape",
         "gate": "stance · spend a lump of \U0001f4ff · choose \U0001f43b / \U0001f985 / \U0001f43a · costs "
                 "<b>2 cards</b> · lasts 3 turns",
         "effect": "Spend Communion to shift — and <b>choose the form</b> (a <b>stance</b>, <b>3 turns</b>). "
                   "It resolves at the <b>start of your next turn</b>: shuffle <b>2 cards from your hand back "
                   "into your deck</b>, and you do <b>not</b> replace them. That’s the real price of the "
                   "form — a <b>−2 hand</b>, two plays you simply don’t get. You <i>do</i> choose which two, "
                   "and they go back into the <b>deck</b>, not the discard: you aren’t throwing them away, "
                   "you’re re-seeding.<br>"
                   "It has to buy back a whole turn of tempo, so it pays <b>hard</b>. At the start of "
                   "<b>every turn you’re shifted</b>, the form reads your hand and pays for every card of its "
                   "<b>school</b> in it — the three forms are the three schools, one each "
                   "(see <code>cards/dps.html</code>):<br>"
                   "\U0001f43b <b>Bear</b> — every <b>\U0001f6e1️ block</b> card in hand → <b>+5 Guard</b>, "
                   "free.<br>"
                   "\U0001f43a <b>Wolf</b> — every <b>⚔️ physical</b> card in hand → your <b>first attack</b> "
                   "this turn hits <b>+5</b> harder.<br>"
                   "\U0001f985 <b>Hawk</b> — every <b>\U0001f9ff spell</b> card in hand → <b>+3 block to the "
                   "whole party</b>, free. <i>(Reads lower per card only because it multiplies by party "
                   "size.)</i><br>"
                   "The payout is on the <b>draw</b>, not the play: you’re paid for <b>holding</b> the right "
                   "types, not spending them — so the two you give back are the two your form wasn’t going to "
                   "pay for anyway. It isn’t a mulligan, it’s a <b>tithe you get to aim</b>.",
         "tree": ["<b>Deep Roots</b> — the shift costs <b>1 card</b> instead of 2",
                  "<b>Primal Instinct</b> — draw 1 extra each turn while shifted (more hand, more payout)",
                  "<b>Two Natures</b> — your hand also pays out for a second form of your choice"]},
        "Communion \U0001f4ff — nature skills and heals bank it; Wild Shape spends a lump to shift. But the "
        "lump isn’t the real price — <b>2 cards</b> are. A form only ever pays what your deck can draw, so the "
        "Druid is the class that rewards a list built <b>lopsided on purpose</b>: a narrow deck is what makes "
        "the two you hand back the easy ones, and then the hand pays you before you spend a point of energy.",
        S_DRUID,
        '<div class="wg"><div class="wgl">WILD SHAPE — pick a form, pay 2 cards for it</div>'
        '<div class="pips"><span style="color:#4dd16b">\U0001f43b</span>'
        '<span style="color:#3a3a46">\U0001f985\U0001f43a</span></div>'
        '<div class="wgt">\U0001f43b Bear · turn <b>1 of 3</b> · gave 2 back (hand <b>−2</b>) → '
        '\U0001f6e1️\U0001f6e1️\U0001f6e1️ still in hand = <b>+15 Guard</b>, free</div></div>')

    b += ('<div class="sub" style="background:#141821;border-color:#2c3340"><h3 style="color:#8fb4e0">'
          "The build cost — what Support adds</h3>"
          "<p>Support reuses the <b>Class Power</b> plumbing the Tank sheet introduces — a per-dwarf "
          "<code>power</code> + <code>power_cd</code> on the party dict, ticked host-side, fired by a "
          "validated tap intent. Communion is <b>one new counter</b> (<code>communion</code> on the party "
          "dict, +1 when a card that helps an ally resolves).<br><br>"
          "<b>The Bard and Druid powers are stances</b> (like Enrage), so they reuse that end-of-turn upkeep "
          "hook.<br><br>"
          "<b>The Bard’s song is the cheapest thing on this sheet, and that’s not luck.</b> Its rule — 3 "
          "distinct targets, AoE counts as 1 — needs <b>no new addressing</b>, because the host already "
          "validates every play as <code>(target_kind, target_idx)</code> in "
          "<code>_try_play(seat, uid, kind, idx)</code>. That pair <i>is</i> the distinct-target key. Bank it "
          "in a per-turn <code>targets</code> set, check <code>size() &gt;= 3</code> at end of turn, and drop "
          "the song + set <code>power_cd = 3</code> if not. <b>“AoE counts as 1” is not a special case we "
          "write — it falls out</b>: an AoE play carries a single address (<code>kind=\"all\"</code>, "
          "<code>idx=-1</code>), so it can only ever add one entry. It’s the same static address the M3b fx "
          "rider already ships as <code>side</code>+<code>slot</code>.<br><br>"
          "<b>Wild Shape is the expensive one</b>, and the cost is <i>input</i>, not logic: it needs two "
          "choices combat has never had to ask for. First a <b>3-way form pick</b> on the tap "
          "(<code>form</code> = bear/hawk/wolf on the party dict, plus <code>shift_turns = 3</code>). Then, on "
          "the first shifted turn, a <b>pick-2-from-hand</b> modal to pay the tithe — a genuinely new input "
          "shape, since every existing play targets a <i>character</i>, not a <i>card</i>. Both are new "
          "validated intents in co-op (per-seat and instant — your own dwarf, so never a ring decision). The "
          "payout itself is trivial by comparison: at the start of each shifted turn, count the hand by "
          "<code>type</code> and multiply. <br><br>"
          "The <b>Cleric’s Channel is passive</b> — the simplest of the three: a per-cast hook tags each play "
          "\U0001f525 (attack) or \U0001f64f (skill/power), bumps a same-type <code>streak</code> (reset on "
          "switch) and a <code>casts</code> counter, and adds <code>streak</code> to the matching charge; on "
          "every 5th cast it fires a party heal + <code>dmg_all</code> sized by the two charges, then clears. "
          "No tap, no cooldown.<br><br>"
          "<b>New ops:</b> <code>channel_aura</code> (the Cleric per-cast hook: tag + streak + 5-cast "
          "discharge) · <code>bank_communion v</code> · <code>spend_communion [ops]</code> (scale by "
          "Communion, exactly like the shipped <code>spend_devotion</code>) · <code>buff_ally_next v</code> "
          "(Bard Inspiration) · the two stance powers (<code>perform</code> / <code>wild_shape form</code>) · "
          "<code>shuffle_into_deck n</code> (Forage + the Wild Shape filter) · <code>hand_type_payout</code> "
          "(the form’s start-of-turn count). <b>Reused as-is:</b> heal_ally, party_block, party_buff, "
          "shield_ally, dmg_all, apply/vulnerable+burn, temp/retaliate, draw, gain_guard. Everything else is "
          "pure data.<br><br>"
          "<b>The one thing to sim first:</b> the form payouts can’t be tuned in isolation — they’re a "
          "function of whatever list the Druid built, so they’re the only numbers on this sheet that move "
          "when a <i>card</i> changes. Bear at <b>+5 per block card</b> off a block-stacked deck is the "
          "obvious blow-out: a 3-block hand is <b>+15 Guard for zero energy</b>, every turn, for 3 turns — "
          "and you still get to play the blocks afterward. The <b>−2 hand</b> is the only brake, and there’s "
          "a real tension worth watching: the narrow deck that makes the payout wide is the same narrow deck "
          "that makes the tithe painless. If Wild Shape ends up dominant, that loop is why, and the lever is "
          "the <b>cost</b> (2 cards → 3) at least as much as the three payout numbers.</p></div>")

    return page("Cards — Support role · class powers", "card_db.gd · STARTER_PACKS (draft)", "Cards", b,
                ROLE_CSS, stage_h=0,
                note="Support: Communion → Channel Divinity / Bardic Performance / Wild Shape")

def s_cards_dps():
    b = ('<div class="note"><b>Draft direction (2026-07-15).</b> The <b>DPS</b> role, same three-layer shape '
         "as the Tank sheet: the <b>role</b> is a shared <i>substrate</i>, each <b>class</b> is one <b>Class "
         "Power</b> that runs on it, and a <b>skill tree</b> (post-MVP) upgrades that power. Numbers are "
         "unsimmed placeholders."
         "<br><br><b>Rev 2026-07-17 — all three powers were rebuilt, and the substrate with them.</b> "
         "<b>Momentum is gone from this role.</b> It measured a <i>solo</i> turn (+1 per attack you played, "
         "reset each turn), and not one of the three powers below is about a solo turn — so it was measuring "
         "the wrong thing. What replaces it isn’t another meter: it’s <b>the rest of the party</b>."
         "</div>")

    b += ('<div class="sub" style="background:linear-gradient(135deg,#2a1e1e,#1c1618);border-color:#4a2f2f">'
          '<h3 style="color:#eb6b6b">⚔️ DPS — your party charges your power</h3>'
          "<p>No personal meter. Every Class Power here is <b>charged, extended or refunded by what your "
          "allies do</b>:</p>"
          '<div class="chips">'
          '<span class="cc"><b>\U0001f9d9 Metamagic</b> — <b>charges</b> when you <i>or an ally</i> casts a '
          '<b>spell</b></span>'
          '<span class="cc"><b>\U0001f5e1️ Assassin’s Mark</b> — <b>lasts longer</b> every time an <i>ally</i> '
          "hits it</span>"
          '<span class="cc"><b>\U0001f44a Flurry</b> — <b>refunded</b> every time <i>anyone</i> lands a '
          "status</span></div>"
          "<p><b>None of the three is on a cooldown, and that’s the point:</b> a cooldown counts <i>turns</i>, "
          "and these need to count <i>teammates</i>. It works because combat here is <b>simultaneous</b> — all "
          "three dwarves act in the same player phase, so your ally’s Burn lands <i>while you still have your "
          "turn</i>. The DPS role is where co-op actually pays out, and these powers are the payout: they’re "
          "the reason you shout “burn it!” at your friend instead of quietly optimising your own hand. Solo, "
          "all three still work — you just have to feed them all three dwarves yourself.</p>"
          "<span class=\"rk\">DRAFT — unsimmed</span></div>")

    b += ('<div class="sub" style="background:#181622;border-color:#3a2f4a">'
          '<h3 style="color:#c295e0">\U0001f9ff What a “spell” is — the one new piece of data</h3>'
          "<p>Two of these powers read <b>spells</b>, so the word has to mean something. It becomes a card’s "
          "<b>school</b> — one of three, on every card:</p>"
          '<div class="chips">'
          '<span class="cc"><b>\U0001f6e1️ block</b> — it puts up a shield</span>'
          '<span class="cc"><b>⚔️ physical</b> — it swings something</span>'
          '<span class="cc"><b>\U0001f9ff spell</b> — everything else: a bolt, a heal, a mark, a bless</span>'
          "</div>"
          "<p><b>School is a second axis, not a rename of the type.</b> The existing <code>attack</code> / "
          "<code>skill</code> / <code>power</code> type drives the tint and the targeting and doesn’t move. "
          "<b>Strike and Bolt are both <code>attack</code> type</b> — but Strike is <i>physical</i> and Bolt "
          "is a <i>spell</i>, and no amount of squinting at the existing type tells you that. Hence a tag.</p>"
          "<p>It pays for itself immediately: the <b>Druid’s three Wild Shape forms</b> on the Support sheet "
          "already read exactly these three schools (\U0001f43b Bear = block, \U0001f43a Wolf = physical, "
          "\U0001f985 Hawk = spell). One field, two sheets.</p></div>")

    b += combat_row_box([
        ("\U0001f9d9", "Sorcerer", "\U0001f300", "Metamagic<br>charges on spellcasts"),
        ("\U0001f5e1️", "Rogue", "\U0001f3af", "Assassin’s Mark<br>one mark at a time"),
        ("\U0001f44a", "Monk", "\U0001f44a", "Flurry of Blows<br>refunded by statuses"),
    ], accent="#eb9a9a",
        fuel="the orb shows the gate — and on this sheet the gate is <b>never a cooldown</b>. It reads "
             "<b>what the party just did</b>: spells cast, hits landed on your mark, statuses stuck.")

    b += role_block(
        "\U0001f9d9", "Sorcerer", "Metamagic Kit", "22 hp · 3 energy",
        {"icon": "\U0001f300", "name": "Metamagic",
         "gate": "no cooldown · charges <b>+1 per spell</b> cast by <b>anyone</b> · ready at <b>3</b>",
         "effect": "<b>Never on a cooldown.</b> Metamagic charges when a <b>spell</b> is cast — <b>yours or "
                   "an ally’s</b>. Your Bolt charges it; so does the Cleric’s Mend, and the Druid’s Regrowth. "
                   "At <b>3</b>, tap it and <b>choose one</b>, then it applies to your <b>next spell</b> and "
                   "the charge resets:<br>"
                   "\U0001f300 <b>Twinned</b> — the spell also hits a <b>second target</b>, in full.<br>"
                   "⚡ <b>Quicken</b> — the spell costs <b>2 less</b> (a 2-cost becomes free).<br>"
                   "⏳ <b>Heighten</b> — the spell <b>doesn’t fire now</b>. At the start of your next turn it "
                   "fires <b>twice</b>.<br>"
                   "Three shapes, one choice, no maths: <b>wider</b>, <b>cheaper</b>, or <b>later but "
                   "double</b>.",
         "tree": ["<b>Font of Magic</b> — ready at <b>2</b> spells instead of 3",
                  "<b>Metamagic Adept</b> — apply <b>two</b> metamagics to the same spell",
                  "<b>Empowered</b> — a Heightened spell fires <b>three</b> times, not twice"]},
        "<b>The party’s spellcasting</b> — not a meter of your own. The Sorcerer is the class that gets "
        "<i>faster</i> the more casters sit beside it: next to a Cleric it charges twice as quickly, next to "
        "a Warrior swinging an axe it charges not at all. <b>Heighten is the one to read twice</b> — it is "
        "the only card in the game that deliberately does nothing on the turn you pay for it.",
        D_SORC,
        '<div class="wg"><div class="wgl">METAMAGIC — charges on party spellcasts</div>'
        '<div class="pips"><span style="color:#c295e0">\U0001f9ff\U0001f9ff</span>'
        '<span style="color:#3a3a46">○</span></div>'
        '<div class="wgt">2 / 3 · your \U0001f3af Mark + the Cleric’s \U0001f64c Mend · one more cast from '
        '<b>anyone</b> and you choose \U0001f300 / ⚡ / ⏳</div></div>')

    b += role_block(
        "\U0001f5e1️", "Rogue", "Sneak Attack Kit", "24 hp · 3 energy",
        {"icon": "\U0001f3af", "name": "Assassin’s Mark",
         "gate": "no cooldown · <b>one mark at a time</b> · re-cast it when the target dies or it runs out",
         "effect": "Name a target. It bleeds <b>4 a turn</b> for <b>3 turns</b>, and the bleed <b>ignores "
                   "armour completely</b> — block, Guard, Bulwark, none of it matters. Then the fight feeds "
                   "it, from <b>both ends</b>:<br>"
                   "\U0001f465 <b>Every ally hit on the marked target → +1 turn.</b> Your party keeps it "
                   "<b>alive</b>.<br>"
                   "\U0001f5e1️ <b>Every hit of YOURS → +2 tick.</b> You make it <b>hurt</b>.<br>"
                   "Neither half is worth much without the other: you alone build a vicious bleed that expires "
                   "in 3 turns; the party alone keeps a 4-a-turn scratch running forever. Together the mark "
                   "outlives the fight and gets worse every round it does.",
         "tree": ["<b>Deep Cut</b> — your hits add <b>+3</b> tick instead of +2",
                  "<b>Open Season</b> — ally hits add <b>2</b> turns instead of 1",
                  "<b>Contract Killer</b> — when a marked target dies, the mark <b>jumps</b> to a new one at "
                  "full duration"]},
        "<b>Your allies’ attacks</b> — the mark is the only thing on this sheet that <b>two people build "
        "together</b>. It’s also the answer to the Warden \U0001f5ff and its Bulwark: a bleed that ignores "
        "armour doesn’t care how much block the wall stacked, so the Rogue is how a party cracks a target it "
        "cannot out-damage.",
        D_ROGUE,
        '<div class="wg"><div class="wgl">ASSASSIN’S MARK — the party keeps it bleeding</div>'
        '<div class="bar"><div class="fill" style="width:80%;background:#eb6b6b"></div></div>'
        '<div class="wgt">\U0001f3af \U0001f479 Brute · <b>8</b> a turn (base 4 +2 +2 from your hits) · '
        '<b>4 turns left</b> (3 +1 from the Warrior) · ignores armour</div></div>')

    b += role_block(
        "\U0001f44a", "Monk", "Flurry Kit", "24 hp · 3 energy",
        {"icon": "\U0001f44a", "name": "Flurry of Blows",
         "gate": "3-turn cooldown — but <b>refunded</b> by every status <b>anyone</b> lands this turn",
         "effect": "Tap it and strike for <b>8</b>. Then the cooldown lights up — and for <b>the rest of this "
                   "turn</b>, <b>every status effect applied to an enemy refunds it</b>. Not just yours: a "
                   "<b>teammate’s</b> Burn \U0001f525, the Sorcerer’s Mark \U0001f3af, the Witch’s Hex — "
                   "<b>anyone’s</b>. Refunded means <b>tap it again</b>.<br>"
                   "So the Monk isn’t a card you play, it’s a <b>rhythm you keep</b>: status → Flurry → "
                   "status → Flurry. The ceiling isn’t your energy or your hand — it’s <b>how many statuses "
                   "your party can land in one turn</b>. Play beside a Cleric slinging Searing Word and a "
                   "Rogue with Poison Blade and the fists simply don’t stop.",
         "tree": ["<b>Iron Fist</b> — <b>10</b> a blow instead of 8",
                  "<b>Ki Flow</b> — every refund also hands you <b>1 ⚡</b>",
                  "<b>Whirlwind</b> — Flurry strikes <b>every</b> enemy, not just one"]},
        "<b>Everyone’s status effects</b> — and it only works because combat is <b>simultaneous</b>: your "
        "ally’s Burn lands <i>while you still have your turn</i>, so it can hand you your fists back before "
        "you’re done. <b>The tension is real, though</b> — end-turn is order-free, and the Monk who ends "
        "first ends its own combo. <b>You want to end LAST</b>, and that is a genuinely social decision, not "
        "a solver one.",
        D_MONK,
        '<div class="wg"><div class="wgl">FLURRY — refunded by every status this turn</div>'
        '<div class="pips"><span style="color:#4dd16b">\U0001f44a\U0001f44a\U0001f44a</span>'
        '<span style="color:#3a3a46">○</span></div>'
        '<div class="wgt">3 blows so far · your \U0001f3af Mark → refund · the Cleric’s \U0001f525 Burn → '
        'refund · <b>ready again</b> — someone land one more</div></div>')

    b += ('<div class="sub" style="background:#141821;border-color:#2c3340"><h3 style="color:#8fb4e0">'
          "The build cost — what DPS adds</h3>"
          "<p>DPS <b>was</b> the lightest role — it scaled off Momentum, which already ships. Dropping "
          "Momentum gives that back: these three powers need <b>hooks</b>, and a hook is more work than a "
          "counter. The good news is that it’s the <b>same three hooks</b>, and once they exist all three "
          "powers are small.<br><br>"
          "<b>The one new field: <code>school</code></b> (<code>block</code> / <code>physical</code> / "
          "<code>spell</code>) on every card def. It can’t be derived — <code>Strike</code> and "
          "<code>Bolt</code> are both <code>attack</code> type. Cheap, but it touches every card in "
          "<code>card_db.gd</code>, and the existing <code>tags</code> field is where it goes.<br><br>"
          "<b>The three hooks</b>, all host-side, all fired where the ops already resolve:<br>"
          "• <b>on any card resolving</b> → if <code>school == spell</code>, +1 to every Sorcerer’s "
          "<code>meta_charge</code>. <i>Party-wide, so it reads the resolving SEAT, not the actor.</i><br>"
          "• <b>on any attack landing</b> → if the target carries an <code>assassin_mark</code>, +1 duration "
          "when the attacker is an ally, +2 tick when it’s the mark’s owner. <i>The mark stores its owner "
          "seat; that’s the whole “both ends” rule.</i><br>"
          "• <b>on any status applying to an enemy</b> → clear <code>power_cd</code> for every Monk, if the "
          "Monk fired this turn. <i>One line, and it is the entire Monk.</i><br><br>"
          "<b>Ordering matters exactly once:</b> Heighten must resolve at <b>start of turn</b>, before the "
          "hand is drawn, or a Quickened+Heightened spell can’t interact with the hand it was meant to set "
          "up.<br><br>"
          "<b>New ops:</b> <code>metamagic</code> (charge + the 3-way pick: <code>twin</code> / "
          "<code>quicken</code> / <code>heighten</code>) · <code>assassin_mark</code> (a DoT carrying owner + "
          "tick + duration) · <code>flurry</code> (flat hit + arm the refund window) · "
          "<code>pierce_armour</code> (the mark’s tick ignores block) · <code>delayed_cast</code> (Heighten’s "
          "held spell). <b>Reused as-is:</b> dmg, dmg_all, apply_status/marked, apply/vulnerable+burn, "
          "on_kill, gain_energy, draw, the whole status pipeline.<br><br>"
          "<b>Co-op is free here, and that is not luck:</b> all three hooks live on the <b>host</b>, which "
          "already resolves every seat’s plays in one place. The charge, the mark and the refund are just "
          "<b>party-dict state</b>, so they ride the existing absolute snapshot — a client never computes "
          "any of it, it renders it. The M3b fx rider already carries the animations.</p></div>")

    return page("Cards — DPS role · class powers", "card_db.gd · STARTER_PACKS (draft)", "Cards", b,
                ROLE_CSS, stage_h=0,
                note="DPS: your party charges it → Metamagic / Assassin’s Mark / Flurry of Blows")

# ================================================================ FOUNDATIONS / COMPONENTS
def s_palette():
    swatches = [
        ("Surfaces", [("COL_BG", BG, "every screen"), ("COL_HUD", HUD, "the rent bar"),
                      ("panel", PANEL, "lobby boxes"), ("war table", "#0d0f14", "hex backdrop")]),
        ("Money & risk", [("C_GREEN", GREEN, "solvent · alive · agreed"),
                          ("C_AMBER", AMBER, "one month of slack · reachable"),
                          ("C_RED", RED, "under the rent · downed"),
                          ("C_COIN", COIN, "gold, and only gold")]),
        ("Card type tint", [("attack", TINT["attack"], "deals damage"),
                            ("skill", TINT["skill"], "everything else"),
                            ("power", TINT["power"], "rewrites the turn"),
                            ("cost orb", ORB, "always this yellow")]),
        ("Class", [("warrior", CLASS_COL["warrior"], "steel"), ("cleric", CLASS_COL["cleric"], "gold"),
                   ("sorcerer", CLASS_COL["sorcerer"], "violet")]),
        ("Danger tier", [("low", DANGER_BG["low"], "\U0001f480"), ("med", DANGER_BG["med"], "\U0001f480\U0001f480"),
                         ("high", DANGER_BG["high"], "\U0001f480\U0001f480\U0001f480")]),
        ("Enemy intent", [("attack", INTENT_COL["attack"], "it will hit someone"),
                          ("block", INTENT_COL["block"], "it will guard"),
                          ("rage_all", INTENT_COL["rage_all"], "it will buff the pack"),
                          ("expose", INTENT_COL["expose"], "it will make you fragile")]),
    ]
    css = GRID_CSS + """
.sw{display:flex;flex-wrap:wrap;gap:12px;width:100%;max-width:1180px}
.s1{width:172px}
.chipc{height:64px;border-radius:8px;border:1px solid rgba(255,255,255,.10)}
.s1 b{display:block;font-size:12px;margin-top:6px;color:#e0e0e8;font-weight:600}
.s1 code{display:block;font-family:ui-monospace,Consolas,monospace;font-size:11px;color:#7a7a88}
.s1 i{display:block;font-size:11px;color:#8b8b99;font-style:normal;margin-top:2px}
"""
    b = ('<div class="note">Pulled straight from the <code>const</code> blocks. The grammar is strict: '
         "<b>green/amber/red is solvency and life</b>, <b>coin-yellow is money and nothing else</b>, and "
         "<b>a card's tint is a promise about what it does</b>.</div>")
    for head, items in swatches:
        b += "<h2>%s</h2><div class=\"sw\">" % head
        for name, hexv, use in items:
            b += ('<div class="s1"><div class="chipc" style="background:%s"></div>'
                  "<b>%s</b><code>%s</code><i>%s</i></div>" % (hexv, name, hexv, use))
        b += "</div>"
    return page("Palette", "the const blocks in *.gd", "Foundations", b, css, stage_h=0,
                note="The colour grammar — and what each colour is allowed to mean")

def s_status():
    rows = [
        ("\U0001f6e1️", "Block", "soaks damage this turn, then it is gone", "party + enemy"),
        ("\U0001f530", "Shield", "−flat per hit, through the enemy phase (Cleric)", "party"),
        ("\U0001f300", "Channel", "next N attacks +v each", "party"),
        ("\U0001f527", "Fortify", "next Guard +5, Retaliate +2", "party"),
        ("\U0001f501", "Retaliate", "reflect v at anything that hits you", "party"),
        ("⚔️", "Momentum", "attacks played this turn (Warrior scaling)", "party"),
        ("\U0001f64f", "Devotion", "skills played (Cleric — spend for Smite)", "party"),
        ("\U0001faa8", "Whetstone", "next attack +v", "party"),
        ("✨", "Empower", "next card ×2", "party"),
        ("\U0001f3af", "Mark", "+25% from ALL sources — the only multiplier", "enemy"),
        ("\U0001f525", "Burn", "ticks at enemy-turn start, ignores block, decays 1", "enemy"),
        ("\U0001f4a5", "Vulnerable", "×1.5 taken, decays 1/turn — goes both ways", "both"),
        ("✅", "Ended / Aye", "this seat has called it — combat turn, or a ring vote", "co-op"),
        ("⏳", "Waiting", "the ring is open and this seat has not answered", "co-op"),
        ("\U0001f4a4", "Absent", "silent 12s — pruned from the ring so nobody is locked out", "co-op"),
    ]
    css = GRID_CSS + """
.g{display:flex;flex-wrap:wrap;gap:10px;width:100%;max-width:1180px}
.st{width:270px;background:#1c1c24;border:1px solid #2c2c38;border-radius:8px;padding:10px 12px;
  display:flex;gap:10px;align-items:flex-start}
.st .e{font-size:26px;line-height:1}
.st b{display:block;font-size:13px;color:#e6e7ea}
.st i{display:block;font-size:11px;color:#8b8b99;font-style:normal;line-height:1.4;margin-top:2px}
.st u{display:block;font-size:10px;color:#5c5c68;text-decoration:none;margin-top:3px;
  text-transform:uppercase;letter-spacing:.06em}
"""
    b = ('<div class="note">One glyph, one meaning, everywhere — on a portrait badge, on a card face, '
         "and in the log. A status the player cannot name in one word does not ship.</div><div class=\"g\">")
    for e, n, d, who in rows:
        b += '<div class="st"><div class="e">%s</div><div><b>%s</b><i>%s</i><u>%s</u></div></div>' % (e, n, d, who)
    return page("Status glyphs", "combat.gd · _refresh_party / _refresh_enemies", "Foundations",
                b + "</div>", css, stage_h=0, note="The status grammar — 15 glyphs, one meaning each")

def s_card_anatomy():
    css = GRID_CSS + """
.bd{display:flex;gap:40px;flex-wrap:wrap;align-items:flex-start;margin-top:8px}
.ann{position:relative}
.ann .card{box-shadow:0 8px 26px rgba(0,0,0,.55)}
.calls{font-size:12px;color:#8b8b99;line-height:1.9;margin-left:4px}
.calls b{color:#e0e0e8;font-weight:600}
"""
    b = ('<div class="note">130×188, 12px radius, 2px border. The frame tint is the card\'s type; the '
         "orb is always coin-yellow; the body is generated by <code>Db.describe()</code> so the numbers on "
         "the face are the numbers you will actually deal.</div>")
    b += "<h2>Anatomy</h2><div class=\"bd\">"
    b += '<div class="ann">%s</div>' % card_html(SORC_SIG[2])
    b += ('<div class="calls"><b>cost orb</b> — 34px, #f5d640, top-left. 0/1/2 only.<br>'
          "<b>emoji</b> — 38–44px, the card's whole identity at a glance.<br>"
          "<b>name</b> — 15px. A ⏳ prefix means on cooldown (Taunt).<br>"
          "<b>body</b> — 12px, generated, <span style=\"color:#73ff80\">green when buffed</span>. "
          "Live numbers, never static text.<br>"
          "<b>frame</b> — the type tint. Selected → 4px #fff273.</div></div>")
    b += "<h2>Type tints<span>the promise the frame makes</span></h2>"
    b += card_row([CHASSIS[0], CHASSIS[1], SORC_SIG[1]])
    b += "<h2>States</h2><div class=\"row\">"
    for c, why in [(CHASSIS[0], "playable"), (SORC_SIG[2], "unplayable — not enough ⚡"),
                   (SORC_SIG[0], "selected — armed, targets lit"),
                   (WARRIOR_SIG[0], "on cooldown — no_repeat")]:
        b += '<div class="slot">%s<div class="why">%s</div></div>' % (
            card_html(c, selected=("selected" in why), playable=("unplayable" not in why),
                      cooldown=("cooldown" in why)), why)
    b += "</div>"
    b += "<h2>Hover / tooltip<span>hover lifts 46px, scales 1.18, straightens the fan rotation</span></h2>"
    b += ('<div class="row"><div class="slot">%s</div>'
          '<div class="tipp" style="align-self:flex-end">Deal 5<br>(+3 per attack · 0 so far)<br>'
          "— Unleash everything — deal 5 +3 per attack already played this turn. "
          "Play it LAST.</div></div>" % card_html(SORC_SIG[2], scale=1.18))
    return page("Card component", "scripts/ui/card.gd", "Components", b, css, stage_h=0,
                note="130×188 — anatomy, tints, states, tooltip")

def s_hex_component():
    css = GRID_CSS + """
.hg{display:flex;flex-wrap:wrap;gap:22px;width:100%;max-width:1180px}
.h1{width:120px;text-align:center}
.h1 .hh{position:relative;width:87px;height:100px;margin:0 auto}
.h1 .hh>div{position:absolute}
.h1 b{display:block;font-size:12px;color:#e0e0e8;margin-top:8px}
.h1 i{display:block;font-size:11px;color:#8b8b99;font-style:normal;line-height:1.35}
"""
    tiles = [("empty", "quiet passage", 0, False, False, False),
             ("combat", "a fight · ☠ = how tough", 2, False, False, False),
             ("reward", "a card leaves the room", 0, False, False, False),
             ("event", "a shared-risk choice", 0, False, False, False),
             ("objective", "\U0001f3c1 the captive — pays the real money", 0, False, False, False),
             ("empty", "where the crew stands", 0, True, False, False),
             ("combat", "reachable — amber ring pulses", 1, False, True, False),
             ("combat", "resolved — desaturates into the board", 0, False, False, True),
             ("wall", "impassable ridge · sits IN the board", 0, False, False, False)]
    b = ('<div class="note">A Civ-style board piece, drawn in <code>_draw()</code>: a dark side hexagon for '
         "thickness, a terrain-tinted top face, a lit rim on the two upper edges, and a pulsing ring for "
         "affordance. Pointy-top, R=50 → 87×100. Picking is hexagon-precise, so a corner never steals "
         "a neighbour's click.</div><div class=\"hg\">")
    for kind, why, dg, cur, reach, res in tiles:
        inner = hex_tile(0, 0, kind, danger=dg, cur=cur, reachable=reach, resolved=res)
        # re-anchor the absolutely-positioned tile into the swatch box
        inner = inner.replace('style="left:%gpx;top:%gpx;' % (hex_px(0, 0)[0] - HEX_W / 2,
                                                              hex_px(0, 0)[1] - HEX_R), 'style="left:0;top:0;', 1)
        name = "entry" if cur else ("resolved" if res else kind)
        b += '<div class="h1"><div class="hh">%s</div><b>%s</b><i>%s</i></div>' % (inner, name, why)
    return page("Hex tile", "scripts/ui/hex_tile.gd", "Components", b + "</div>", css, stage_h=0,
                note="Every tile kind — terrain fill, glyph, ring, bevel")

def s_crew_bar():
    css = GRID_CSS + """
.bar{position:relative;width:720px;height:74px;margin-bottom:6px;border:1px solid #2c2c38}
.bar *{position:absolute}
.lead{font-size:12px;color:#7a7a88;margin:0 0 14px;max-width:900px;line-height:1.5}
"""
    def bar(ring, seats):
        inner = crew_bar(0, ring=ring, seats=seats)
        inner = inner.replace('<div style="left:0;top:0px;width:720px;height:74px">', "", 1)
        inner = inner.rsplit("</div>", 1)[0]
        return '<div class="bar">%s</div>' % inner
    S = lambda a, b_, c: [("\U0001f6e1️", "Thrain", True, a), ("⛑️", "Bruni", True, b_),
                          ("\U0001f9d9", "Vela", True, c)]
    b = ('<div class="note">The co-op conscience bar. It is <b>chrome</b> — a sibling of the screen root — '
         "so it survives every screen rebuild and is visible on the whole campaign. It answers three "
         "questions at once: <b>who is at the table</b>, <b>what is on the floor</b>, and "
         "<b>who still has to say yes</b>.</div>")
    b += "<h2>Idle<span>nothing on the floor — navigate freely</span></h2>"
    b += bar(None, S(False, False, False))
    b += "<h2>Ring open<span>a shared-risk proposal — proposing IS your aye</span></h2>"
    b += bar(("Bruni", "move to ⚔️ a hex (☠☠)", 1, 3),
             [("\U0001f6e1️", "Thrain", True, False), ("⛑️", "Bruni", True, True),
              ("\U0001f9d9", "Vela", True, False)])
    b += "<h2>You have agreed<span>the Agree button becomes “waiting…”</span></h2>"
    b += bar(("Bruni", "\U0001f3f3️ extract (+36g)", 2, 3), S(True, True, False))
    b += "<h2>A seat went quiet<span>silent 12s → \U0001f4a4 pruned from the ring, so nobody is locked out</span></h2>"
    b += bar(("Thrain", "end the month (rent 55g comes due)", 1, 2),
             [("\U0001f6e1️", "Thrain", True, True), ("⛑️", "Bruni", True, False),
              ("\U0001f9d9", "Vela", False, False)])
    b += "<h2>What needs a ring<span>consequence decides the tier — not the name</span></h2>"
    b += ("<table><tr><th>needs everyone</th><th>yours alone, instantly</th></tr>"
          "<tr><td>embark on a contract<br>move to a hex<br>extract<br>an event choice<br>end the month<br>"
          "a shop buy that dips <i>below the rent line</i></td>"
          "<td>navigating menus<br>selecting a contract to read it<br>claiming a loot card (first tap wins)<br>"
          "an affordable shop buy<br>playing a card in combat<br>ending your own turn</td></tr></table>")
    return page("Crew bar — the ring of ayes", "scripts/overworld/overworld.gd · _refresh_ring",
                "Components", b, css, stage_h=0,
                note="Who is here · what is proposed · who still has to say yes")

def s_enemy():
    css = GRID_CSS + """
.eg{display:flex;flex-wrap:wrap;gap:14px;width:100%;max-width:1180px}
.e1{width:174px;background:#1c1c24;border:1px solid #2c2c38;border-radius:8px;padding:12px;text-align:center}
.e1 .em{font-size:40px;line-height:1.1}
.e1 b{display:block;font-size:14px;margin-top:2px}
.e1 .hp{font-size:12px;color:#8b8b99}
.e1 .pf{font-size:11px;color:#7a7a88;line-height:1.4;margin-top:6px}
.e1 .mv{font-size:12px;margin-top:8px;line-height:1.8;text-align:left}
.panel{position:relative;width:480px;height:92px;background:rgba(18,18,26,.97);
  border-bottom:1px solid rgba(255,255,255,.14);margin-top:6px}
.panel *{position:absolute}
"""
    ens = [
        ("Brute", "\U0001f479", "45 hp · atk 9", "tankiest — block, then max HP. Easy to bait with Taunt.",
         [("attack", "\U0001f5e1️ Smash 9"), ("attack", "\U0001f5e1️ Smash 9"), ("attack", "\U0001f4a2 CRUSH 14")]),
        ("Assassin", "\U0001f977", "30 hp · atk 6", "Healer → DPS. Skips the tank unless forced.",
         [("attack", "\U0001f5e1️ Stab 6"), ("expose", "\U0001f4a5 Expose"), ("multi", "\U0001f5e1️ Flurry 3×3")]),
        ("Caster", "\U0001f52e", "28 hp · atk 5", "lowest current HP — snipes the weakest.",
         [("attack", "\U0001f5e1️ Zap 5"), ("block", "\U0001f6e1️ Ward 6"), ("attack", "\U0001f4a2 Bolt 10")]),
        ("Wolf", "\U0001f43a", "22 hp · atk 5", "lowest HP — and its Howl buffs the whole pack, permanently.",
         [("attack", "\U0001f5e1️ Bite 5"), ("rage_all", "\U0001f4e3 Howl +2"), ("attack", "\U0001f5e1️ Bite 5")]),
        ("Warden", "\U0001f5ff", "40 hp · atk 7", "tankiest — walls its allies, then trades.",
         [("guard_all", "\U0001f6e1️ Bulwark 8"), ("attack", "\U0001f5e1️ Slam 7"), ("attack", "\U0001f5e1️ Slam 7")]),
        ("Witch", "\U0001f9ff", "26 hp · atk 6", "lowest HP — and her Shriek hits every dwarf.",
         [("attack_all", "\U0001f300 Shriek 3×all"), ("expose", "\U0001f4a5 Hex"), ("attack", "\U0001f4a2 Blast 7")]),
        ("Ogre", "\U0001f47a", "55 hp · atk 10", "tankiest — braces, then a two-beat crush. Time your blocks.",
         [("block", "\U0001f6e1️ Brace 5"), ("attack", "\U0001f4a2 CRUSH 16")]),
    ]
    b = ('<div class="note">Seven enemies, each a <b>fixed rotation</b> of telegraphed moves started at a '
         "random offset, plus a <b>preferred target</b> the threat arrow draws live. There is no hidden "
         "information in a fight — you can always see who is about to be hit, for how much, and by what. "
         "That is the whole puzzle.</div><div class=\"eg\">")
    for n, e, hp, pf, moves in ens:
        b += '<div class="e1"><div class="em">%s</div><b>%s</b><div class="hp">%s</div>' % (e, n, hp)
        b += '<div class="pf">%s</div><div class="mv">' % pf
        for k, t in moves:
            b += '<div style="color:%s">%s</div>' % (INTENT_COL[k], t)
        b += "</div></div>"
    b += "</div>"
    b += "<h2>Intent panel<span>hover or tap an enemy — the y 40–132 band, x-clamped</span></h2>"
    b += ('<div class="panel">'
          '<div style="left:10px;top:4px;font-size:15px;color:#fff">\U0001f52e Caster — \U0001f6e1️ Ward 6</div>'
          '<div style="left:10px;top:27px;font-size:12px;color:#c7c7d1">Shields itself — the ward soaks your next hits.</div>'
          '<div style="left:10px;top:47px;font-size:12px;color:#f2cc73">Next: \U0001f4a2 Bolt 10</div>'
          '<div style="left:10px;top:68px;font-size:11px;color:#9eb3cc">Snipes the weakest — targets whoever has the lowest current HP.</div>'
          "</div>")
    b += "<h2>Threat arrow<span>enemy → its target, live · kills reroute it · Taunt snaps them all to the Warrior</span></h2>"
    b += ('<div class="note">3px shaft, 9px head, <code>rgba(242,77,77,.65)</code>. Drawn above the board and '
          "below the cards, so it never fights the hand for attention.</div>")
    return page("Enemies + intent", "card_db.gd · ENEMIES / combat.gd · _intent_text", "Components",
                b, css, stage_h=0, note="7 enemies, their move rotations, and the telegraph grammar")

# ================================================================ landing page
def s_index():
    groups = [
        ("Screens", "every major game scene, at the true 720×1280 portrait", [
            ("screens/main-menu.html", "Main Menu", "Solo · Host · Join"),
            ("screens/lobby.html", "Lobby", "room code · seats · dorf pick"),
            ("screens/combat.html", "Combat", "co-op, simultaneous — the party puzzle"),
            ("screens/dashboard.html", "Company Dashboard", "the roster + the rent clock"),
            ("screens/contracts.html", "Contracts + Shop", "pick a job · buy against the rent"),
            ("screens/expedition.html", "Expedition", "hex crawl · the ring of ayes"),
            ("screens/spoils.html", "Spoils", "one card leaves the room"),
            ("screens/event.html", "Event", "a shared-risk choice"),
            ("screens/outcome.html", "Outcome", "rescued / extracted / wiped"),
        ]),
        ("Cards & roles", "the card library + the class-power role sheets", [
            ("cards/neutral.html", "Neutral cards", "chassis + the universal reward pool"),
            ("cards/class.html", "Tank role", "Barbarian · Fighter · Paladin"),
            ("cards/support.html", "Support role", "Cleric · Bard · Druid"),
            ("cards/dps.html", "DPS role", "Sorcerer · Rogue · Monk"),
            ("cards/lab.html", "Card Lab", "blank bench + the op vocabulary"),
        ]),
        ("Components", "the reusable pieces the screens are built from", [
            ("components/card.html", "Card", "130×188 — anatomy, tints, states"),
            ("components/crew-bar.html", "Crew bar", "the ring of ayes"),
            ("components/hex-tile.html", "Hex tile", "every tile kind"),
            ("components/enemies.html", "Enemies + intent", "7 enemies, the telegraph grammar"),
        ]),
        ("Foundations", "the grammar everything obeys", [
            ("foundations/palette.html", "Palette", "the colour grammar"),
            ("foundations/status-glyphs.html", "Status glyphs", "15 glyphs, one meaning each"),
        ]),
    ]
    css = """
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:#0b0b0e;color:#e6e7ea;
  font-family:"Segoe UI",system-ui,-apple-system,"Noto Sans",sans-serif}
.wrap{max-width:1120px;margin:0 auto;padding:48px 28px 72px}
h1{font-size:34px;letter-spacing:.02em}
.sub{color:#8b8b99;font-size:15px;margin-top:8px;line-height:1.5;max-width:760px}
.sub b{color:#c7c7d1}
h2{font-size:14px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:#8b8b99;
  margin:38px 0 4px}
h2 span{color:#5c5c68;letter-spacing:0;text-transform:none;font-weight:400;margin-left:10px;font-size:12.5px}
.grid{display:flex;flex-wrap:wrap;gap:14px;margin-top:14px}
a.tile{display:block;width:250px;background:#16161d;border:1px solid #2c2c38;border-radius:10px;
  padding:15px 16px;text-decoration:none;color:inherit;transition:border-color .12s,transform .12s}
a.tile:hover{border-color:#5a5a6e;transform:translateY(-2px)}
a.tile b{display:block;font-size:15px;color:#e6e7ea}
a.tile i{display:block;font-size:12px;color:#8b8b99;font-style:normal;margin-top:4px;line-height:1.4}
a.tile code{font-size:11px;color:#5c5c68;font-family:ui-monospace,Consolas,monospace;margin-top:7px;display:block}
.foot{margin-top:52px;color:#5c5c68;font-size:12px;line-height:1.6}
"""
    b = ('<div class="wrap"><h1>Dorf Company — Design Workspace</h1>'
         '<p class="sub">A pixel-faithful recreation of every major game scene at the true '
         "720×1280 portrait viewport, plus the card library and the class-power role sheets. "
         "Each page is built from the real coordinates, colours and strings in the Godot source, so a "
         "change here maps 1:1 back to a Godot coordinate. <b>Draft — unsimmed numbers.</b></p>")
    for head, sub, items in groups:
        b += '<h2>%s<span>%s</span></h2><div class="grid">' % (head, sub)
        for path, name, note in items:
            b += ('<a class="tile" href="%s"><b>%s</b><i>%s</i><code>%s</code></a>'
                   % (path, name, note, path))
        b += "</div>"
    b += ('<div class="foot">Generated by <code>gen_design.py</code> · also lives in the '
          "Claude Design workspace. This is design exploration, not the shipped build.</div></div>")
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "<title>Dorf Company — Design Workspace</title>\n<style>%s</style></head>\n"
            "<body>\n%s\n</body></html>\n" % (css, b))

# ================================================================ write
FILES = [
    ("index.html", s_index),
    ("foundations/palette.html", s_palette),
    ("foundations/status-glyphs.html", s_status),
    ("components/card.html", s_card_anatomy),
    ("components/crew-bar.html", s_crew_bar),
    ("components/hex-tile.html", s_hex_component),
    ("components/enemies.html", s_enemy),
    ("screens/main-menu.html", s_main_menu),
    ("screens/lobby.html", s_lobby),
    ("screens/combat.html", s_combat),
    ("screens/dashboard.html", s_dashboard),
    ("screens/contracts.html", s_contracts),
    ("screens/expedition.html", s_expedition),
    ("screens/spoils.html", s_spoils),
    ("screens/event.html", s_event),
    ("screens/outcome.html", s_outcome),
    ("cards/neutral.html", s_cards_neutral),
    ("cards/class.html", s_cards_roles),
    ("cards/support.html", s_cards_support),
    ("cards/dps.html", s_cards_dps),
    ("cards/lab.html", s_card_lab),
]

for path, fn in FILES:
    full = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(fn())
    print("wrote", path)
print("\n%d files -> %s" % (len(FILES), OUT))
