extends Area3D
class_name TimeBullet

@export var damage := 1
@export var max_life := 4.0
@export var time_scaled := true

var velocity := Vector3.ZERO
var team := "player"
var owner_peer_id := 0
var life := 0.0
var impact_tint := Color.WHITE

@onready var trail: MeshInstance3D = $Trail

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	_make_trail()


func setup(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, source_team: String, tint: Color) -> void:
	global_position = start_position
	velocity = direction.normalized() * speed
	damage = bullet_damage
	team = source_team
	impact_tint = tint
	_set_tint(tint)
	look_at(global_position + direction.normalized(), Vector3.UP)


func setup_network(start_position: Vector3, direction: Vector3, speed: float, bullet_damage: int, source_team: String, tint: Color, source_peer_id: int) -> void:
	setup(start_position, direction, speed, bullet_damage, source_team, tint)
	owner_peer_id = source_peer_id


func _physics_process(delta: float) -> void:
	var scale := _time_factor() if time_scaled else 1.0
	var step := delta * scale
	var from := global_position
	var to := global_position + velocity * step
	var hit := _ray_hit(from, to)
	if not hit.is_empty():
		if not _should_ignore(hit["collider"]):
			global_position = hit["position"]
			_hit_collider(hit["collider"])
			return
	global_position = to
	life += delta
	if life > max_life:
		queue_free()


func _on_body_entered(body: Node) -> void:
	_hit_collider(body)


func _hit_collider(body: Object) -> void:
	if not is_instance_valid(body):
		return
	if not body is Node:
		queue_free()
		return
	var node := body as Node
	if _should_ignore(node):
		return
	_spawn_impact()
	if node.has_method("take_damage"):
		node.take_damage(damage, global_position)
	queue_free()


func _on_area_entered(area: Area3D) -> void:
	if area != self:
		_spawn_impact()
		queue_free()


func _time_factor() -> float:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("get_time_factor"):
		return game.get_time_factor()
	return 1.0


func _should_ignore(body: Object) -> bool:
	if not body is Node:
		return false
	var node := body as Node
	if team == "player":
		if owner_peer_id == 0:
			return node.is_in_group("player")
		return node.is_in_group("player") and node.get_multiplayer_authority() == owner_peer_id
	if team == "enemy":
		return node.is_in_group("enemy")
	return false


func _ray_hit(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	return space.intersect_ray(query)


func _spawn_impact() -> void:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("spawn_impact"):
		game.spawn_impact(global_position, impact_tint)


func _make_trail() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.035
	mesh.bottom_radius = 0.035
	mesh.height = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.3, 0.55)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.05)
	mat.emission_energy_multiplier = 1.2
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	trail.mesh = mesh
	trail.position = Vector3(0, 0, 0.55)
	trail.rotation_degrees.x = 90.0


func _set_tint(tint: Color) -> void:
	var mesh_instance := $MeshInstance3D as MeshInstance3D
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 2.8
	mesh_instance.material_override = mat
