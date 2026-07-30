@tool
extends CompositorEffect
class_name BaseCompositorEffect


@export_tool_button("Recompile", "Callable") var recompile_action = compile_shader;


var rd: RenderingDevice
var shader: RID
var pipeline: RID


func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT;
	rd = RenderingServer.get_rendering_device();
	
	compile_shader();


func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	if not rd: return;
	if not pipeline.is_valid(): return;
	
	var render_scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers();
	if not render_scene_buffers: return;
	
	var render_size : Vector2i = render_scene_buffers.get_internal_size();
	if render_size.x == 0 and render_size.y == 0: return;
	
	# Thread groups
	var x_groups : int = (render_size.x - 1) / 8 + 1;
	var y_groups : int = (render_size.y - 1) / 8 + 1;
	var z_groups : int = 1;
	
	# Push constant
	var push_constant : PackedFloat32Array = PackedFloat32Array();
	push_constant.push_back(render_size.x);
	push_constant.push_back(render_size.y);
	push_constant.push_back(0.0);
	push_constant.push_back(0.0);
	
	var input_image = render_scene_buffers.get_color_layer(0);
	
	# Create a uniform set.
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(input_image)
	var uniform_set = UniformSetCacheRD.get_cache(shader, 0, [ uniform ])

	# Run our compute shader.
	var compute_list:= rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
	rd.compute_list_end()


func compile_shader() -> bool:
	if not rd:
		return false;
	
	var shader_code = template_shader;
	
	if shader.is_valid():
		rd.free_rid(shader);
		shader = RID();
		pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = shader_code;
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	shader = rd.shader_create_from_spirv(shader_spirv);
	if not shader.is_valid():
		return false;
	
	pipeline = rd.compute_pipeline_create(shader);
	
	print("Successful recompilation");
	
	return pipeline.is_valid();




func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader);





const template_shader: String = """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec4 color = imageLoad(color_image, uv);
	

	imageStore(color_image, uv, color);
}
"""
