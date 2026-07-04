extends CharacterBody3D
class_name EnemyAgent

signal died

@export var bullet_scene: PackedScene = preload("res://scenes/Bullet.tscn")
@export var max_health := 3
@export var move_speed := 4.1
@export var fire_interval := 1.6
@export var bullet_speed := 12.0
@export var variant := "grunt"
@export var contact_damage := 1

var health := max_health
var fire_cooldown := 0.0
var stun_time := 0.0
var strafe_phase := 0.0
var burst_shots := 1
var preferred_range := 5.5
var retreat_range := 3.0
var shoot_range := 24.0
var contact_cooldown := 0.0
var network_id := -1
var sync_timer := 0.0
var remote_target_position := Vector3.ZERO
var remote_target_rotation := Vector3.ZERO

@onready var muzzle: Marker3D = $Muzzle
@onready var body_mesh: MeshInstance3D = $MeshInstance3D

func _ready() -> void:
	health = max_health
	strafe_phase = randf() * TAU
	remote_target_position = global_position
	remote_target_rotation = rotation
	_apply_variant_material()


func _physics_process(delta: float) -> void:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("is_game_active") and not game.is_game_active():
		velocity = Vector3.ZERO
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		global_position = global_position.lerp(remote_target_position, 0.32)
		rotation = rotation.lerp(remote_target_rotation, 0.32)
		return

	var player := _nearest_live_player()
	if not player:
		return

	var scale := _time_factor()
	var scaled_delta := delta * scale
	stun_time = maxf(stun_time - scaled_delta, 0.0)
	fire_cooldown = maxf(fire_cooldown - scaled_delta, 0.0)
	contact_cooldown = maxf(contact_cooldown - scaled_delta, 0.0)

	var to_player := player.global_position - global_position
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	var distance := maxf(flat.length(), 0.001)
	var forward := flat.normalized()
	var side := Vector3(-forward.z, 0.0, forward.x)
	var desired := Vector3.ZERO

	if stun_time <= 0.0:
		if distance > preferred_range:
			desired += forward
		elif distance < retreat_range:
			desired -= forward
		desired += side * sin(Time.get_ticks_msec() * 0.002 + strafe_phase) * 0.55

	velocity.x = desired.normalized().x * move_speed * scale if desired.length() > 0.01 else 0.0
	velocity.z = desired.normalized().z * move_speed * scale if desired.length() > 0.01 else 0.0
	if not is_on_floor():
		velocity.y -= 24.0 * delta
	else:
		velocity.y = 0.0
	move_and_slide()

	if flat.length() > 0.1:
		look_at(Vector3(player.global_position.x, global_position.y, player.global_position.z), Vector3.UP)

	if distance < 1.25 and contact_cooldown <= 0.0 and player.has_method("take_damage"):
		player.take_damage(contact_damage, global_position)
		contact_cooldown = 1.0

	if fire_cooldown <= 0.0 and distance < shoot_range and _has_line_of_sight(player):
		_fire_at(player)
		fire_cooldown = fire_interval + randf_range(-0.25, 0.35)

	_sync_network_state(delta)


func configure(enemy_variant: String, difficulty: float) -> void:
	variant = enemy_variant
	match variant:
		"runner":
			max_health = 1 + int(difficulty * 0.25)
			move_speed = 6.6 + difficulty * 0.12
			fire_interval = 2.2
			bullet_speed = 10.0
			preferred_range = 1.7
			retreat_range = 0.0
			shoot_range = 10.0
			contact_damage = 1
		"bruiser":
			max_health = 5 + int(difficulty * 0.7)
			move_speed = 2.7 + difficulty * 0.08
			fire_interval = 1.95
			bullet_speed = 10.5
			preferred_range = 4.2
			retreat_range = 1.4
			burst_shots = 2
		"sniper":
			max_health = 2 + int(difficulty * 0.35)
			move_speed = 2.5 + difficulty * 0.04
			fire_interval = maxf(0.95, 2.15 - difficulty * 0.05)
			bullet_speed = 18.0 + difficulty * 0.25
			preferred_range = 14.0
			retreat_range = 8.5
			shoot_range = 34.0
		_:
			max_health = 2 + int(difficulty * 0.45)
			move_speed = 4.0 + difficulty * 0.12
			fire_interval = maxf(0.85, 1.65 - difficulty * 0.045)
			bullet_speed = 12.0 + difficulty * 0.18
			preferred_range = 5.5
			retreat_range = 3.0
			shoot_range = 24.0
	health = max_health


func set_network_id(id: int) -> void:
	network_id = id


func take_damage(amount: int, hit_position: Vector3) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	health -= amount
	stun_time = 0.25
	_flash_hit()
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("spawn_impact"):
		game.spawn_impact(hit_position, Color(1, 0.12, 0.08))
	if health <= 0:
		if game and game.has_method("spawn_death_burst"):
			game.spawn_death_burst(global_position)
		if game and game.has_method("remove_enemy_network") and network_id >= 0:
			game.remove_enemy_network(network_id)
		died.emit()
		queue_free()


func _fire_at(player: Node3D) -> void:
	var aim_point := player.global_position + Vector3(0, 0.35, 0)
	for shot in range(burst_shots):
		var spread := Vector3(randf_range(-0.045, 0.045), randf_range(-0.02, 0.04), randf_range(-0.045, 0.045))
		var direction := (aim_point - muzzle.global_position).normalized() + spread
		var tint := Color(1, 0.08, 0.04)
		if variant == "sniper":
			tint = Color(1, 0.82, 0.12)
		elif variant == "bruiser":
			tint = Color(1, 0.22, 0.04)
		var game := get_tree().get_first_node_in_group("game")
		if game and game.has_method("request_enemy_bullet"):
			game.request_enemy_bullet(muzzle.global_position, direction.normalized(), bullet_speed, 1, tint)
		else:
			var bullet = bullet_scene.instantiate()
			get_tree().current_scene.add_child(bullet)
			bullet.setup(muzzle.global_position, direction.normalized(), bullet_speed, 1, "enemy", tint)


func _has_line_of_sight(player: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.5, player.global_position + Vector3.UP * 0.45)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty() or hit.get("collider") == player


func _time_factor() -> float:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("get_time_factor"):
		return game.get_time_factor()
	return 1.0


func _flash_hit() -> void:
	var original := body_mesh.material_override
	var flash := StandardMaterial3D.new()
	flash.albedo_color = Color.WHITE
	flash.emission_enabled = true
	flash.emission = Color.WHITE
	flash.emission_energy_multiplier = 2.5
	body_mesh.material_override = flash
	await get_tree().create_timer(0.08).timeout
	if is_instance_valid(body_mesh):
		body_mesh.material_override = original


func _apply_variant_material() -> void:
	var mat := StandardMaterial3D.new()
	match variant:
		"runner":
			mat.albedo_color = Color(1.0, 0.18, 0.08)
			mat.emission = Color(1.0, 0.02, 0.0)
		"bruiser":
			mat.albedo_color = Color(0.85, 0.05, 1.0)
			mat.emission = Color(0.5, 0.0, 0.8)
		"sniper":
			mat.albedo_color = Color(1.0, 0.75, 0.08)
			mat.emission = Color(1.0, 0.45, 0.0)
		_:
			mat.albedo_color = Color(1, 0.09, 0.06, 1)
			mat.emission = Color(1, 0.03, 0.01)
	mat.emission_enabled = true
	mat.emission_energy_multiplier = 0.9
	body_mesh.material_override = mat


func _nearest_live_player() -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for candidate in get_tree().get_nodes_in_group("player"):
		if not candidate is Node3D:
			continue
		if candidate.get("dead") == true:
			continue
		var distance := global_position.distance_to(candidate.global_position)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


func apply_remote_state(pos: Vector3, rot: Vector3, new_health: int) -> void:
	remote_target_position = pos
	remote_target_rotation = rot
	health = new_health


func _sync_network_state(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server() or network_id < 0:
		return
	sync_timer -= delta
	if sync_timer > 0.0:
		return
	sync_timer = 0.08
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("sync_enemy_network"):
		game.sync_enemy_network(network_id, global_position, rotation, health)
