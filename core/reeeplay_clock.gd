## Time conversion and formatting helpers for REEEplay ticks and seconds.
class_name REEEplayClock
extends RefCounted


## Converts an integer tick to recording seconds.
static func tick_to_seconds(tick: int, tick_rate: int) -> float:
	if tick_rate <= 0:
		return 0.0
	return float(tick) / float(tick_rate)


## Converts recording seconds to the nearest lower integer tick.
static func seconds_to_tick(seconds: float, tick_rate: int) -> int:
	if tick_rate <= 0:
		return 0
	return maxi(0, int(floor(seconds * float(tick_rate))))


## Formats seconds as "M:SS" or "H:MM:SS" when >= 1 hour.
static func format_time(seconds: float) -> String:
	var clamped := maxf(0.0, seconds)
	var total := int(floor(clamped))
	@warning_ignore("integer_division")
	var h := total / 3600
	@warning_ignore("integer_division")
	var m := (total % 3600) / 60
	var s := total % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]
