extends Area3D

@export var kind := "ammo"
@export var amount := 18.0
@export var label := "AMMO"

var bob_phase := 0.0
var base_y := 0.0
var icon_root: Node3D

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	base_y = position.y
	bob_phase = randf() * TAU
	_apply_material()
	_build_icon()


func _process(delta: float) -> void:
	bob_phase += delta * 2.8
	position.y = base_y + sin(bob_phase) * 0.18
	rotation.y += delta * 1.7
	if icon_root:
		icon_root.rotation.y -= delta * 0.7


func setup(pickup_kind: String, pickup_amount: float, pickup_label: String) -> void:
	kind = pickup_kind
	amount = pickup_amount
	label = pickup_label


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return

	match kind:
		"ammo":
			body.add_ammo(int(amount))
		"health":
			body.heal(int(amount))
		"overcharge":
			body.add_power("overcharge", amount)
		"damage_boost":
			body.add_power("damage_boost", amount)
		"infinite_ammo":
			body.add_power("infinite_ammo", amount)
		"dash":
			body.add_power("dash", amount)
		"speed_boost":
			body.add_power("speed_boost", amount)
		"shield":
			body.add_power("shield", amount)
		"weapon_crate":
			var crate_game := get_tree().get_first_node_in_group("game")
			if crate_game and crate_game.has_method("open_weapon_crate"):
				crate_game.open_weapon_crate(body)

	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("show_pickup_text"):
		game.show_pickup_text(label)
	queue_free()


func _apply_material() -> void:
	var mat := StandardMaterial3D.new()
	match kind:
		"ammo":
			mat.albedo_color = Color(0.15, 0.75, 1.0)
		"health":
			mat.albedo_color = Color(0.1, 1.0, 0.35)
		"overcharge":
			mat.albedo_color = Color(1.0, 0.25, 0.1)
		"damage_boost":
			mat.albedo_color = Color(1.0, 0.05, 0.05)
		"infinite_ammo":
			mat.albedo_color = Color(1.0, 0.9, 0.15)
		"dash":
			mat.albedo_color = Color(0.65, 0.35, 1.0)
		"speed_boost":
			mat.albedo_color = Color(0.25, 1.0, 0.8)
		"shield":
			mat.albedo_color = Color(0.3, 0.55, 1.0)
		"weapon_crate":
			mat.albedo_color = Color(1.0, 0.55, 0.1)
		_:
			mat.albedo_color = Color.WHITE
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 1.4
	mesh_instance.material_override = mat


func _build_icon() -> void:
	icon_root = Node3D.new()
	icon_root.position = Vector3(0, 0.58, 0)
	add_child(icon_root)

	mesh_instance.scale = Vector3(0.78, 0.78, 0.78)
	var icon_color := _pickup_color()
	_add_icon_ring(icon_color)

	match kind:
		"ammo":
			for i in range(3):
				var round := _icon_mesh(_make_cylinder_mesh(0.055, 0.42), icon_color)
				round.position = Vector3(-0.16 + i * 0.16, 0.02, 0)
				round.rotation_degrees.x = 90
				icon_root.add_child(round)
		"health":
			_add_icon_box(Vector3(0, 0.02, 0), Vector3(0.46, 0.12, 0.12), icon_color)
			_add_icon_box(Vector3(0, 0.02, 0), Vector3(0.12, 0.46, 0.12), icon_color)
		"overcharge":
			var core := _icon_mesh(SphereMesh.new(), icon_color)
			core.scale = Vector3(0.22, 0.22, 0.22)
			icon_root.add_child(core)
			_add_icon_box(Vector3(0, 0.0, 0), Vector3(0.62, 0.055, 0.055), icon_color)
		"damage_boost":
			var blade := _icon_mesh(BoxMesh.new(), icon_color)
			blade.scale = Vector3(0.18, 0.52, 0.08)
			blade.rotation_degrees.z = 45
			icon_root.add_child(blade)
		"infinite_ammo":
			var left := _icon_mesh(_make_torus_mesh(0.12, 0.18), icon_color)
			left.position.x = -0.13
			left.rotation_degrees.y = 90
			icon_root.add_child(left)
			var right := _icon_mesh(_make_torus_mesh(0.12, 0.18), icon_color)
			right.position.x = 0.13
			right.rotation_degrees.y = 90
			icon_root.add_child(right)
		"dash":
			_add_arrow_icon(icon_color, 0.0)
		"speed_boost":
			_add_arrow_icon(icon_color, -0.16)
			_add_arrow_icon(icon_color, 0.16)
		"shield":
			var shield := _icon_mesh(SphereMesh.new(), icon_color)
			shield.scale = Vector3(0.28, 0.36, 0.08)
			icon_root.add_child(shield)
			_add_icon_box(Vector3(0, 0.04, 0.07), Vector3(0.08, 0.42, 0.04), Color(0.82, 1.0, 1.0))
		"weapon_crate":
			_add_icon_box(Vector3(0, 0.0, 0.0), Vector3(0.48, 0.12, 0.12), icon_color)
			_add_icon_box(Vector3(0, 0.0, 0.0), Vector3(0.12, 0.48, 0.12), icon_color)
			_add_icon_box(Vector3(0, 0.0, 0.0), Vector3(0.42, 0.42, 0.04), Color(1.0, 0.82, 0.25))


func _pickup_color() -> Color:
	match kind:
		"ammo":
			return Color(0.15, 0.75, 1.0)
		"health":
			return Color(0.1, 1.0, 0.35)
		"overcharge":
			return Color(1.0, 0.25, 0.1)
		"damage_boost":
			return Color(1.0, 0.05, 0.05)
		"infinite_ammo":
			return Color(1.0, 0.9, 0.15)
		"dash":
			return Color(0.65, 0.35, 1.0)
		"speed_boost":
			return Color(0.25, 1.0, 0.8)
		"shield":
			return Color(0.3, 0.55, 1.0)
		"weapon_crate":
			return Color(1.0, 0.55, 0.1)
	return Color.WHITE


func _icon_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.2
	return mat


func _icon_mesh(mesh: Mesh, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _icon_material(color)
	return node


func _add_icon_box(pos: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := _icon_mesh(mesh, color)
	node.position = pos
	icon_root.add_child(node)


func _add_icon_ring(color: Color) -> void:
	var ring := _icon_mesh(_make_torus_mesh(0.42, 0.48), color)
	ring.rotation_degrees.x = 90
	ring.position.y = -0.04
	icon_root.add_child(ring)


func _add_arrow_icon(color: Color, x_offset: float) -> void:
	var shaft := _icon_mesh(BoxMesh.new(), color)
	shaft.scale = Vector3(0.08, 0.32, 0.06)
	shaft.position = Vector3(x_offset, -0.03, 0)
	shaft.rotation_degrees.z = -38
	icon_root.add_child(shaft)

	var head := _icon_mesh(_make_cylinder_mesh(0.14, 0.16), color)
	head.position = Vector3(x_offset + 0.18, 0.16, 0)
	head.rotation_degrees = Vector3(90, 0, -38)
	icon_root.add_child(head)


func _make_cylinder_mesh(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	return mesh


func _make_torus_mesh(inner_radius: float, outer_radius: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_radius
	mesh.outer_radius = outer_radius
	return mesh
