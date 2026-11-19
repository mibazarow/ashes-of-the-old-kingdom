extends Node
## Central signal bus. Systems talk through here instead of holding references.

signal player_health_changed(current: int, maximum: int)
signal player_mana_changed(current: int, maximum: int)
signal player_xp_changed(current: int, needed: int, level: int)
signal player_gold_changed(amount: int)
signal player_died()
signal player_respawned()

signal enemy_died(enemy_id: StringName, enemy_type: StringName, world_position: Vector2)
signal damage_dealt(payload: Dictionary)

signal status_applied(status_name: String, duration: float)
signal status_expired(status_name: String)

signal quest_started(quest_id: StringName)
signal quest_progress(quest_id: StringName, current: int, target: int)
signal quest_completed(quest_id: StringName)

signal item_picked(item_id: StringName, amount: int)
signal inventory_changed()
signal equipment_changed()

signal toast(message: String)
signal interact_prompt(text: String)
signal dialogue_requested(lines: Array)
signal dialogue_closed()
signal game_paused(is_paused: bool)
signal save_loaded(player_position: Vector2)
