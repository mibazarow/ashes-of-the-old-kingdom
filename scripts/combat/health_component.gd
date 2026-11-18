class_name HealthComponent
extends Node
## Reusable HP container for enemies and destructibles.

signal health_changed(current: int, maximum: int)
signal damaged(amount: int, info: Dictionary)
signal died(info: Dictionary)

@export var max_health: int = 30

var current_health: int = 30
var is_dead: bool = false


func _ready() -> void:
	current_health = max_health
	health_changed.emit(current_health, max_health)


func take_damage(amount: int, info: Dictionary = {}) -> int:
	if is_dead or amount <= 0:
		return 0
	var applied := mini(amount, current_health)
	current_health -= applied
	health_changed.emit(current_health, max_health)
	damaged.emit(applied, info)
	if current_health <= 0:
		is_dead = true
		died.emit(info)
	return applied


func heal(amount: int) -> void:
	if is_dead:
		return
	current_health = mini(max_health, current_health + maxi(amount, 0))
	health_changed.emit(current_health, max_health)


func reset() -> void:
	is_dead = false
	current_health = max_health
	health_changed.emit(current_health, max_health)
