class_name AdultGate
extends Control
## The grown-up check that stands in front of every account screen
## (DLC_SERVER.md 4.1).
##
## [b]It is a DETERRENT, not security.[/b] The design doc says so in as many words:
## its job is to keep a five year old out of the sign-in screen, and it is the
## industry-normal pattern for exactly that. Anyone who can do arithmetic can pass
## it, which is the point -- the things worth protecting are protected server-side
## (the game token carries no account-mutating abilities at all, DLC_SERVER.md 4.2).
##
## [b]Why the question is spelled out in WORDS.[/b] "What is fourteen plus nine?"
## rather than "14 + 9". A child who can already read digits and tap a number pad
## can brute-force the digit form by accident; reading two number words and adding
## them is a comfortably later skill. The numbers are re-rolled on every wrong
## answer and on every open, so the answer cannot be learnt by repetition.
##
## [b]An overlay, not a screen[/b] -- same reasoning as [SettingsPanel]: it composes
## into [code]main.tscn[/code]'s overlay layer over whatever is showing. It writes
## nothing, knows nothing about accounts, and only ever reports
## [signal passed] or [signal cancelled]. Signals up, calls down.

## The grown-up answered correctly.
signal passed()
## They gave up, or tapped outside.
signal cancelled()

## Range the two addends are drawn from. The sum stays under 40, so the arithmetic
## is easy for an adult and the words stay short.
const LEFT_RANGE := Vector2i(11, 29)
const RIGHT_RANGE := Vector2i(2, 9)

## Wrong answers before the question is re-rolled (and the hint sharpens).
const ATTEMPTS_BEFORE_RESET := 2

const ONES: PackedStringArray = [
	"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
	"ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
	"seventeen", "eighteen", "nineteen",
]
const TENS: PackedStringArray = [
	"", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
]

@onready var _scrim: Button = $Scrim
@onready var _question: Label = $Center/Panel/Margin/Column/Question
@onready var _answer: LineEdit = $Center/Panel/Margin/Column/Answer
@onready var _hint: Label = $Center/Panel/Margin/Column/Hint
@onready var _submit_button: Button = $Center/Panel/Margin/Column/Row/SubmitButton
@onready var _cancel_button: Button = $Center/Panel/Margin/Column/Row/CancelButton

var _expected := 0
var _wrong := 0
## BL-48's shared overlay scaler. Held so it is not collected; it parents itself.
var _metrics: OverlayMetrics


func _ready() -> void:
	# BL-48: one number sizes every overlay. The gate's answer field is a text input
	# on a phone, so it gets the touch floor like any button (see OverlayMetrics).
	_metrics = OverlayMetrics.attach(self)
	_scrim.pressed.connect(_on_cancel_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_submit_button.pressed.connect(submit)
	_answer.text_submitted.connect(func(_text: String) -> void: submit())
	_hint.visible = false
	reroll()
	_answer.grab_focus()


## Picks a new question. Called on open and after a wrong answer.
func reroll() -> void:
	var left := randi_range(LEFT_RANGE.x, LEFT_RANGE.y)
	var right := randi_range(RIGHT_RANGE.x, RIGHT_RANGE.y)
	_expected = left + right
	_question.text = "What is %s plus %s?" % [spell(left), spell(right)]
	_answer.text = ""


## Checks the typed answer. Public so a harness can drive the gate without
## synthesising key events.
func submit() -> bool:
	if answer_is_correct():
		passed.emit()
		return true
	_wrong += 1
	if _wrong >= ATTEMPTS_BEFORE_RESET:
		_wrong = 0
		reroll()
		_hint.text = "Not quite — here's a new one. This part is for a grown-up."
	else:
		_hint.text = "That's not it. Type the answer as digits."
	_hint.visible = true
	_answer.grab_focus()
	return false


func answer_is_correct() -> bool:
	return _answer.text.strip_edges().is_valid_int() \
		and int(_answer.text.strip_edges()) == _expected


## Test hook: the number that would pass right now.
func get_expected_answer() -> int:
	return _expected


func get_question_text() -> String:
	return _question.text


func set_answer_text(text: String) -> void:
	_answer.text = text


func get_answer_field() -> LineEdit:
	return _answer


func get_submit_button() -> Button:
	return _submit_button


func get_cancel_button() -> Button:
	return _cancel_button


## BL-48's shared scaler, for the harnesses.
func get_overlay_metrics() -> OverlayMetrics:
	return _metrics


func get_hint_text() -> String:
	return _hint.text if _hint.visible else ""


func _on_cancel_pressed() -> void:
	cancelled.emit()


## An integer 0-99 in words ("twenty-seven"). Only ever fed values from the two
## ranges above, but complete for its domain so the ranges can move freely.
static func spell(value: int) -> String:
	if value < 0 or value > 99:
		return str(value)
	if value < 20:
		return ONES[value]
	var tens := TENS[value / 10]
	var ones := value % 10
	return tens if ones == 0 else "%s-%s" % [tens, ONES[ones]]
