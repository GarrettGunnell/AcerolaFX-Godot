@tool
extends CompositorEffect
class_name AcerolaFX_ImageBlit

@export var source_texture : Texture2D;
@export var nearest_neighbor : bool = false;

var rd : RenderingDevice;
var shader : RID;
var pipeline : RID;

var nearest_sampler : RID;
var linear_sampler : RID;

@export_tool_button("Recompile", "Callable") var recompile_action = compile_shader;

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT;
	needs_motion_vectors = true;
	needs_normal_roughness = true;
	
	rd = RenderingServer.get_rendering_device();
	if not rd: return;
	
	compile_shader();
	
	# Create nearest neighbor sampler state
	var sampler_state : RDSamplerState = RDSamplerState.new();
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST;
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST;
	nearest_sampler = rd.sampler_create(sampler_state);
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR;
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR;
	linear_sampler = rd.sampler_create(sampler_state);


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
	
	var color_buffer : RID = render_scene_buffers.get_color_layer(0);
	var image_to_blit_buffer : RID = RenderingServer.texture_get_rd_texture(source_texture.get_rid(), true);
	
	# Create a uniform set.
	var color_buffer_uniform : RDUniform = RDUniform.new();
	color_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	color_buffer_uniform.binding = 0;
	color_buffer_uniform.add_id(color_buffer);
	
	var image_to_blit_buffer_uniform : RDUniform = RDUniform.new();
	image_to_blit_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
	image_to_blit_buffer_uniform.binding = 1;
	if nearest_neighbor:
		image_to_blit_buffer_uniform.add_id(nearest_sampler);
	else:
		image_to_blit_buffer_uniform.add_id(linear_sampler);
	
	image_to_blit_buffer_uniform.add_id(image_to_blit_buffer);
	
	var uniform_set : RID = UniformSetCacheRD.get_cache(shader, 0, [ color_buffer_uniform, image_to_blit_buffer_uniform ]);

	# Run our compute shader.
	var compute_list := rd.compute_list_begin();
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline);
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
	rd.compute_list_end();


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
		
		if nearest_sampler.is_valid():
			rd.free_rid(nearest_sampler);
		if linear_sampler.is_valid():
			rd.free_rid(linear_sampler);


const template_shader: String = """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D blit_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	vec2 reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) {
		return;
	}
	
	vec2 uv = gl_GlobalInvocationID.xy / params.raster_size;
	
	vec4 blit_image_color = texture(blit_image, uv);

	vec4 color_output = blit_image_color;

	imageStore(color_image, thread_id, color_output);
}
"""
