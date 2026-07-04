extends Node3D

@export var enemy_scene: PackedScene = preload("res://scenes/Enemy.tscn")
@export var pickup_scene: PackedScene = preload("res://scenes/Pickup.tscn")
@export var player_scene: PackedScene = preload("res://scenes/Player.tscn")

var time_factor := 0.16
var target_time_factor := 0.16
var wave := 0
var kills := 0
var enemies_alive := 0
var game_over := false
var slow_charge := 1.0
var combo := 0
var combo_timer := 0.0
var damage_flash := 0.0
var burst_cooldown := 0.0
var game_started := false
var paused_for_menu := true
var pickup_text_timer := 0.0
var difficulty_scale := 1.0
var screen_flash_enabled := true
var network_mode := "single"
var lobby_status := "Offline"
var network_port := 24570
var discovery_port := 24571
var max_players := 6
var spawned_peer_ids := []
var next_enemy_network_id := 1
var lobby_code := ""
var desired_join_code := ""
var discovery_timer := 0.0
var discovery_broadcaster: PacketPeerUDP
var discovery_listener: PacketPeerUDP

@onready var player = $Player

var hud_layer: CanvasLayer
var status_label: Label
var health_label: Label
var wave_label: Label
var combo_label: Label
var ammo_label: Label
var weapon_label: Label
var ability_label: Label
var pickup_label: Label
var wave_banner_label: Label
var crosshair: Control
var slow_bar: ColorRect
var flash_rect: ColorRect
var menu_layer: CanvasLayer
var menu_root: Control
var menu_title: Label
var start_button: Button
var sensitivity_slider: HSlider
var difficulty_button: OptionButton
var flash_toggle: CheckButton
var lobby_label: Label
var port_spin: SpinBox
var code_edit: LineEdit
var host_button: Button
var join_code_button: Button
var disconnect_button: Button
var resolved_host_ip := ""
var death_layer: CanvasLayer
var death_root: Control
var death_title: Label
var death_info: Label
var respawn_button: Button

func _ready() -> void:
	add_to_group("game")
	randomize()
	_build_world()
	_build_hud()
	_build_menu()
	_build_death_screen()
	_connect_network_signals()
	player.health_changed.connect(_on_player_health_changed)
	player.shot_fired.connect(_on_player_shot)
	player.damaged.connect(_on_player_damaged)
	player.ammo_changed.connect(_on_player_ammo_changed)
	player.reload_state_changed.connect(_on_reload_state_changed)
	player.ability_changed.connect(_on_ability_changed)
	player.weapon_changed.connect(_on_weapon_changed)
	_on_player_health_changed(player.health, player.max_health)
	_on_player_ammo_changed(player.ammo, player.magazine_size, player.reserve_ammo)
	_on_ability_changed(0.0, true)
	_on_weapon_changed("PISTOL", ["pistol"])
	_show_menu("TIMEBREAK ARENA", "PLAY")


func _process(delta: float) -> void:
	_update_lobby_discovery(delta)
	if Input.is_action_just_pressed("reset_game"):
		get_tree().reload_current_scene()
		return

	if Input.is_action_just_pressed("pause_toggle") and game_started and not game_over:
		if paused_for_menu:
			_resume_game()
		else:
			_show_menu("PAUSED", "RESUME")
		return

	if paused_for_menu or not game_started:
		return

	if _is_death_screen_visible():
		_update_hud()
		return

	if game_over:
		return

	burst_cooldown = maxf(burst_cooldown - delta, 0.0)
	pickup_text_timer = maxf(pickup_text_timer - delta, 0.0)
	combo_timer = maxf(combo_timer - delta, 0.0)
	if combo_timer <= 0.0:
		combo = 0

	if Input.is_action_just_pressed("time_burst"):
		_try_time_burst()

	var player_motion = player.get_motion_strength() if player.has_method("get_motion_strength") else 0.0
	var manual_slow := Input.is_action_pressed("slow_time") and slow_charge > 0.02
	if manual_slow:
		slow_charge = maxf(slow_charge - delta * 0.22, 0.0)
	else:
		slow_charge = minf(slow_charge + delta * 0.08, 1.0)

	target_time_factor = 0.07 if manual_slow else lerpf(0.16, 1.0, player_motion)
	time_factor = lerpf(time_factor, target_time_factor, delta * 8.0)
	damage_flash = maxf(damage_flash - delta * 2.5, 0.0)
	_update_hud()

	if enemies_alive <= 0:
		if _is_wave_authority():
			_spawn_wave()


func get_time_factor() -> float:
	return time_factor


func is_game_active() -> bool:
	return game_started and not paused_for_menu and not game_over


func is_player_control_enabled() -> bool:
	return is_game_active() and not _is_death_screen_visible()


func _spawn_wave() -> void:
	if not _is_wave_authority():
		return
	wave += 1
	var difficulty := float(wave) * difficulty_scale
	var count := 2 + int(ceil(wave * 0.85 * difficulty_scale))
	enemies_alive = count
	if multiplayer.has_multiplayer_peer():
		sync_wave_state_network.rpc(wave, enemies_alive)
	_show_wave_banner("WAVE %d" % wave)
	for i in range(count):
		var variant := _pick_enemy_variant()
		var spawn_pos := _spawn_position(i, count)
		if multiplayer.has_multiplayer_peer():
			var enemy_id := next_enemy_network_id
			next_enemy_network_id += 1
			spawn_enemy_network.rpc(enemy_id, variant, difficulty, spawn_pos)
		else:
			_spawn_enemy_instance(-1, variant, difficulty, spawn_pos)
	if wave == 1:
		show_pickup_text("SURVIVE")
	else:
		_spawn_wave_pickups()
	_update_hud()


func _on_enemy_died() -> void:
	if not _is_wave_authority():
		return
	enemies_alive -= 1
	if multiplayer.has_multiplayer_peer():
		sync_wave_state_network.rpc(wave, enemies_alive)
	kills += 1
	combo += 1
	combo_timer = 2.4
	slow_charge = minf(slow_charge + 0.24, 1.0)
	if randf() < 0.18:
		_spawn_pickup(_random_pickup_kind(), _random_pickup_position())
	_update_hud()


func _on_player_health_changed(health: int, max_health: int) -> void:
	health_label.text = "HEALTH %d/%d" % [health, max_health]
	if health <= 0:
		status_label.text = "YOU SHATTERED"
		_show_death_screen()


func _on_player_shot() -> void:
	time_factor = maxf(time_factor, 0.35)


func _on_player_damaged() -> void:
	damage_flash = 1.0


func _on_player_ammo_changed(ammo: int, magazine_size: int, reserve_ammo: int) -> void:
	ammo_label.text = "AMMO %d/%d   RESERVE %d" % [ammo, magazine_size, reserve_ammo]


func _on_weapon_changed(weapon_name: String, unlocked_weapons: Array) -> void:
	var slots := []
	for i in range(unlocked_weapons.size()):
		slots.append("%d:%s" % [i + 1, str(unlocked_weapons[i]).to_upper()])
	weapon_label.text = "WEAPON %s   %s" % [weapon_name, "  ".join(slots)]


func _on_reload_state_changed(is_reloading: bool) -> void:
	if is_reloading:
		status_label.text = "RELOADING"


func _on_ability_changed(dash_cooldown_value: float, dash_ready: bool) -> void:
	var dash_text := "DASH READY" if dash_ready else "DASH %.1f" % dash_cooldown_value
	ability_label.text = "%s   BURST %.0f%%" % [dash_text, slow_charge * 100.0]


func show_pickup_text(text: String) -> void:
	pickup_label.text = text
	pickup_text_timer = 1.5


func open_weapon_crate(target_player: Node) -> void:
	if not target_player.has_method("locked_weapons"):
		show_pickup_text("CRATE EMPTY")
		return
	var locked: Array = target_player.locked_weapons()
	if locked.is_empty():
		target_player.add_ammo(24)
		show_pickup_text("CRATE: AMMO CACHE")
		return
	var weapon: String = locked.pick_random()
	if target_player.unlock_weapon(weapon):
		show_pickup_text("UNLOCKED %s" % weapon.to_upper())
	else:
		show_pickup_text("CRATE JAMMED")


func spawn_impact(position: Vector3, tint: Color) -> void:
	for i in range(5):
		var spark := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.055, 0.055, randf_range(0.18, 0.42))
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.emission_enabled = true
		mat.emission = tint
		mat.emission_energy_multiplier = 2.2
		mesh.material = mat
		spark.mesh = mesh
		spark.global_position = position + Vector3(randf_range(-0.08, 0.08), randf_range(-0.08, 0.08), randf_range(-0.08, 0.08))
		spark.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		add_child(spark)
		_fade_and_free(spark, randf_range(0.12, 0.24))


func spawn_death_burst(position: Vector3) -> void:
	for i in range(18):
		var shard := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(randf_range(0.08, 0.18), randf_range(0.08, 0.18), randf_range(0.28, 0.62))
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, randf_range(0.05, 0.22), randf_range(0.02, 0.08))
		mat.emission_enabled = true
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 1.7
		mesh.material = mat
		shard.mesh = mesh
		shard.global_position = position + Vector3(randf_range(-0.35, 0.35), randf_range(0.0, 1.0), randf_range(-0.35, 0.35))
		shard.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		add_child(shard)
		_launch_shard(shard, Vector3(randf_range(-5, 5), randf_range(3, 8), randf_range(-5, 5)), randf_range(0.45, 0.9))


func _try_time_burst() -> void:
	if slow_charge < 0.35 or burst_cooldown > 0.0:
		return

	slow_charge -= 0.35
	burst_cooldown = 1.2
	time_factor = 0.04
	var origin: Vector3 = player.global_position
	_spawn_pulse(origin)

	for enemy in get_tree().get_nodes_in_group("enemy"):
		if enemy is Node3D and enemy.global_position.distance_to(origin) <= 7.0:
			enemy.take_damage(1, enemy.global_position + Vector3.UP * 0.5)

	for projectile in get_tree().get_nodes_in_group("projectile"):
		if projectile is Node3D and projectile.global_position.distance_to(origin) <= 9.0 and projectile.get("team") == "enemy":
			spawn_impact(projectile.global_position, Color(0.1, 0.9, 1.0))
			projectile.queue_free()


func request_player_bullet(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color, shooter_peer_id: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		_spawn_player_bullet_instance(start_position, direction, speed, bullet_damage, tint, shooter_peer_id)
		return
	if multiplayer.is_server():
		spawn_player_bullet_network.rpc(start_position, direction, speed, bullet_damage, tint, shooter_peer_id)
	else:
		request_player_bullet_server.rpc_id(1, start_position, direction, speed, bullet_damage, tint, shooter_peer_id)


@rpc("any_peer", "call_remote", "reliable")
func request_player_bullet_server(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color, shooter_peer_id: int) -> void:
	if multiplayer.is_server():
		spawn_player_bullet_network.rpc(start_position, direction, speed, bullet_damage, tint, shooter_peer_id)


@rpc("authority", "call_local", "reliable")
func spawn_player_bullet_network(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color, shooter_peer_id: int) -> void:
	_spawn_player_bullet_instance(start_position, direction, speed, bullet_damage, tint, shooter_peer_id)


func _spawn_player_bullet_instance(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color, shooter_peer_id: int) -> void:
	var bullet = preload("res://scenes/Bullet.tscn").instantiate()
	add_child(bullet)
	bullet.setup_network(start_position, direction, speed, bullet_damage, "player", tint, shooter_peer_id)


func request_enemy_bullet(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		spawn_enemy_bullet_network.rpc(start_position, direction, speed, bullet_damage, tint)
	else:
		_spawn_enemy_bullet_instance(start_position, direction, speed, bullet_damage, tint)


@rpc("authority", "call_local", "reliable")
func spawn_enemy_bullet_network(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color) -> void:
	_spawn_enemy_bullet_instance(start_position, direction, speed, bullet_damage, tint)


func _spawn_enemy_bullet_instance(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, tint: Color) -> void:
	var bullet = preload("res://scenes/Bullet.tscn").instantiate()
	add_child(bullet)
	bullet.setup(start_position, direction, speed, bullet_damage, "enemy", tint)


func _pick_enemy_variant() -> String:
	if wave <= 1:
		return "grunt"
	var roll := randf()
	if wave >= 5 and roll > 0.78:
		return "bruiser"
	if wave >= 4 and roll > 0.58:
		return "sniper"
	if wave >= 2 and roll > 0.32:
		return "runner"
	return "grunt"


func _spawn_wave_pickups() -> void:
	_spawn_pickup("ammo", _random_pickup_position())
	if wave % 2 == 0:
		_spawn_pickup("health", _random_pickup_position())
	if wave >= 3:
		_spawn_pickup(_random_power_kind(), _random_pickup_position())
	if wave == 2 or wave % 3 == 0:
		_spawn_pickup("weapon_crate", _random_pickup_position())


func _spawn_pickup(kind: String, position: Vector3) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		spawn_pickup_network.rpc(kind, position)
		return
	_spawn_pickup_instance(kind, position)


func _spawn_pickup_instance(kind: String, position: Vector3) -> void:
	var pickup = pickup_scene.instantiate()
	match kind:
		"ammo":
			pickup.setup("ammo", 18.0, "+AMMO")
		"health":
			pickup.setup("health", 2.0, "+HEALTH")
		"overcharge":
			pickup.setup("overcharge", 7.0, "OVERCHARGE")
		"damage_boost":
			pickup.setup("damage_boost", 8.0, "DAMAGE BOOST")
		"infinite_ammo":
			pickup.setup("infinite_ammo", 6.0, "BOTTOMLESS")
		"dash":
			pickup.setup("dash", 0.0, "DASH RESET")
		"speed_boost":
			pickup.setup("speed_boost", 8.0, "SPEED BOOST")
		"shield":
			pickup.setup("shield", 7.0, "SHIELD")
		"weapon_crate":
			pickup.setup("weapon_crate", 0.0, "WEAPON CRATE")
	add_child(pickup)
	pickup.global_position = position


@rpc("authority", "call_local", "reliable")
func spawn_enemy_network(enemy_id: int, variant: String, difficulty: float, spawn_pos: Vector3) -> void:
	_spawn_enemy_instance(enemy_id, variant, difficulty, spawn_pos)


func _spawn_enemy_instance(enemy_id: int, variant: String, difficulty: float, spawn_pos: Vector3) -> void:
	var enemy = enemy_scene.instantiate()
	enemy.configure(variant, difficulty)
	enemy.set_network_id(enemy_id)
	if _is_wave_authority():
		enemy.died.connect(_on_enemy_died)
	add_child(enemy)
	enemy.global_position = spawn_pos


@rpc("authority", "call_local", "reliable")
func spawn_pickup_network(kind: String, position: Vector3) -> void:
	_spawn_pickup_instance(kind, position)


@rpc("authority", "call_remote", "reliable")
func sync_wave_state_network(new_wave: int, new_enemies_alive: int) -> void:
	var changed_wave := new_wave != wave
	wave = new_wave
	enemies_alive = new_enemies_alive
	if changed_wave:
		_show_wave_banner("WAVE %d" % wave)
	_update_hud()


func request_enemy_damage(enemy_id: int, amount: int, hit_position: Vector3) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		_apply_enemy_damage(enemy_id, amount, hit_position)
	else:
		request_enemy_damage_server.rpc_id(1, enemy_id, amount, hit_position)


@rpc("any_peer", "call_remote", "reliable")
func request_enemy_damage_server(enemy_id: int, amount: int, hit_position: Vector3) -> void:
	if multiplayer.is_server():
		_apply_enemy_damage(enemy_id, amount, hit_position)


func _apply_enemy_damage(enemy_id: int, amount: int, hit_position: Vector3) -> void:
	var enemy := _find_enemy_by_id(enemy_id)
	if enemy and enemy.has_method("take_damage"):
		enemy.take_damage(amount, hit_position)


func sync_enemy_network(enemy_id: int, pos: Vector3, rot: Vector3, health: int) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		sync_enemy_state_network.rpc(enemy_id, pos, rot, health)


@rpc("authority", "call_remote", "unreliable")
func sync_enemy_state_network(enemy_id: int, pos: Vector3, rot: Vector3, health: int) -> void:
	var enemy := _find_enemy_by_id(enemy_id)
	if enemy and enemy.has_method("apply_remote_state"):
		enemy.apply_remote_state(pos, rot, health)


func remove_enemy_network(enemy_id: int) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		remove_enemy_network_rpc.rpc(enemy_id)


@rpc("authority", "call_remote", "reliable")
func remove_enemy_network_rpc(enemy_id: int) -> void:
	var enemy := _find_enemy_by_id(enemy_id)
	if enemy:
		spawn_death_burst(enemy.global_position)
		enemy.queue_free()


func _find_enemy_by_id(enemy_id: int) -> Node:
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if enemy.get("network_id") == enemy_id:
			return enemy
	return null


func _random_pickup_kind() -> String:
	var options := ["ammo", "health", "overcharge", "damage_boost", "infinite_ammo", "dash", "speed_boost", "shield", "weapon_crate"]
	return options.pick_random()


func _random_power_kind() -> String:
	var options := ["overcharge", "damage_boost", "infinite_ammo", "dash", "speed_boost", "shield"]
	return options.pick_random()


func _random_pickup_position() -> Vector3:
	return Vector3(randf_range(-17.0, 17.0), 0.75, randf_range(-17.0, 17.0))


func _spawn_pulse(position: Vector3) -> void:
	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.96
	mesh.outer_radius = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.85, 1.0, 0.48)
	mat.emission_enabled = true
	mat.emission = Color(0.0, 0.75, 1.0)
	mat.emission_energy_multiplier = 2.4
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	ring.mesh = mesh
	ring.global_position = Vector3(position.x, 0.18, position.z)
	ring.rotation_degrees.x = 90.0
	add_child(ring)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(ring, "scale", Vector3(7.0, 7.0, 7.0), 0.34).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color", Color(0.0, 0.85, 1.0, 0.0), 0.34)
	tween.set_parallel(false)
	tween.tween_callback(Callable(ring, "queue_free"))


func _fade_and_free(node: Node3D, lifetime: float) -> void:
	var tween := create_tween()
	tween.tween_property(node, "scale", Vector3.ZERO, lifetime).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(Callable(node, "queue_free"))


func _launch_shard(node: Node3D, velocity: Vector3, lifetime: float) -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(node, "position", node.position + velocity, lifetime).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "rotation", node.rotation + Vector3(randf() * TAU, randf() * TAU, randf() * TAU), lifetime)
	tween.set_parallel(false)
	tween.tween_property(node, "scale", Vector3.ZERO, 0.15)
	tween.tween_callback(Callable(node, "queue_free"))


func _spawn_position(index: int, count: int) -> Vector3:
	var angle := TAU * float(index) / float(count) + randf_range(-0.28, 0.28)
	var radius := randf_range(11.0, 18.0)
	return Vector3(cos(angle) * radius, 1.1, sin(angle) * radius)


func _build_world() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.018, 0.022)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.22, 0.28, 0.32)
	env.ambient_light_energy = 0.55
	env.glow_enabled = true
	env.glow_intensity = 0.55
	environment.environment = env
	add_child(environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.6
	add_child(sun)

	_add_floor()
	_add_arena_walls()
	_add_city_blocks()
	_add_cover()
	_add_accent_lights()


func _add_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	add_child(floor_body)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(46, 1, 46)
	collision.shape = shape
	collision.position.y = -0.55
	floor_body.add_child(collision)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(46, 0.18, 46)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.095, 0.105)
	mat.roughness = 0.65
	mat.metallic = 0.05
	box.material = mat
	mesh.mesh = box
	mesh.position.y = -0.12
	floor_body.add_child(mesh)

	for x in range(-22, 23, 4):
		_add_grid_line(Vector3(x, 0.01, 0), Vector3(0.035, 0.02, 46))
	for z in range(-22, 23, 4):
		_add_grid_line(Vector3(0, 0.015, z), Vector3(46, 0.02, 0.035))


func _add_grid_line(position: Vector3, size: Vector3) -> void:
	var line := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.55, 0.72, 1)
	mat.emission_enabled = true
	mat.emission = Color(0.0, 0.26, 0.34, 1)
	mat.emission_energy_multiplier = 0.7
	mesh.material = mat
	line.mesh = mesh
	line.position = position
	add_child(line)


func _add_arena_walls() -> void:
	_add_block(Vector3(0, 2.0, -23), Vector3(46, 4, 0.7), Color(0.12, 0.14, 0.16))
	_add_block(Vector3(0, 2.0, 23), Vector3(46, 4, 0.7), Color(0.12, 0.14, 0.16))
	_add_block(Vector3(-23, 2.0, 0), Vector3(0.7, 4, 46), Color(0.12, 0.14, 0.16))
	_add_block(Vector3(23, 2.0, 0), Vector3(0.7, 4, 46), Color(0.12, 0.14, 0.16))


func _add_cover() -> void:
	var cover_data := [
		[Vector3(-7, 1.2, -4), Vector3(2.0, 2.4, 5.2)],
		[Vector3(8, 0.9, 5), Vector3(5.4, 1.8, 1.7)],
		[Vector3(3, 1.7, -10), Vector3(2.2, 3.4, 2.2)],
		[Vector3(-12, 1.1, 8), Vector3(2.8, 2.2, 2.8)],
		[Vector3(13, 1.4, -7), Vector3(1.8, 2.8, 4.4)],
		[Vector3(-2, 0.75, 11), Vector3(7.0, 1.5, 1.2)],
		[Vector3(15, 0.7, 11), Vector3(1.4, 1.4, 5.8)],
		[Vector3(-16, 0.7, -10), Vector3(5.8, 1.4, 1.4)],
		[Vector3(0, 2.3, -17), Vector3(8.0, 0.8, 1.4)],
		[Vector3(0, 0.35, -14), Vector3(3.0, 0.7, 3.0)]
	]
	for item in cover_data:
		_add_block(item[0], item[1], Color(0.17, 0.19, 0.2))

	for i in range(10):
		var pos := Vector3(randf_range(-18, 18), 0.45, randf_range(-18, 18))
		_add_block(pos, Vector3(randf_range(0.8, 1.6), randf_range(0.7, 1.4), randf_range(0.8, 1.6)), Color(0.11, 0.13, 0.145))


func _add_city_blocks() -> void:
	var buildings := [
		[Vector3(-18, 4.0, -18), Vector3(5.5, 8.0, 5.5), Color(0.09, 0.105, 0.12)],
		[Vector3(-8, 6.0, -21), Vector3(6.5, 12.0, 3.5), Color(0.12, 0.12, 0.13)],
		[Vector3(9, 5.0, -20), Vector3(5.0, 10.0, 4.0), Color(0.08, 0.095, 0.11)],
		[Vector3(18, 7.0, -15), Vector3(4.0, 14.0, 7.0), Color(0.11, 0.12, 0.135)],
		[Vector3(-20, 5.5, 2), Vector3(3.8, 11.0, 7.5), Color(0.10, 0.115, 0.125)],
		[Vector3(20, 4.5, 5), Vector3(4.2, 9.0, 8.0), Color(0.075, 0.09, 0.105)],
		[Vector3(-15, 6.5, 20), Vector3(7.0, 13.0, 4.5), Color(0.12, 0.11, 0.12)],
		[Vector3(5, 5.0, 20), Vector3(9.0, 10.0, 4.0), Color(0.09, 0.10, 0.11)],
		[Vector3(18, 7.5, 18), Vector3(5.0, 15.0, 5.0), Color(0.11, 0.10, 0.12)]
	]
	for data in buildings:
		_add_building(data[0], data[1], data[2])

	_add_neon_sign(Vector3(-11, 3.5, -19.1), Vector3(2.8, 0.55, 0.08), Color(0.0, 0.95, 1.0))
	_add_neon_sign(Vector3(18.1, 4.2, -10), Vector3(0.08, 0.6, 3.0), Color(1.0, 0.15, 0.35))
	_add_neon_sign(Vector3(7, 3.0, 18.1), Vector3(3.2, 0.5, 0.08), Color(1.0, 0.82, 0.1))


func _add_building(position: Vector3, size: Vector3, color: Color) -> void:
	_add_block(position, size, color)
	var front_z := position.z - size.z * 0.5 - 0.02
	var back_z := position.z + size.z * 0.5 + 0.02
	var left_x := position.x - size.x * 0.5 - 0.02
	var right_x := position.x + size.x * 0.5 + 0.02
	for floor_index in range(1, int(size.y / 1.5)):
		var y := position.y - size.y * 0.5 + floor_index * 1.35
		for col in range(-1, 2):
			var x: float = position.x + float(col) * minf(1.35, size.x * 0.24)
			_add_window(Vector3(x, y, front_z), Vector3(0.65, 0.42, 0.035))
			_add_window(Vector3(x, y, back_z), Vector3(0.65, 0.42, 0.035))
		for col in range(-1, 2):
			var z: float = position.z + float(col) * minf(1.35, size.z * 0.24)
			_add_window(Vector3(left_x, y, z), Vector3(0.035, 0.42, 0.65))
			_add_window(Vector3(right_x, y, z), Vector3(0.035, 0.42, 0.65))


func _add_window(position: Vector3, size: Vector3) -> void:
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	var lit := randf() > 0.35
	mat.albedo_color = Color(0.02, 0.08, 0.11) if not lit else Color(0.2, 0.75, 1.0)
	mat.emission_enabled = lit
	mat.emission = Color(0.05, 0.55, 0.95) if lit else Color.BLACK
	mat.emission_energy_multiplier = 0.8 if lit else 0.0
	mesh.material = mat
	mesh_instance.mesh = mesh
	mesh_instance.position = position
	add_child(mesh_instance)


func _add_neon_sign(position: Vector3, size: Vector3, color: Color) -> void:
	var sign := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.8
	mesh.material = mat
	sign.mesh = mesh
	sign.position = position
	add_child(sign)


func _add_block(position: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = position
	add_child(body)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.5
	mesh.material = mat
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)


func _add_accent_lights() -> void:
	for pos in [Vector3(-17, 3.2, -17), Vector3(17, 3.2, -17), Vector3(-17, 3.2, 17), Vector3(17, 3.2, 17)]:
		var light := OmniLight3D.new()
		light.position = pos
		light.light_color = Color(0.0, 0.72, 1.0)
		light.light_energy = 1.0
		light.omni_range = 12.0
		add_child(light)


func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)

	health_label = _make_label(Vector2(24, 20), 22)
	wave_label = _make_label(Vector2(24, 52), 18)
	ammo_label = _make_label(Vector2(24, 104), 18)
	weapon_label = _make_label(Vector2(24, 128), 16)
	ability_label = _make_label(Vector2(24, 152), 16)
	combo_label = _make_label(Vector2(24, 178), 18)
	pickup_label = _make_label(Vector2(0, 148), 22)
	pickup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pickup_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	wave_banner_label = _make_label(Vector2(0, 245), 54)
	wave_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wave_banner_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	status_label = _make_label(Vector2(0, 92), 28)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	status_label.text = ""

	crosshair = Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.offset_left = -12
	crosshair.offset_top = -12
	crosshair.offset_right = 12
	crosshair.offset_bottom = 12
	hud_layer.add_child(crosshair)
	crosshair.draw.connect(_draw_crosshair)

	var bar_back := ColorRect.new()
	bar_back.position = Vector2(24, 86)
	bar_back.size = Vector2(220, 8)
	bar_back.color = Color(0.04, 0.06, 0.07, 0.9)
	hud_layer.add_child(bar_back)

	slow_bar = ColorRect.new()
	slow_bar.position = bar_back.position
	slow_bar.size = bar_back.size
	slow_bar.color = Color(0.0, 0.78, 1.0, 0.95)
	hud_layer.add_child(slow_bar)

	flash_rect = ColorRect.new()
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 0.02, 0.0, 0.0)
	hud_layer.add_child(flash_rect)


func _build_menu() -> void:
	menu_layer = CanvasLayer.new()
	menu_layer.layer = 10
	add_child(menu_layer)

	menu_root = Control.new()
	menu_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_layer.add_child(menu_root)

	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.0, 0.0, 0.0, 0.82)
	menu_root.add_child(shade)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -430
	panel.offset_top = -285
	panel.offset_right = 430
	panel.offset_bottom = 285
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.035, 0.045, 0.94), Color(0.0, 0.78, 1.0, 0.75), 2, 8))
	menu_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	menu_title = Label.new()
	menu_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_title.add_theme_font_size_override("font_size", 42)
	menu_title.modulate = Color(0.85, 1.0, 1.0)
	box.add_child(menu_title)

	var subtitle := Label.new()
	subtitle.text = "Neon wave survival with time-bending combat and code-only LAN lobbies"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(0.62, 0.76, 0.82)
	subtitle.add_theme_font_size_override("font_size", 15)
	box.add_child(subtitle)

	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(780, 390)
	tabs.add_theme_stylebox_override("panel", _panel_style(Color(0.01, 0.015, 0.02, 0.42), Color(0.13, 0.22, 0.26, 0.65), 1, 6))
	tabs.add_theme_color_override("font_selected_color", Color(0.82, 1.0, 1.0))
	tabs.add_theme_color_override("font_unselected_color", Color(0.55, 0.68, 0.72))
	box.add_child(tabs)

	var play_tab := VBoxContainer.new()
	play_tab.name = "Play"
	play_tab.add_theme_constant_override("separation", 14)
	tabs.add_child(play_tab)

	start_button = Button.new()
	start_button.text = "PLAY"
	start_button.pressed.connect(_on_start_pressed)
	_style_primary_button(start_button)
	play_tab.add_child(start_button)

	var play_info := Label.new()
	play_info.text = "Drop into a neon city arena, bend time, loot crates, and survive escalating enemy waves."
	play_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	play_info.modulate = Color(0.84, 0.94, 0.96)
	play_info.add_theme_font_size_override("font_size", 18)
	play_tab.add_child(play_info)

	var weapon_info := Label.new()
	weapon_info.text = "Weapon crates unlock the shotgun, sniper, SMG, and railgun. Switch unlocked weapons with 1-4."
	weapon_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	weapon_info.modulate = Color(0.62, 0.76, 0.82)
	play_tab.add_child(weapon_info)

	var settings_tab := VBoxContainer.new()
	settings_tab.name = "Settings"
	settings_tab.add_theme_constant_override("separation", 11)
	tabs.add_child(settings_tab)

	var sens_label := Label.new()
	sens_label.text = "Mouse Sensitivity: affects first-person camera turn speed."
	sens_label.modulate = Color(0.84, 0.94, 0.96)
	settings_tab.add_child(sens_label)
	sensitivity_slider = HSlider.new()
	sensitivity_slider.min_value = 0.08
	sensitivity_slider.max_value = 0.5
	sensitivity_slider.step = 0.01
	sensitivity_slider.value = player.mouse_sensitivity * 100.0
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	settings_tab.add_child(sensitivity_slider)

	var difficulty_label := Label.new()
	difficulty_label.text = "Difficulty: changes enemy count, health, speed, and variant pressure."
	difficulty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	difficulty_label.modulate = Color(0.84, 0.94, 0.96)
	settings_tab.add_child(difficulty_label)
	difficulty_button = OptionButton.new()
	difficulty_button.add_item("Easy")
	difficulty_button.add_item("Normal")
	difficulty_button.add_item("Hard")
	difficulty_button.selected = 1
	difficulty_button.item_selected.connect(_on_difficulty_selected)
	settings_tab.add_child(difficulty_button)

	flash_toggle = CheckButton.new()
	flash_toggle.text = "Damage Flash: red screen flash when hit"
	flash_toggle.button_pressed = true
	flash_toggle.toggled.connect(_on_flash_toggled)
	flash_toggle.modulate = Color(0.84, 0.94, 0.96)
	settings_tab.add_child(flash_toggle)

	var settings_note := Label.new()
	settings_note.text = "Settings apply immediately. Difficulty affects newly spawned waves."
	settings_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	settings_note.modulate = Color(0.75, 0.86, 0.9)
	settings_tab.add_child(settings_note)

	var info_tab := VBoxContainer.new()
	info_tab.name = "Info"
	info_tab.add_theme_constant_override("separation", 11)
	tabs.add_child(info_tab)

	var controls := Label.new()
	controls.text = "Controls\nWASD move  Shift sprint  Space jump\nLMB shoot  RMB slow time  R reload\nQ dash  E time burst  1-4 switch weapons\nEsc pause  F5 restart"
	controls.modulate = Color(0.84, 0.94, 0.96)
	info_tab.add_child(controls)

	var powerups := Label.new()
	powerups.text = "Powerups\nAmmo, health, speed boost, shield, overcharge, damage boost, bottomless ammo, dash reset, weapon crates."
	powerups.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	powerups.modulate = Color(0.72, 0.86, 0.9)
	info_tab.add_child(powerups)

	var weapons := Label.new()
	weapons.text = "Weapons\nPistol: reliable starter\nShotgun: close range spread\nSniper: slow high damage\nSMG: fast sustained fire\nRailgun: rare heavy precision"
	weapons.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	weapons.modulate = Color(0.72, 0.86, 0.9)
	info_tab.add_child(weapons)

	var lobby_tab := VBoxContainer.new()
	lobby_tab.name = "Lobby"
	lobby_tab.add_theme_constant_override("separation", 11)
	tabs.add_child(lobby_tab)

	lobby_label = Label.new()
	lobby_label.text = "Host a LAN lobby to generate a code. Players on the same network can join using that code."
	lobby_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lobby_label.modulate = Color(0.84, 0.94, 0.96)
	lobby_tab.add_child(lobby_label)

	var code_label := Label.new()
	code_label.text = "Lobby Code"
	code_label.modulate = Color(0.62, 0.76, 0.82)
	lobby_tab.add_child(code_label)
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "Enter host code"
	code_edit.custom_minimum_size = Vector2(0, 42)
	code_edit.add_theme_stylebox_override("normal", _panel_style(Color(0.03, 0.045, 0.055, 0.9), Color(0.0, 0.58, 0.78, 0.65), 1, 4))
	code_edit.add_theme_stylebox_override("focus", _panel_style(Color(0.03, 0.055, 0.065, 0.95), Color(0.0, 0.88, 1.0, 0.95), 2, 4))
	lobby_tab.add_child(code_edit)

	var port_label := Label.new()
	port_label.text = "Lobby Port"
	port_label.modulate = Color(0.62, 0.76, 0.82)
	lobby_tab.add_child(port_label)
	port_spin = SpinBox.new()
	port_spin.min_value = 1024
	port_spin.max_value = 65535
	port_spin.value = network_port
	port_spin.custom_minimum_size = Vector2(0, 42)
	lobby_tab.add_child(port_spin)

	host_button = Button.new()
	host_button.text = "HOST CODE LOBBY"
	host_button.pressed.connect(_on_host_pressed)
	_style_primary_button(host_button)
	lobby_tab.add_child(host_button)

	join_code_button = Button.new()
	join_code_button.text = "JOIN BY CODE"
	join_code_button.pressed.connect(_on_join_code_pressed)
	_style_secondary_button(join_code_button)
	lobby_tab.add_child(join_code_button)

	disconnect_button = Button.new()
	disconnect_button.text = "DISCONNECT"
	disconnect_button.pressed.connect(_on_disconnect_pressed)
	_style_secondary_button(disconnect_button)
	lobby_tab.add_child(disconnect_button)

	var quit_button := Button.new()
	quit_button.text = "QUIT"
	quit_button.pressed.connect(Callable(get_tree(), "quit"))
	_style_secondary_button(quit_button)
	play_tab.add_child(quit_button)


func _build_death_screen() -> void:
	death_layer = CanvasLayer.new()
	death_layer.layer = 12
	add_child(death_layer)

	death_root = Control.new()
	death_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	death_root.visible = false
	death_layer.add_child(death_root)

	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.25, 0.0, 0.0, 0.72)
	death_root.add_child(shade)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -230
	panel.offset_top = -135
	panel.offset_right = 230
	panel.offset_bottom = 135
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.015, 0.02, 0.94), Color(1.0, 0.1, 0.1, 0.8), 2, 8))
	death_root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	death_title = Label.new()
	death_title.text = "YOU DIED"
	death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_title.add_theme_font_size_override("font_size", 42)
	box.add_child(death_title)

	death_info = Label.new()
	death_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(death_info)

	respawn_button = Button.new()
	respawn_button.text = "RESPAWN"
	respawn_button.pressed.connect(_on_respawn_pressed)
	_style_primary_button(respawn_button)
	box.add_child(respawn_button)


func _panel_style(fill: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style


func _style_primary_button(button: Button) -> void:
	button.custom_minimum_size = Vector2(0, 46)
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", Color(0.02, 0.05, 0.06))
	button.add_theme_stylebox_override("normal", _panel_style(Color(0.0, 0.86, 1.0, 0.95), Color(0.72, 1.0, 1.0, 1.0), 1, 5))
	button.add_theme_stylebox_override("hover", _panel_style(Color(0.4, 1.0, 1.0, 1.0), Color(0.92, 1.0, 1.0, 1.0), 1, 5))
	button.add_theme_stylebox_override("pressed", _panel_style(Color(0.0, 0.55, 0.72, 1.0), Color(0.72, 1.0, 1.0, 1.0), 1, 5))


func _style_secondary_button(button: Button) -> void:
	button.custom_minimum_size = Vector2(0, 40)
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color(0.84, 0.96, 1.0))
	button.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.055, 0.065, 0.88), Color(0.0, 0.45, 0.65, 0.7), 1, 5))
	button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.11, 0.13, 0.95), Color(0.0, 0.8, 1.0, 0.95), 1, 5))
	button.add_theme_stylebox_override("pressed", _panel_style(Color(0.02, 0.04, 0.05, 1.0), Color(0.0, 0.8, 1.0, 0.95), 1, 5))


func _make_label(pos: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	label.modulate = Color(0.88, 0.96, 1.0)
	hud_layer.add_child(label)
	return label


func _draw_crosshair() -> void:
	var c := Vector2(12, 12)
	crosshair.draw_line(c + Vector2(-10, 0), c + Vector2(-3, 0), Color(0.8, 1, 1), 2)
	crosshair.draw_line(c + Vector2(3, 0), c + Vector2(10, 0), Color(0.8, 1, 1), 2)
	crosshair.draw_line(c + Vector2(0, -10), c + Vector2(0, -3), Color(0.8, 1, 1), 2)
	crosshair.draw_line(c + Vector2(0, 3), c + Vector2(0, 10), Color(0.8, 1, 1), 2)


func _update_hud() -> void:
	wave_label.text = "WAVE %d   KILLS %d   ENEMIES %d" % [wave, kills, enemies_alive]
	combo_label.text = "COMBO x%d" % combo if combo > 1 else ""
	if not player.is_reloading:
		status_label.text = "TIME FROZEN" if Input.is_action_pressed("slow_time") and slow_charge > 0.02 else ""
	pickup_label.visible = pickup_text_timer > 0.0
	slow_bar.size.x = lerpf(0.0, 220.0, slow_charge)
	ability_label.text = "%s   BURST %.0f%%" % ["DASH READY" if player.dash_cooldown <= 0.0 else "DASH %.1f" % player.dash_cooldown, slow_charge * 100.0]
	flash_rect.color = Color(1.0, 0.02, 0.0, damage_flash * 0.28 if screen_flash_enabled else 0.0)


func _show_wave_banner(text: String) -> void:
	wave_banner_label.text = text
	wave_banner_label.modulate = Color(0.85, 1.0, 1.0, 0.0)
	var tween := create_tween()
	tween.tween_property(wave_banner_label, "modulate", Color(0.85, 1.0, 1.0, 1.0), 0.18)
	tween.tween_interval(0.85)
	tween.tween_property(wave_banner_label, "modulate", Color(0.85, 1.0, 1.0, 0.0), 0.45)


func _show_menu(title: String, action_text: String) -> void:
	paused_for_menu = true
	menu_root.visible = true
	menu_title.text = title
	start_button.text = action_text
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false


func _resume_game() -> void:
	if _is_death_screen_visible():
		return
	paused_for_menu = false
	menu_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_start_pressed() -> void:
	if not game_started:
		game_started = true
		_resume_game()
		_spawn_wave()
	else:
		_resume_game()


func _on_sensitivity_changed(value: float) -> void:
	player.mouse_sensitivity = value / 100.0


func _on_difficulty_selected(index: int) -> void:
	match index:
		0:
			difficulty_scale = 0.78
		2:
			difficulty_scale = 1.28
		_:
			difficulty_scale = 1.0


func _on_flash_toggled(enabled: bool) -> void:
	screen_flash_enabled = enabled


func _show_death_screen() -> void:
	if not death_root:
		return
	death_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var code_text := lobby_code if not lobby_code.is_empty() else desired_join_code
	var join_text := "Lobby code: %s   Port: %d" % [code_text if not code_text.is_empty() else "single-player", network_port]
	death_info.text = "%s\nRespawn keeps you in the same lobby." % join_text


func _hide_death_screen() -> void:
	if death_root:
		death_root.visible = false
	if game_started and not paused_for_menu:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _is_death_screen_visible() -> bool:
	return death_root and death_root.visible


func _on_respawn_pressed() -> void:
	var peer_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	var spawn_pos := _network_spawn_position(peer_id) + Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if player and player.has_method("respawn"):
		player.respawn(spawn_pos)
	_hide_death_screen()
	_update_hud()


func _connect_network_signals() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _is_wave_authority() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func _on_host_pressed() -> void:
	network_port = int(port_spin.value)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(network_port, max_players)
	if err != OK:
		_set_lobby_status("Host failed on port %d" % network_port)
		return
	multiplayer.multiplayer_peer = peer
	network_mode = "host"
	lobby_code = _generate_lobby_code()
	code_edit.text = lobby_code
	_start_discovery_broadcast()
	_prepare_local_network_player(1)
	_set_lobby_status("Hosting lobby %s. Share this code with players on your network." % lobby_code)


func _on_join_code_pressed() -> void:
	desired_join_code = code_edit.text.strip_edges().to_upper()
	if desired_join_code.is_empty():
		_set_lobby_status("Enter a lobby code first.")
		return
	_start_discovery_listen()
	_set_lobby_status("Searching LAN for lobby %s..." % desired_join_code)


func _connect_to_discovered_lobby(host_ip: String, port: int) -> void:
	network_port = port
	resolved_host_ip = host_ip
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(resolved_host_ip, network_port)
	if err != OK:
		_set_lobby_status("Join failed. Check the lobby code and network.")
		return
	multiplayer.multiplayer_peer = peer
	network_mode = "client"
	_set_lobby_status("Joining lobby %s..." % desired_join_code)


func _on_disconnect_pressed() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_stop_lobby_discovery()
	network_mode = "single"
	lobby_code = ""
	desired_join_code = ""
	resolved_host_ip = ""
	spawned_peer_ids.clear()
	for node in get_tree().get_nodes_in_group("network_player"):
		if node != player:
			node.queue_free()
	_prepare_local_network_player(1)
	_set_lobby_status("Offline")


func _on_connected_to_server() -> void:
	var id := multiplayer.get_unique_id()
	_prepare_local_network_player(id)
	_set_lobby_status("Connected as player %d" % id)
	request_lobby_join.rpc_id(1, id)


func _on_connection_failed() -> void:
	_set_lobby_status("Connection failed.")


func _on_server_disconnected() -> void:
	_set_lobby_status("Host disconnected.")
	_on_disconnect_pressed()


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_set_lobby_status("Player %d connected." % id)


func _on_peer_disconnected(id: int) -> void:
	var node := get_node_or_null("Player_%d" % id)
	if node:
		node.queue_free()
	spawned_peer_ids.erase(id)
	_set_lobby_status("Player %d left." % id)


@rpc("any_peer", "call_remote", "reliable")
func request_lobby_join(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	for existing_id in spawned_peer_ids:
		spawn_network_player.rpc_id(peer_id, existing_id)
	spawn_network_player.rpc(peer_id)
	_spawn_network_player(peer_id)


@rpc("authority", "call_local", "reliable")
func spawn_network_player(peer_id: int) -> void:
	_spawn_network_player(peer_id)


func _prepare_local_network_player(peer_id: int) -> void:
	player.name = "Player_%d" % peer_id
	player.add_to_group("network_player")
	player.set_multiplayer_authority(peer_id)
	player.global_position = _network_spawn_position(peer_id)
	if not spawned_peer_ids.has(peer_id):
		spawned_peer_ids.append(peer_id)


func _spawn_network_player(peer_id: int) -> void:
	if get_node_or_null("Player_%d" % peer_id):
		return
	if not spawned_peer_ids.has(peer_id):
		spawned_peer_ids.append(peer_id)
	var remote_player = player_scene.instantiate()
	remote_player.name = "Player_%d" % peer_id
	remote_player.add_to_group("network_player")
	remote_player.set_multiplayer_authority(peer_id)
	add_child(remote_player)
	remote_player.global_position = _network_spawn_position(peer_id)
	if remote_player.has_node("Body"):
		var body := remote_player.get_node("Body") as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.1, 0.45, 1.0) if peer_id != multiplayer.get_unique_id() else Color(0.05, 0.11, 0.16)
		mat.emission_enabled = peer_id != multiplayer.get_unique_id()
		mat.emission = Color(0.0, 0.2, 0.8)
		mat.emission_energy_multiplier = 0.35
		body.material_override = mat


func _network_spawn_position(peer_id: int) -> Vector3:
	var positions := [Vector3(0, 1.2, 9), Vector3(3, 1.2, 9), Vector3(-3, 1.2, 9), Vector3(0, 1.2, 12), Vector3(5, 1.2, 7), Vector3(-5, 1.2, 7)]
	return positions[abs(peer_id) % positions.size()]


func _set_lobby_status(text: String) -> void:
	lobby_status = text
	if lobby_label:
		var code_text := lobby_code if not lobby_code.is_empty() else desired_join_code
		lobby_label.text = "%s\nMode: %s\nCode: %s\nLocal ID: %d" % [text, network_mode, code_text if not code_text.is_empty() else "-", multiplayer.get_unique_id()]


func _generate_lobby_code() -> String:
	var alphabet := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code := ""
	for i in range(4):
		code += alphabet.substr(randi_range(0, alphabet.length() - 1), 1)
	return code


func _start_discovery_broadcast() -> void:
	discovery_broadcaster = PacketPeerUDP.new()
	discovery_broadcaster.set_broadcast_enabled(true)
	discovery_broadcaster.set_dest_address("255.255.255.255", discovery_port)
	discovery_timer = 0.0


func _start_discovery_listen() -> void:
	if discovery_listener:
		discovery_listener.close()
	discovery_listener = PacketPeerUDP.new()
	var err := discovery_listener.bind(discovery_port)
	if err != OK:
		_set_lobby_status("Could not search for lobbies. Check firewall/network permissions.")


func _stop_lobby_discovery() -> void:
	if discovery_broadcaster:
		discovery_broadcaster.close()
		discovery_broadcaster = null
	if discovery_listener:
		discovery_listener.close()
		discovery_listener = null


func _update_lobby_discovery(delta: float) -> void:
	if discovery_broadcaster and network_mode == "host":
		discovery_timer -= delta
		if discovery_timer <= 0.0:
			discovery_timer = 0.75
			var payload := "GREATER_GAME|%s|%d" % [lobby_code, network_port]
			discovery_broadcaster.put_packet(payload.to_utf8_buffer())

	if discovery_listener and network_mode != "host":
		while discovery_listener.get_available_packet_count() > 0:
			var packet := discovery_listener.get_packet()
			var message := packet.get_string_from_utf8()
			var parts := message.split("|")
			if parts.size() == 3 and parts[0] == "GREATER_GAME" and parts[1] == desired_join_code:
				var host_ip := discovery_listener.get_packet_ip()
				port_spin.value = int(parts[2])
				_stop_lobby_discovery()
				_set_lobby_status("Found lobby %s. Connecting..." % desired_join_code)
				_connect_to_discovered_lobby(host_ip, int(parts[2]))
				return
