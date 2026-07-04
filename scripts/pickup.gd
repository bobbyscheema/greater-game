extends Area3D

@export var kind := "ammo"
@export var amount := 18.0
@export var label := "AMMO"

var bob_phase := 0.0
var base_y := 0.0

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	base_y = position.y
	bob_phase = randf() * TAU
	_apply_material()


func _process(delta: float) -> void:
	bob_phase += delta * 2.8
	position.y = base_y + sin(bob_phase) * 0.18
	rotation.y += delta * 1.7


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
