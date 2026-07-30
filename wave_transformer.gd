extends Node

@export var x_frequency : float = 1.0;
@export var x_amplitude : float = 1.0;
@export var y_frequency : float = 1.0;
@export var y_amplitude : float = 1.0;

var t : float = 0.0;

func _process(delta: float) -> void:
	self.position.x = sin(t * x_frequency) * x_amplitude;
	self.position.y = sin(t * y_frequency) * y_amplitude;
	
	t += delta;
