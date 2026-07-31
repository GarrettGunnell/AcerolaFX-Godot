@tool
extends CompositorEffect
class_name AcerolaFX_Blur


@export var kernel_size : int = 1;

var rd : RenderingDevice;
var shader : RID;
var pipeline : RID;

var nearest_sampler : RID;

@export_tool_button("Recompile", "Callable") var recompile_action = compile_shader;

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT;
	needs_motion_vectors = true;
	
	rd = RenderingServer.get_rendering_device();
	if not rd: return;
	
	compile_shader();
	
	# Create nearest neighbor sampler state
	var sampler_state : RDSamplerState = RDSamplerState.new();
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST;
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST;
	nearest_sampler = rd.sampler_create(sampler_state);


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
	var push_constant : PackedInt32Array = PackedInt32Array();
	push_constant.push_back(render_size.x);
	push_constant.push_back(render_size.y);
	push_constant.push_back(kernel_size);
	push_constant.push_back(0);
	
	var color_buffer : RID = render_scene_buffers.get_color_layer(0);
	var motion_vector_buffer : RID = render_scene_buffers.get_velocity_layer(0);
	var depth_buffer : RID = render_scene_buffers.get_depth_layer(0);
	
	# Create a uniform set.
	var color_buffer_uniform : RDUniform = RDUniform.new();
	color_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	color_buffer_uniform.binding = 0;
	color_buffer_uniform.add_id(color_buffer);
	
	# Depth cannot be bound as image2D due to being created without the proper usage flag, it must be accessed with a sampler2D instead
	var depth_buffer_uniform : RDUniform = RDUniform.new();
	depth_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
	depth_buffer_uniform.binding = 1;
	depth_buffer_uniform.add_id(nearest_sampler);
	depth_buffer_uniform.add_id(depth_buffer);
	
	var motion_buffer_uniform : RDUniform = RDUniform.new();
	motion_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	motion_buffer_uniform.binding = 2;
	motion_buffer_uniform.add_id(motion_vector_buffer);
	
	var uniform_set : RID = UniformSetCacheRD.get_cache(shader, 0, [ color_buffer_uniform, depth_buffer_uniform, motion_buffer_uniform ]);

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


const template_shader: String = """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_image;
layout(rgba16f, set = 0, binding = 2) uniform image2D motion_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	ivec2 raster_size;
	int kernel_size;
	int reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) {
		return;
	}
	
	vec2 uv = gl_GlobalInvocationID.xy / params.raster_size;

	vec4 color = imageLoad(color_image, thread_id);
    vec4 motion = imageLoad(motion_image, thread_id); 
	
	float raw_depth = texture(depth_image, uv).r;

	int kernel_size = params.kernel_size;
	
	int samples = 1;
	vec4 color_sum = color;
	for (int x = -kernel_size; x <= kernel_size; ++x) {
		for (int y = -kernel_size; y <= kernel_size; ++y) {
			if (x == 0 && y == 0) continue;
			
			ivec2 sample_pos = thread_id + ivec2(x, y);
			
			sample_pos = clamp(sample_pos, ivec2(0), size);
			
			color_sum += imageLoad(color_image, sample_pos);
			samples += 1;
		}
	}
	
	
	vec4 color_output = color_sum / vec4(samples);
	vec4 depth_output = vec4(raw_depth);
	vec4 motion_output = abs(motion);

	imageStore(color_image, thread_id, color_output);
}
"""
