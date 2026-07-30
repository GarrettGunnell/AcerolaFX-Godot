extends Node

@export var frequency : float = 1.0;
@export var amplitude : float = 1.0;

var t : float = 0.0;

func _process(delta: float) -> void:
	self.position.x = sin(t * frequency) * amplitude;
	
	t += delta;
