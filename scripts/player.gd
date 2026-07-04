extends CharacterBody3D
class_name PlayerController

signal health_changed(health: int, max_health: int)
signal shot_fired
signal damaged
signal ammo_changed(ammo: int, magazine_size: int, reserve_ammo: int)
signal reload_state_changed(is_reloading: bool)
signal ability_changed(dash_cooldown: float, dash_ready: bool)
signal weapon_changed(weapon_name: String, unlocked_weapons: Array)

@export var bullet_scene: PackedScene = preload("res://scenes/Bullet.tscn")
@export var mouse_sensitivity := 0.0022
@export var move_speed := 8.0
@export var sprint_speed := 11.0
@export var jump_velocity := 7.0
@export var max_health := 5
@export var fire_rate := 0.17
@export var magazine_size := 12
@export var max_reserve_ammo := 60
@export var reload_time := 1.15
@export var dash_speed := 22.0
@export var dash_duration := 0.16
@export var dash_cooldown_time := 1.25

var health := max_health
var ammo := magazine_size
var reserve_ammo := max_reserve_ammo
var pitch := 0.0
var fire_cooldown := 0.0
var last_motion_strength := 0.0
var dead := false
var is_reloading := false
var reload_timer := 0.0
var dash_timer := 0.0
var dash_cooldown := 0.0
var dash_direction := Vector3.ZERO
var damage_multiplier := 1
var buff_timer := 0.0
var infinite_ammo_timer := 0.0
var speed_boost_timer := 0.0
var shield_timer := 0.0
var weapon_profiles := {
	"pistol": {"label": "PISTOL", "mag": 12, "reserve": 72, "fire_rate": 0.17, "reload": 1.05, "pellets": 1, "spread": 0.006, "damage": 1, "speed": 38.0, "tint": Color(0.15, 0.95, 1.0)},
	"shotgun": {"label": "SHOTGUN", "mag": 6, "reserve": 36, "fire_rate": 0.72, "reload": 1.45, "pellets": 7, "spread": 0.085, "damage": 1, "speed": 32.0, "tint": Color(1.0, 0.55, 0.12)},
	"sniper": {"label": "SNIPER", "mag": 4, "reserve": 24, "fire_rate": 0.95, "reload": 1.65, "pellets": 1, "spread": 0.001, "damage": 4, "speed": 72.0, "tint": Color(1.0, 0.92, 0.18)},
	"smg": {"label": "SMG", "mag": 28, "reserve": 140, "fire_rate": 0.075, "reload": 1.2, "pellets": 1, "spread": 0.028, "damage": 1, "speed": 34.0, "tint": Color(0.45, 1.0, 0.35)},
	"railgun": {"label": "RAILGUN", "mag": 3, "reserve": 15, "fire_rate": 1.2, "reload": 1.9, "pellets": 1, "spread": 0.0, "damage": 6, "speed": 92.0, "tint": Color(0.8, 0.35, 1.0)}
}
var weapon_order := ["pistol", "shotgun", "sniper", "smg", "railgun"]
var unlocked_weapons := ["pistol"]
var current_weapon := "pistol"
var ammo_by_weapon := {}
var reserve_by_weapon := {}
var network_send_timer := 0.0
var remote_target_position := Vector3.ZERO
var remote_target_rotation := Vector3.ZERO

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var muzzle: Marker3D = $Head/Camera3D/Gun/Muzzle
@onready var gun: Node3D = $Head/Camera3D/Gun

func _ready() -> void:
	health = max_health
	_init_weapons()
	health_changed.emit(health, max_health)
	ammo_changed.emit(ammo, magazine_size, reserve_ammo)
	ability_changed.emit(dash_cooldown, true)
	weapon_changed.emit(_weapon_label(current_weapon), unlocked_weapons)
	_apply_player_material()
	_update_network_control()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_locally_controlled():
		return
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("is_player_control_enabled") and not game.is_player_control_enabled():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not dead:
		rotate_y(-event.relative.x * mouse_sensitivity)
		pitch = clampf(pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-84), deg_to_rad(84))
		head.rotation.x = pitch


func _physics_process(delta: float) -> void:
	_update_network_control()
	if not _is_locally_controlled():
		return
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("is_player_control_enabled") and not game.is_player_control_enabled():
		velocity = Vector3.ZERO
		return
	if dead:
		velocity = Vector3.ZERO
		return

	fire_cooldown = maxf(fire_cooldown - delta, 0.0)
	dash_cooldown = maxf(dash_cooldown - delta, 0.0)
	buff_timer = maxf(buff_timer - delta, 0.0)
	infinite_ammo_timer = maxf(infinite_ammo_timer - delta, 0.0)
	speed_boost_timer = maxf(speed_boost_timer - delta, 0.0)
	shield_timer = maxf(shield_timer - delta, 0.0)
	if buff_timer <= 0.0:
		damage_multiplier = 1
	if is_reloading:
		reload_timer = maxf(reload_timer - delta, 0.0)
		if reload_timer <= 0.0:
			_finish_reload()

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var basis := global_transform.basis
	var direction := (basis.x * input_dir.x + basis.z * input_dir.y).normalized()
	_handle_weapon_inputs()
	var speed := sprint_speed if Input.is_action_pressed("sprint") else move_speed
	if speed_boost_timer > 0.0:
		speed *= 1.45

	if Input.is_action_just_pressed("dash") and dash_cooldown <= 0.0:
		_start_dash(direction)

	if dash_timer > 0.0:
		dash_timer = maxf(dash_timer - delta, 0.0)
		velocity.x = dash_direction.x * dash_speed
		velocity.z = dash_direction.z * dash_speed
	else:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed

	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity
		else:
			velocity.y = 0.0
	else:
		velocity.y -= 24.0 * delta

	move_and_slide()
	last_motion_strength = clampf(Vector2(velocity.x, velocity.z).length() / sprint_speed, 0.0, 1.0)

	if Input.is_action_just_pressed("reload"):
		start_reload()
	if Input.is_action_pressed("shoot") and fire_cooldown <= 0.0:
		_fire()

	_update_gun_motion(delta)
	ability_changed.emit(dash_cooldown, dash_cooldown <= 0.0)
	_send_network_transform(delta)


func take_damage(amount: int, _hit_position: Vector3) -> void:
	if dead:
		return
	if multiplayer.has_multiplayer_peer() and not _is_locally_controlled():
		return
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("is_player_control_enabled") and not game.is_player_control_enabled():
		return
	if shield_timer > 0.0:
		amount = max(amount - 1, 0)
		if amount <= 0:
			damaged.emit()
			return
	health = max(health - amount, 0)
	health_changed.emit(health, max_health)
	damaged.emit()
	if health <= 0:
		dead = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sync_health_state()


func get_motion_strength() -> float:
	var trigger := 1.0 if Input.is_action_pressed("shoot") else 0.0
	return maxf(last_motion_strength, trigger)


func heal(amount: int) -> void:
	health = min(health + amount, max_health)
	health_changed.emit(health, max_health)


func respawn(spawn_position: Vector3) -> void:
	dead = false
	health = max_health
	velocity = Vector3.ZERO
	global_position = spawn_position
	remote_target_position = spawn_position
	health_changed.emit(health, max_health)
	_apply_player_material()
	_sync_health_state()
	_send_respawn_state()


func add_ammo(amount: int) -> void:
	for weapon in unlocked_weapons:
		var max_reserve = weapon_profiles[weapon]["reserve"]
		reserve_by_weapon[weapon] = min(int(reserve_by_weapon[weapon]) + amount, int(max_reserve))
	reserve_ammo = int(reserve_by_weapon[current_weapon])
	ammo_changed.emit(ammo, magazine_size, reserve_ammo)


func add_power(kind: String, amount: float) -> void:
	match kind:
		"overcharge":
			damage_multiplier = 2
			buff_timer = maxf(buff_timer, amount)
		"damage_boost":
			damage_multiplier = 3
			buff_timer = maxf(buff_timer, amount)
		"infinite_ammo":
			infinite_ammo_timer = maxf(infinite_ammo_timer, amount)
		"dash":
			dash_cooldown = 0.0
		"speed_boost":
			speed_boost_timer = maxf(speed_boost_timer, amount)
		"shield":
			shield_timer = maxf(shield_timer, amount)
	ability_changed.emit(dash_cooldown, dash_cooldown <= 0.0)


func unlock_weapon(weapon: String) -> bool:
	if not weapon_profiles.has(weapon) or unlocked_weapons.has(weapon):
		return false
	unlocked_weapons.append(weapon)
	ammo_by_weapon[weapon] = int(weapon_profiles[weapon]["mag"])
	reserve_by_weapon[weapon] = int(weapon_profiles[weapon]["reserve"])
	switch_weapon(weapon)
	return true


func locked_weapons() -> Array:
	var locked := []
	for weapon in weapon_order:
		if not unlocked_weapons.has(weapon):
			locked.append(weapon)
	return locked


func switch_weapon(weapon: String) -> void:
	if not unlocked_weapons.has(weapon) or current_weapon == weapon:
		return
	_store_current_weapon_ammo()
	current_weapon = weapon
	_apply_weapon_profile()
	is_reloading = false
	reload_state_changed.emit(false)
	weapon_changed.emit(_weapon_label(current_weapon), unlocked_weapons)
	ammo_changed.emit(ammo, magazine_size, reserve_ammo)


func start_reload() -> void:
	if is_reloading or ammo >= magazine_size or reserve_ammo <= 0:
		return
	is_reloading = true
	reload_timer = reload_time
	reload_state_changed.emit(true)


func _fire() -> void:
	if is_reloading:
		return
	if ammo <= 0 and infinite_ammo_timer <= 0.0:
		start_reload()
		return
	fire_cooldown = fire_rate
	if infinite_ammo_timer <= 0.0:
		ammo -= 1
		ammo_by_weapon[current_weapon] = ammo
		ammo_changed.emit(ammo, magazine_size, reserve_ammo)
	var profile: Dictionary = weapon_profiles[current_weapon]
	var pellets := int(profile["pellets"])
	for i in range(pellets):
		var direction := _spread_direction(float(profile["spread"]))
		var damage := int(profile["damage"]) * damage_multiplier
		var game := get_tree().get_first_node_in_group("game")
		if multiplayer.has_multiplayer_peer() and game and game.has_method("request_player_bullet"):
			game.request_player_bullet(muzzle.global_position, direction, float(profile["speed"]), damage, profile["tint"], multiplayer.get_unique_id())
		else:
			var bullet = bullet_scene.instantiate()
			get_tree().current_scene.add_child(bullet)
			bullet.setup_network(muzzle.global_position, direction, float(profile["speed"]), damage, "player", profile["tint"], 0)
	shot_fired.emit()


func _finish_reload() -> void:
	var needed := magazine_size - ammo
	var loaded = min(needed, reserve_ammo)
	ammo += loaded
	reserve_ammo -= loaded
	ammo_by_weapon[current_weapon] = ammo
	reserve_by_weapon[current_weapon] = reserve_ammo
	is_reloading = false
	ammo_changed.emit(ammo, magazine_size, reserve_ammo)
	reload_state_changed.emit(false)


func _start_dash(direction: Vector3) -> void:
	dash_direction = direction
	if dash_direction.length() < 0.1:
		dash_direction = -global_transform.basis.z
	dash_direction = dash_direction.normalized()
	dash_timer = dash_duration
	dash_cooldown = dash_cooldown_time
	ability_changed.emit(dash_cooldown, false)


func _update_gun_motion(delta: float) -> void:
	var target_z := -0.82 - last_motion_strength * 0.04
	if is_reloading:
		target_z = -0.68
	gun.position.z = lerpf(gun.position.z, target_z, delta * 10.0)
	gun.rotation.z = lerpf(gun.rotation.z, -velocity.x * 0.012, delta * 8.0)


func _apply_player_material() -> void:
	var mesh := $Body as MeshInstance3D
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.11, 0.16, 1)
	mat.metallic = 0.15
	mat.roughness = 0.38
	mesh.material_override = mat

	var gun_mesh := $Head/Camera3D/Gun/GunMesh as MeshInstance3D
	var gun_mat := StandardMaterial3D.new()
	gun_mat.albedo_color = Color(0.02, 0.025, 0.03, 1)
	gun_mat.emission_enabled = true
	gun_mat.emission = Color(0.0, 0.35, 0.45)
	gun_mat.emission_energy_multiplier = 0.35
	gun_mesh.material_override = gun_mat


func _init_weapons() -> void:
	for weapon in weapon_order:
		ammo_by_weapon[weapon] = int(weapon_profiles[weapon]["mag"])
		reserve_by_weapon[weapon] = int(weapon_profiles[weapon]["reserve"])
	_apply_weapon_profile()


func _handle_weapon_inputs() -> void:
	if Input.is_action_just_pressed("weapon_1"):
		_switch_by_slot(0)
	elif Input.is_action_just_pressed("weapon_2"):
		_switch_by_slot(1)
	elif Input.is_action_just_pressed("weapon_3"):
		_switch_by_slot(2)
	elif Input.is_action_just_pressed("weapon_4"):
		_switch_by_slot(3)


func _switch_by_slot(slot: int) -> void:
	if slot >= 0 and slot < unlocked_weapons.size():
		switch_weapon(unlocked_weapons[slot])


func _apply_weapon_profile() -> void:
	var profile: Dictionary = weapon_profiles[current_weapon]
	magazine_size = int(profile["mag"])
	max_reserve_ammo = int(profile["reserve"])
	fire_rate = float(profile["fire_rate"])
	reload_time = float(profile["reload"])
	ammo = int(ammo_by_weapon[current_weapon])
	reserve_ammo = int(reserve_by_weapon[current_weapon])


func _store_current_weapon_ammo() -> void:
	ammo_by_weapon[current_weapon] = ammo
	reserve_by_weapon[current_weapon] = reserve_ammo


func _spread_direction(spread: float) -> Vector3:
	var base := -camera.global_transform.basis.z.normalized()
	if spread <= 0.0:
		return base
	var x := camera.global_transform.basis.x * randf_range(-spread, spread)
	var y := camera.global_transform.basis.y * randf_range(-spread, spread)
	return (base + x + y).normalized()


func _weapon_label(weapon: String) -> String:
	return str(weapon_profiles[weapon]["label"])


func _is_locally_controlled() -> bool:
	return not multiplayer.has_multiplayer_peer() or is_multiplayer_authority()


func _update_network_control() -> void:
	var controlled := _is_locally_controlled()
	camera.current = controlled
	set_process_unhandled_input(controlled)
	if not controlled:
		global_position = global_position.lerp(remote_target_position, 0.35)
		rotation = rotation.lerp(remote_target_rotation, 0.35)


func _send_network_transform(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not is_multiplayer_authority():
		return
	network_send_timer -= delta
	if network_send_timer > 0.0:
		return
	network_send_timer = 0.05
	sync_remote_transform.rpc(global_position, rotation)


@rpc("any_peer", "call_remote", "unreliable")
func sync_remote_transform(pos: Vector3, rot: Vector3) -> void:
	if is_multiplayer_authority():
		return
	remote_target_position = pos
	remote_target_rotation = rot


func _sync_health_state() -> void:
	if multiplayer.has_multiplayer_peer() and is_multiplayer_authority():
		sync_remote_health.rpc(health, dead)


func _send_respawn_state() -> void:
	if multiplayer.has_multiplayer_peer() and is_multiplayer_authority():
		sync_remote_respawn.rpc(global_position, health)


@rpc("any_peer", "call_remote", "reliable")
func sync_remote_health(new_health: int, is_dead: bool) -> void:
	if is_multiplayer_authority():
		return
	health = new_health
	dead = is_dead
	if dead:
		velocity = Vector3.ZERO
		if has_node("Body"):
			var body := $Body as MeshInstance3D
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.22, 0.02, 0.02)
			mat.emission_enabled = true
			mat.emission = Color(0.35, 0.0, 0.0)
			mat.emission_energy_multiplier = 0.5
			body.material_override = mat


@rpc("any_peer", "call_remote", "reliable")
func sync_remote_respawn(spawn_position: Vector3, new_health: int) -> void:
	if is_multiplayer_authority():
		return
	dead = false
	health = new_health
	global_position = spawn_position
	remote_target_position = spawn_position
	velocity = Vector3.ZERO
	_apply_player_material()
