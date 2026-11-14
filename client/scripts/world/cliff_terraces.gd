extends RefCounted
## Cliff plateaus, drawn only. Factorio's map is flat; a cliff is a chain of pieces on a 4 x 4
## grid with the high ground on its left (model_library.gd CLIFF_PIECES). The cliff meshes are
## ridges (tools/models/nature/cliffs.py), so on flat ground both sides look level and the rock
## reads as a wall. This lifts the ground on the high side into a shelf, up to the rock's crest,
## and leaves the green channel at 0 so the rock (ground_low) stays on the low ground and its
## face is the drop. The back of the ridge sits under the shelf.
##
## Nothing here moves an entity or changes a build order. The mouse walks the drawn ground the
## same way an add-on's hills do (ground_height.gd ray_hit) and the point comes back at y = 0, so
## picking and placement stay in Factorio's tile plane. A hills add-on that sets its own field
## (api.terrain, owner its id) replaces this whole field, plateaus included; clearing that field
## brings the plateaus back. Off with Settings → Graphics → Cliff plateaus.

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Settings := preload("res://scripts/menu/settings.gd")

const OWNER := "cliffs"
## Tiles. A little under the cliff mesh's crest (profile 0.76 of 2.5), so the rock's lip shows
## above the shelf and the face drops to the low ground.
const HEIGHT := 1.7
const STEP := 2.0
const SIZE := 512  # texels: 1,024 tiles across, enough for Ultra's view with the border fade
const REACH := 72.0  # tiles the shelf extends from a cliff before it eases back to flat
const END_RAMP := 14.0  # tiles past a chain's free end over which the shelf ramps down
const STEP_FROM := -1.55  # tiles onto the low side where the rise starts (the face's foot)
const STEP_TO := -0.2  # full height just onto the low side, under the crest
const EDGE := 24  # texels faded to flat at the grid's border
const RECENTRE := 128.0
const SETTLE := 0.6
const CHUNKS_PER_FRAME := 8
const CHUNK := 32


## One cliff piece as the segment it runs, from the middle of one edge of its cell to another
## ("none": the cell's middle). Empty when the orientation isn't a run.
static func segment(pos: Vector2, orientation: String) -> PackedVector2Array:
	var parts := orientation.split("-to-")
	if parts.size() != 2:
		return PackedVector2Array()
	var a := _edge(parts[0])
	var b := _edge(parts[1])
	if a == b:
		return PackedVector2Array()
	return PackedVector2Array([pos + a, pos + b])


static func _edge(name: String) -> Vector2:
	match name:
		"west":
			return Vector2(-2, 0)
		"east":
			return Vector2(2, 0)
		"north":
			return Vector2(0, -2)
		"south":
			return Vector2(0, 2)
	return Vector2.ZERO


## Endpoints no other piece shares: where a chain starts or stops, or a gap was blown in it.
## Keys are _q of the point.
static func free_ends(segments: Array) -> Dictionary:
	var degree := {}
	for seg in segments:
		var s: PackedVector2Array = seg
		if s.size() < 2:
			continue
		for p in [s[0], s[1]]:
			var k := _q(p)
			degree[k] = int(degree.get(k, 0)) + 1
	var open := {}
	for k in degree:
		if int(degree[k]) == 1:
			open[k] = true
	return open


static func _q(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * 2.0), roundi(p.y * 2.0))


## Distance to one segment, the signed side (positive on the high side, Factorio's left) and how
## far past a free end the closest point lies. (1e9, 0, 0) when the piece has no length.
static func _measure(p: Vector2, a: Vector2, b: Vector2, a_free: bool, b_free: bool) -> Vector3:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.00000001:
		return Vector3(1.0e9, 0.0, 0.0)
	var length := sqrt(l2)
	var t := (p - a).dot(ab) / l2
	var tc := clampf(t, 0.0, 1.0)
	var diff := p - (a + ab * tc)
	var side := (diff.x * ab.y - diff.y * ab.x) / length
	var past := 0.0
	if tc <= 0.0 and a_free:
		past = maxf(-t, 0.0) * length
	elif tc >= 1.0 and b_free:
		past = maxf(t - 1.0, 0.0) * length
	return Vector3(diff.length(), side, past)


## The nearest segment's (distance, side, past).
static func nearest(p: Vector2, segments: Array, open: Dictionary) -> Vector3:
	var best := Vector3(1.0e9, 0.0, 0.0)
	for seg in segments:
		var s: PackedVector2Array = seg
		if s.size() < 2:
			continue
		var m := _measure(p, s[0], s[1], open.has(_q(s[0])), open.has(_q(s[1])))
		if m.x < best.x - 0.000001 or (absf(m.x - best.x) < 0.000001 and m.z < best.z):
			best = m
	return best


## The shelf's height at `p`, in tiles. 0 on the low side, past a chain's end and far from every cliff.
static func sample(p: Vector2, segments: Array, open: Dictionary) -> float:
	return _raised(nearest(p, segments, open))


static func _raised(n: Vector3) -> float:
	if n.x > REACH:
		return 0.0
	var past := n.z
	var widen := minf(past, END_RAMP) * 0.45
	var k := smoothstep(STEP_FROM - widen, STEP_TO + widen, n.y)
	var end := 1.0 - smoothstep(0.0, END_RAMP, past)
	var reach := 1.0 - smoothstep(REACH * 0.7, REACH, n.x)
	return HEIGHT * k * end * reach


## The field's red channel (the shelf), row by row. `wet` is chunk -> 32 x 32 tile kinds (0 land,
## anything else pulled back to 0, so a lake keeps its level). The border fades to flat.
static func grid(segments: Array, open: Dictionary, origin: Vector2, size: int, step: float, wet: Dictionary = {}) -> PackedFloat32Array:
	var n := size * size
	var best := PackedFloat32Array()
	var side := PackedFloat32Array()
	var past := PackedFloat32Array()
	best.resize(n)
	side.resize(n)
	past.resize(n)
	best.fill(1.0e9)
	for seg in segments:
		var s: PackedVector2Array = seg
		if s.size() < 2:
			continue
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var a_free := open.has(_q(a))
		var b_free := open.has(_q(b))
		var min_x := minf(a.x, b.x) - REACH
		var max_x := maxf(a.x, b.x) + REACH
		var min_y := minf(a.y, b.y) - REACH
		var max_y := maxf(a.y, b.y) + REACH
		var i0 := maxi(int(floor((min_x - origin.x) / step)), 0)
		var i1 := mini(int(floor((max_x - origin.x) / step)), size - 1)
		var j0 := maxi(int(floor((min_y - origin.y) / step)), 0)
		var j1 := mini(int(floor((max_y - origin.y) / step)), size - 1)
		for j in range(j0, j1 + 1):
			var row := j * size
			var cz := origin.y + (float(j) + 0.5) * step
			for i in range(i0, i1 + 1):
				var p := Vector2(origin.x + (float(i) + 0.5) * step, cz)
				var m := _measure(p, a, b, a_free, b_free)
				if m.x > REACH:
					continue
				var idx := row + i
				if m.x < best[idx] - 0.000001 or (absf(m.x - best[idx]) < 0.000001 and m.z < past[idx]):
					best[idx] = m.x
					side[idx] = m.y
					past[idx] = m.z
	var h := PackedFloat32Array()
	h.resize(n)
	for idx in n:
		h[idx] = _raised(Vector3(best[idx], side[idx], past[idx]))
	for c in wet:
		var kinds: PackedByteArray = wet[c]
		if kinds.size() != CHUNK * CHUNK:
			continue
		var base := Vector2(c) * float(CHUNK)
		for t in kinds.size():
			if kinds[t] == 0:
				continue
			var wx := base.x + float(t % CHUNK) + 0.5
			var wy := base.y + float(t / CHUNK) + 0.5
			var i := int(floor((wx - origin.x) / step))
			var j := int(floor((wy - origin.y) / step))
			if i < 0 or j < 0 or i >= size or j >= size:
				continue
			h[j * size + i] = 0.0
	if EDGE > 0:
		for j in size:
			var fj := mini(j, size - 1 - j)
			for i in size:
				var f := mini(mini(i, size - 1 - i), fj)
				if f < EDGE:
					h[j * size + i] *= smoothstep(0.0, float(EDGE), float(f))
	return h


## The red/green image for ground_height.gd, or null when the shelf is flat everywhere in the grid
## (green stays 0: cliff meshes sit on the low ground). Called on a worker.
static func _bake_image(segments: Array, open: Dictionary, origin: Vector2, wet: Dictionary) -> Image:
	var h := grid(segments, open, origin, SIZE, STEP, wet)
	var peak := 0.0
	for v in h:
		if v > peak:
			peak = v
	if peak < 0.001:
		return null
	var rg := PackedFloat32Array()
	rg.resize(h.size() * 2)
	for i in h.size():
		rg[i * 2] = h[i]
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGF, rg.to_byte_array())


## Runs the bake on a worker without holding the driver: [task id, [image], generation, origin].
static func _queue_bake(segments: Array, open: Dictionary, origin: Vector2, wet: Dictionary, gen: int) -> Array:
	var out: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void: out[0] = _bake_image(segments, open, origin, wet), false, "Cliff plateaus")
	return [task, out, gen, origin]


var _watched := 0
var _packed := {}  # Vector2i -> PackedFloat32Array of that chunk's segments
var _queue: Array = []
var _queued := {}
var _dirty := true
var _quiet := 0.0
var _centre := Vector2.INF
var _gen := 0
var _job: Array = []  # [task id, [image], generation, origin]; empty when none is running
## The last bake was flat, so it isn't asked for again until the cliffs move or the view does.
var _flat := false


func tick(world, delta: float) -> void:
	_finish_job()
	if not _enabled():
		_flat = false
		_release()
		return
	if world.get_instance_id() != _watched:
		_watched = world.get_instance_id()
		if not world.entities_changed.is_connected(_on_entities):
			world.entities_changed.connect(_on_entities)
		if world.has_signal("tiles_changed") and not world.tiles_changed.is_connected(_on_tiles):
			world.tiles_changed.connect(_on_tiles)
		_packed.clear()
		_queue.clear()
		_queued.clear()
		_centre = Vector2.INF
		_dirty = true
		_flat = false
		for c in world.chunks:
			_enqueue(c)
	_read_some(world)
	_quiet += delta
	var focus: Vector2 = world.focus()
	if _centre == Vector2.INF or focus.distance_to(_centre) > RECENTRE:
		if _centre == Vector2.INF:
			_quiet = SETTLE
		_flat = false
		_dirty = true
	# An add-on cleared its field (or the game started flat): draw the shelf again.
	if not _flat and GroundHeight.owner == "" and not GroundHeight.is_on() and not _packed.is_empty():
		_dirty = true
	if _packed.is_empty() and _queue.is_empty() and _job.is_empty():
		_release()
		_dirty = false
		return
	if _dirty and _job.is_empty() and _queue.is_empty() and _quiet >= SETTLE and _may_write():
		_start_job(world, focus)


func reset() -> void:
	_gen += 1
	_packed.clear()
	_queue.clear()
	_queued.clear()
	_centre = Vector2.INF
	_dirty = true
	_quiet = 0.0
	_flat = false
	_release()


func shutdown() -> void:
	_gen += 1
	if not _job.is_empty():
		WorkerThreadPool.wait_for_task_completion(_job[0])
		_job = []
	_release()


func _enabled() -> bool:
	return bool(Settings.get_value("graphics", "cliff_plateaus"))


## An add-on's field (any owner but ours) wins. A field left on with no owner is a test's or a
## caller's: left alone until it is cleared.
func _may_write() -> bool:
	if GroundHeight.owner == OWNER:
		return true
	return GroundHeight.owner == "" and not GroundHeight.is_on()


func _release() -> void:
	if GroundHeight.owner == OWNER:
		GroundHeight.clear()
		_centre = Vector2.INF


func _enqueue(c: Vector2i) -> void:
	if _queued.has(c):
		return
	_queued[c] = true
	_queue.append(c)


func _on_entities(c: Vector2i) -> void:
	_enqueue(c)


func _on_tiles(_c: Vector2i) -> void:
	_dirty = true
	_quiet = 0.0


func _read_some(world) -> void:
	var n := 0
	while n < CHUNKS_PER_FRAME and not _queue.is_empty():
		var c: Vector2i = _queue.pop_front()
		_queued.erase(c)
		n += 1
		var found := PackedFloat32Array()
		var cv = world.chunks.get(c)
		if cv != null:
			var buf: Array = []
			for key in cv.entities:
				var r = cv.entities[key]
				var proto = world.protos.entity(r.proto_id)
				if proto == null or proto.type != "cliff":
					continue
				var seg := segment(r.pos, str(r.extra.get("co", "")))
				if seg.is_empty():
					continue
				buf.append(seg)
			if not buf.is_empty():
				found.resize(buf.size() * 4)
				var i := 0
				for seg in buf:
					var s: PackedVector2Array = seg
					found[i] = s[0].x
					found[i + 1] = s[0].y
					found[i + 2] = s[1].x
					found[i + 3] = s[1].y
					i += 4
		var before: PackedFloat32Array = _packed.get(c, PackedFloat32Array())
		if found != before:
			if found.is_empty():
				_packed.erase(c)
			else:
				_packed[c] = found
			_dirty = true
			_quiet = 0.0
			_flat = false


func _start_job(world, focus: Vector2) -> void:
	var segments: Array = []
	for c in _packed:
		var raw: PackedFloat32Array = _packed[c]
		var i := 0
		while i + 3 < raw.size():
			segments.append(PackedVector2Array([Vector2(raw[i], raw[i + 1]), Vector2(raw[i + 2], raw[i + 3])]))
			i += 4
	if segments.is_empty():
		_release()
		_dirty = false
		return
	var span := float(SIZE) * STEP
	var origin := ((focus - Vector2(span, span) * 0.5) / 64.0).floor() * 64.0
	_gen += 1
	_job = _queue_bake(segments, free_ends(segments), origin, _wet(world), _gen)
	_centre = origin + Vector2(span, span) * 0.5
	_dirty = false


func _wet(world) -> Dictionary:
	var kinds: PackedByteArray = world.protos.tile_is_water
	if kinds.is_empty():
		return {}
	var out := {}
	for c in world.chunks:
		var cv = world.chunks[c]
		var ids: PackedInt32Array = cv.tile_ids
		if ids.size() != CHUNK * CHUNK:
			continue
		var row := PackedByteArray()
		row.resize(ids.size())
		var any := false
		var kn := kinds.size()
		for i in ids.size():
			var id := ids[i]
			var k := kinds[id] if id >= 0 and id < kn else 0
			row[i] = k
			any = any or k != 0
		if any:
			out[c] = row
	return out


func _finish_job() -> void:
	if _job.is_empty():
		return
	if not WorkerThreadPool.is_task_completed(_job[0]):
		return
	WorkerThreadPool.wait_for_task_completion(_job[0])
	var out: Array = _job[1]
	var gen := int(_job[2])
	var origin: Vector2 = _job[3]
	_job = []
	if gen != _gen or not _enabled() or not _may_write():
		return
	var image: Image = out[0]
	if image == null:
		_flat = true
		_release()
		return
	GroundHeight.set_field(image, origin, STEP, OWNER)
