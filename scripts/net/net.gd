extends Node
## Net — Supabase Realtime (Phoenix) client for Dorf Company co-op.
##
## Native WebSocketPeer, so the SAME code runs in the editor and the web (wasm) export
## (no JavaScriptBridge). Autoloaded as `Net`, but INERT until connect_realtime() is
## called — it does not dial in _ready, so it ships harmlessly in the overworld build.
## Speaks the Phoenix vsn=2.0.0 ARRAY frame protocol: [join_ref, ref, topic, event, payload].
## See docs/plans/2026-07-10-multiplayer-coop-design.md §4.

const Config := preload("res://scripts/net/net_config.gd")

signal realtime_connected                       # socket open (pre-join)
signal realtime_joined                          # channel join acked by the server
signal realtime_error(msg: String)
signal realtime_closed(code: int, reason: String)
signal message_received(event: String, payload: Dictionary)

enum State { OFFLINE, CONNECTING, JOINING, JOINED }
const HEARTBEAT_SEC := 20.0                     # Phoenix idles out ~25s; stay well under

var _ws: WebSocketPeer = null
var _state: int = State.OFFLINE
var _topic := ""
var _ref := 0
var _join_ref := ""
var _hb_accum := 0.0
var _self_echo := false                         # broadcast.self — true only for the self-test

func is_online() -> bool:
	return _state == State.JOINED

## Dial a room by code. self_echo=true asks the server to echo our OWN broadcasts back
## (used only to self-test the round-trip on a single client; production uses false).
func connect_realtime(room_code: String, self_echo := false) -> void:
	disconnect_realtime()
	_self_echo = self_echo
	_topic = Config.room_topic(room_code)
	_ref = 0
	_join_ref = ""
	_hb_accum = 0.0
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(Config.socket_url())
	if err != OK:
		_ws = null
		realtime_error.emit("connect_to_url failed: %d" % err)
		return
	_state = State.CONNECTING

func disconnect_realtime() -> void:
	if _ws != null:
		_ws.close()
	_ws = null
	_state = State.OFFLINE

## Fire a broadcast to the room. event = our app message type (e.g. "action", "snapshot").
func send_message(event: String, payload: Dictionary) -> void:
	if _state != State.JOINED:
		return
	_send_frame(_join_ref, _next_ref(), _topic, "broadcast",
		{"type": "broadcast", "event": event, "payload": payload})

func _next_ref() -> String:
	_ref += 1
	return str(_ref)

func _send_frame(join_ref: Variant, ref: String, topic: String, event: String, payload: Dictionary) -> void:
	if _ws == null:
		return
	_ws.send_text(JSON.stringify([join_ref, ref, topic, event, payload]))

func _send_join() -> void:
	_join_ref = _next_ref()
	_send_frame(_join_ref, _join_ref, _topic, "phx_join",
		{"config": {"broadcast": {"self": _self_echo, "ack": false}, "presence": {"key": ""}, "private": false}})
	_state = State.JOINING

func _send_heartbeat() -> void:
	_send_frame(null, _next_ref(), "phoenix", "heartbeat", {})

func _process(delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if _state == State.CONNECTING:
				realtime_connected.emit()
				_send_join()
			_hb_accum += delta
			if _hb_accum >= HEARTBEAT_SEC:
				_hb_accum = 0.0
				_send_heartbeat()
			while _ws != null and _ws.get_available_packet_count() > 0:
				_on_text(_ws.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			var code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			_ws = null
			_state = State.OFFLINE
			realtime_closed.emit(code, reason)

func _on_text(txt: String) -> void:
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_ARRAY or (parsed as Array).size() < 5:
		return
	var arr: Array = parsed
	var ref: Variant = arr[1]
	var event: String = str(arr[3])
	var payload: Variant = arr[4]
	match event:
		"phx_reply":
			var status := ""
			if typeof(payload) == TYPE_DICTIONARY:
				status = str((payload as Dictionary).get("status", ""))
			if _state == State.JOINING and str(ref) == _join_ref:
				if status == "ok":
					_state = State.JOINED
					realtime_joined.emit()
				else:
					realtime_error.emit("join refused: " + txt)
		"broadcast":
			if typeof(payload) == TYPE_DICTIONARY:
				var ev := str((payload as Dictionary).get("event", ""))
				var data: Variant = (payload as Dictionary).get("payload", {})
				if typeof(data) != TYPE_DICTIONARY:
					data = {}
				message_received.emit(ev, data)
		"phx_error", "phx_close":
			realtime_error.emit(event + ": " + txt)
		_:
			pass  # system / presence_state / presence_diff — swallow
