class_name REEEplayHighlightDetector
extends RefCounted
## Scores recorded event clusters to detect exciting highlight windows for timeline bookmarking.


class HighlightWindow extends RefCounted:
	var start_tick: int = 0
	var end_tick: int = 0
	var peak_tick: int = 0
	var score: float = 0.0
	var tags: Array[StringName] = []


## Scans events and returns sorted highlight windows above min_score.
static func detect(
	events: Array[REEEplayEvent],
	tick_rate: int,
	window_seconds: float = 8.0,
	min_score: float = 3.0,
	weights: Dictionary = {}
) -> Array[HighlightWindow]:
	if events.is_empty():
		return []

	var window_ticks := maxi(1, roundi(window_seconds * float(maxi(1, tick_rate))))
	var sorted := events.duplicate()
	sorted.sort_custom(func(a: REEEplayEvent, b: REEEplayEvent) -> bool:
		return a.tick < b.tick
	)

	var windows: Array[HighlightWindow] = []
	var n := sorted.size()
	var i := 0
	while i < n:
		var start_ev: REEEplayEvent = sorted[i]
		var w_start: int = start_ev.tick
		var w_end: int = w_start + window_ticks
		var total_score := 0.0
		var best_tick := w_start
		var best_weight := -1.0
		var tag_set: Dictionary[StringName, bool] = {}

		var j := i
		while j < n and (sorted[j] as REEEplayEvent).tick <= w_end:
			var ev: REEEplayEvent = sorted[j]
			var w := float(weights.get(ev.type_id, ev.highlight_weight()))
			total_score += w
			if w > best_weight:
				best_weight = w
				best_tick = ev.tick
			for t in ev.highlight_tags():
				tag_set[t] = true
			j += 1

		if total_score >= min_score:
			var hw := HighlightWindow.new()
			hw.start_tick = w_start
			hw.end_tick = sorted[j - 1].tick
			hw.peak_tick = best_tick
			hw.score = total_score
			for t in tag_set:
				hw.tags.append(t)
			windows.append(hw)
			i = j
		else:
			i += 1

	windows.sort_custom(func(a: HighlightWindow, b: HighlightWindow) -> bool:
		return a.score > b.score
	)
	return windows
