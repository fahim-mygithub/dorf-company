extends RefCounted

## Supabase Realtime relay config for Dorf Company co-op.
##
## These values ship in the PUBLIC web bundle by design (friends-only threat model,
## see docs/plans/2026-07-10-multiplayer-coop-design.md §4/§10). This is a DEDICATED
## relay-only project ("dorf-company") with no tables, so the anon key exposes nothing;
## data safety does not rely on hiding it. Channels are namespaced "dorf:room:<code>".
const SUPABASE_REF := "bhyywxapswvqjhjnsbnw"
const SUPABASE_ANON := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJoeXl3eGFwc3d2cWpoam5zYm53Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM3MDk2ODYsImV4cCI6MjA5OTI4NTY4Nn0.zqwNxWPdZaTeNRv-ThHifd9nhoXT9Ay5ZA69AaVTs1E"

## Phoenix Realtime websocket URL. vsn=2.0.0 => ARRAY frame format.
static func socket_url() -> String:
	return "wss://%s.supabase.co/realtime/v1/websocket?apikey=%s&vsn=2.0.0" % [SUPABASE_REF, SUPABASE_ANON]

## Phoenix topic for a room. "realtime:" prefix is required by Supabase Realtime;
## "dorf:room:" namespaces us away from any other project traffic.
static func room_topic(code: String) -> String:
	return "realtime:dorf:room:%s" % code
