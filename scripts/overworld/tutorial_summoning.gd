extends RefCounted
class_name TutorialSummoning
## THE SUMMONING — the campaign's opening scene and its entire tutorial.
##
## 28 beats, one button. A demon lord gloats, is handed a job application, and then explains the
## rent clock with visible contempt. Runs ONCE per fresh campaign (see overworld `_new_run`).
##
## Structure: Act I beats 1-6 (the gloat) · Act II 7-20 (the interview) · Act III 21-28 (onboarding).
## There are deliberately NO choices and NO dice here — the choice band prints its own consequences
## and the odds bar shows all three outcomes before you commit, so both teach themselves on first
## contact. A cutscene only needs to explain what the UI cannot say for itself: the rent clock.
##
## `focus` names a rect the overworld hands us in ctx.focus_rects. A focus whose rect is missing
## degrades to a plain beat, so a beat pointing at a screen we are not on still reads fine.

const CAST := {
	"belzenlok": {"name": "Belzenlok", "art": "😈", "metal": Color(0.553, 0.122, 0.141)},
}

## The one line to change if the name ever needs to be legally ours.
## Demonlord Belzenlok is a Magic: The Gathering card (Dominaria, WotC) — an in-fiction
## "not affiliated" gag is not a defence. BELZENAK / BALZENHOLD / VELZENOK keep the mouthfeel.
const DEMON := "belzenlok"

static func beats() -> Array:
	return [
		# ---------------------------------------------------------- ACT I — the gloat
		{"who": "", "art": "🕯️",
		 "body": "The circle is chalk. The candles are from a supermarket. The incantation was transcribed off a forum post with four replies, three of which said \"fake\"."},

		{"who": DEMON, "side": "left",
		 "body": "\"AT LAST. THE SEVENTH SEAL BUCKLES. THE AIR CURDLES. WHO DARES—\"",
		 "auto_ms": 1400},

		{"who": "", "art": "🚨",
		 "body": "The smoke alarm goes off."},

		{"who": DEMON, "side": "left",
		 "body": "\"—WHO DARES SUMMON BELZENLOK, DEVOURER OF THE NINE LEGIONS, WARDEN OF THE ASH GATE, HE WHO BROKE THE ARCHANGEL SEPTIMUS OVER ONE KNEE—\""},

		{"who": DEMON, "side": "left",
		 "body": "\"I HAVE RULED HELL FOR NINE THOUSAND YEARS. I HAVE SUBJUGATED ARMIES THAT DARKENED CONTINENTS. I HAVE MADE KINGS EAT THEIR OWN CROWNS.\"",
		 "aside": "The smoke alarm is still going."},

		{"who": DEMON, "side": "left",
		 "body": "\"SPEAK, MORTAL. NAME YOUR DEEPEST, DARKEST DESIRE, AND I SHALL SEE IT DONE IN BLOOD AND IN FIRE.\""},

		# ---------------------------------------------------------- ACT II — the interview
		{"who": "", "art": "📋", "hold_ms": 1600,
		 "body": "You point at the desk. On it: one (1) job application, printed single-sided, very slightly damp."},

		{"who": DEMON, "side": "left",
		 "body": "\"…What is that.\""},

		# THE SWAP — first time the light moves. In co-op the face that lights is your own dorf.
		{"who": "@us", "side": "right",
		 "prev": "\"…NAME YOUR DEEPEST, DARKEST DESIRE.\"",
		 "body": "\"It's a job application. The ritual was posted in a careers forum. I thought it was a networking thing.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"A networking thing.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"…Do you have a resume.\""},

		{"who": "", "art": "📄",
		 "body": "You produce it. It is laminated."},

		{"who": DEMON, "side": "left", "hold_ms": 2200,
		 "body": "\"…Master of Business Administration.\""},

		{"who": "", "art": "💨",
		 "body": "He sighs. It is a sound like a mausoleum exhaling."},

		{"who": DEMON, "side": "left",
		 "body": "\"This is useless. This is worse than useless. I have devoured theologians. I could have USED a theologian.\""},

		{"who": "", "art": "🧮",
		 "body": "Then something behind his eyes changes. It is not mercy. It is arithmetic."},

		{"who": DEMON, "side": "left", "hold_ms": 1200,
		 "body": "\"Although.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"I have a vacancy. Middle management. There is a company of dwarves in my portfolio and no one to stand between me and their paperwork.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"It is NOT a pyramid scheme. It is a downward-facing opportunity structure. The dwarves came to me the same way — debts, most of them, from ventures that were also legitimate. They owe monthly. We call it a tithe. You will call it Managerial Expenses.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"Should the Company fail to make its Expenses, your contract converts. You will be a dorf. In someone else's company. I am told the pay is worse.\"",
		 "aside": "He lets that sit."},

		# ---------------------------------------------------------- ACT III — onboarding
		{"who": "", "art": "🗄️",
		 "body": "The room is gone. There is a desk that was not there before, and on it, everything you now own."},

		{"who": DEMON, "focus": "hud_rent", "art": "😈",
		 "body": "\"That number. Not the others — THAT one. It rises every month whether you work or not, and when you cannot meet it, the arrangement ends.\"",
		 "aside": "He does not say what \"ends\" means. He has already told you."},

		{"who": DEMON, "focus": "hud_treasury", "art": "😈",
		 "body": "\"This is the treasury. It is not yours. You are its custodian, in the way a bucket is the custodian of water.\""},

		{"who": DEMON, "focus": "roster", "art": "😈",
		 "body": "\"Your dwarves. They have names, which I encourage you not to learn — they wound, they die, and they are replaced, and the replacing is the job.\"",
		 "aside": "He delivers this as though it were the good news."},

		{"who": DEMON, "focus": "contract_board", "art": "😈",
		 "body": "\"Work. Three postings a month, each with a danger rating and a payout, and the relationship between those two numbers is the only thinking this job requires.\""},

		{"who": DEMON, "focus": "end_month", "art": "😈",
		 "body": "\"When you have nothing left worth doing, close the month. The rent comes due, and I will be there to collect it.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"On an expedition you may push deeper, or you may leave with what you have. Leaving is a button. Managers who never press it become dwarves rather quickly.\""},

		{"who": DEMON, "side": "left",
		 "body": "\"Month one begins now. Do not disappoint me. I have a spreadsheet, and you are on it.\""},
	]
