@tool
extends CompositorEffect
class_name AcerolaFX_Blur

@export var disabled : bool = false;
enum BlurType {BOX, GAUSSIAN, KAWASE};
@export var blur_type : BlurType;
@export_range(1, 1000) var kernel_size : int = 1;
@export_range(1, 10) var pass_count : int = 1;
@export var std_deviation : float = 1.0;

@export_group("Experimental")
@export var race_condition_blur : bool = false;
@export var unseparated_box_blur : bool = false;
@export_group("")

var rd : RenderingDevice;

var blit_shader : RID;
var blit_pipeline : RID;

var single_buffer_blur_shader : RID;
var single_buffer_blur_pipeline : RID;

var unseparated_blur_shader : RID;
var unseparated_blur_pipeline : RID;

var box_blur_pass_one_shader : RID;
var box_blur_pass_one_pipeline : RID;
var box_blur_pass_two_shader : RID;
var box_blur_pass_two_pipeline : RID;

var gaussian_blur_pass_one_shader : RID;
var gaussian_blur_pass_one_pipeline : RID;
var gaussian_blur_pass_two_shader : RID;
var gaussian_blur_pass_two_pipeline : RID;

var kawase_blur_pass_one_shader : RID;
var kawase_blur_pass_one_pipeline : RID;
var kawase_blur_pass_two_shader : RID;
var kawase_blur_pass_two_pipeline : RID;

var linear_sampler : RID;
var pong_texture : RID;
var pong_size : Vector2i = Vector2i.ZERO;

@export_tool_button("Recompile", "Callable") var recompile_action = compile_shaders;

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT;
	
	rd = RenderingServer.get_rendering_device();
	if not rd: return;
	
	compile_shaders();
	
	# Create linear neighbor sampler state
	var sampler_state : RDSamplerState = RDSamplerState.new();
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR;
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR;
	linear_sampler = rd.sampler_create(sampler_state);


func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	if disabled: return;
	if not rd: return;
	if not single_buffer_blur_pipeline.is_valid(): return;
	
	var render_scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers();
	if not render_scene_buffers: return;
	
	var render_size : Vector2i = render_scene_buffers.get_internal_size();
	if render_size.x == 0 and render_size.y == 0: return;
	
	# Regenerate pong texture
	if pong_size != render_size:
		if pong_texture.is_valid(): rd.free_rid(pong_texture);
		
		var pong_format : RDTextureFormat = RDTextureFormat.new();
		pong_format.width = render_size.x;
		pong_format.height = render_size.y;
		pong_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT;
		pong_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT;
		
		pong_texture = rd.texture_create(pong_format, RDTextureView.new());
		pong_size = render_size;
	
	if race_condition_blur:
		bad_blur(render_scene_buffers);
		return;
	
	if unseparated_box_blur:
		unseparated_blur(render_scene_buffers);
		return;
	
	if blur_type == BlurType.BOX:
		box_blur(render_scene_buffers);
	elif blur_type == BlurType.GAUSSIAN:
		gaussian_blur(render_scene_buffers);
	elif blur_type == BlurType.KAWASE:
		kawase_blur(render_scene_buffers);


func bad_blur(_render_scene_buffers: RenderSceneBuffersRD) -> void:
	var render_size : Vector2i = _render_scene_buffers.get_internal_size();
	
	var x_groups : int = int(float(render_size.x - 1) / 8 + 1);
	var y_groups : int = int(float(render_size.y - 1) / 8 + 1);
	var z_groups : int = 1;
	
	var push_constant : PackedInt32Array = PackedInt32Array();
	push_constant.push_back(render_size.x);
	push_constant.push_back(render_size.y);
	push_constant.push_back(kernel_size);
	push_constant.push_back(0);
	
	var color_buffer : RID = _render_scene_buffers.get_color_layer(0);
	
	var color_buffer_uniform : RDUniform = RDUniform.new();
	color_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	color_buffer_uniform.binding = 0;
	color_buffer_uniform.add_id(color_buffer);
	
	var uniform_set : RID = UniformSetCacheRD.get_cache(single_buffer_blur_shader, 0, [ color_buffer_uniform ]);
	
	var compute_list := rd.compute_list_begin();
	rd.compute_list_bind_compute_pipeline(compute_list, single_buffer_blur_pipeline);
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
	rd.compute_list_end();


func unseparated_blur(_render_scene_buffers: RenderSceneBuffersRD) -> void:
	var render_size : Vector2i = _render_scene_buffers.get_internal_size();
	
	var x_groups : int = int(float(render_size.x - 1) / 8 + 1);
	var y_groups : int = int(float(render_size.y - 1) / 8 + 1);
	var z_groups : int = 1;
	
	var push_constant : PackedInt32Array = PackedInt32Array();
	push_constant.push_back(render_size.x);
	push_constant.push_back(render_size.y);
	push_constant.push_back(kernel_size);
	push_constant.push_back(0);
	
	var color_buffer : RID = _render_scene_buffers.get_color_layer(0);
	
	var color_buffer_uniform : RDUniform = RDUniform.new();
	color_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	color_buffer_uniform.binding = 0;
	color_buffer_uniform.add_id(color_buffer);
	
	var pong_buffer_uniform : RDUniform = RDUniform.new();
	pong_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	pong_buffer_uniform.binding = 1;
	pong_buffer_uniform.add_id(pong_texture);
	
	var blur_uniform_set : RID = UniformSetCacheRD.get_cache(unseparated_blur_shader, 0, [ color_buffer_uniform, pong_buffer_uniform ]);
	
	var source_buffer_uniform : RDUniform = RDUniform.new();
	source_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	source_buffer_uniform.binding = 0;
	source_buffer_uniform.add_id(pong_texture);
	
	var destination_buffer_uniform : RDUniform = RDUniform.new();
	destination_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	destination_buffer_uniform.binding = 1;
	destination_buffer_uniform.add_id(color_buffer);
	
	var blit_uniform_set : RID = UniformSetCacheRD.get_cache(blit_shader, 0, [ source_buffer_uniform, destination_buffer_uniform ]);
	
	var compute_list := rd.compute_list_begin();
	rd.compute_list_bind_compute_pipeline(compute_list, unseparated_blur_pipeline);
	rd.compute_list_bind_uniform_set(compute_list, blur_uniform_set, 0);
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
	rd.compute_list_add_barrier(compute_list);
	rd.compute_list_bind_compute_pipeline(compute_list, blit_pipeline);
	rd.compute_list_bind_uniform_set(compute_list, blit_uniform_set, 0);
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
	rd.compute_list_end();


func box_blur(_render_scene_buffers: RenderSceneBuffersRD) -> void:
	var render_size : Vector2i = _render_scene_buffers.get_internal_size();
	
	var x_groups : int = int(float(render_size.x - 1) / 8 + 1);
	var y_groups : int = int(float(render_size.y - 1) / 8 + 1);
	var z_groups : int = 1;
	
	var push_constant : PackedInt32Array = PackedInt32Array();
	push_constant.push_back(render_size.x);
	push_constant.push_back(render_size.y);
	push_constant.push_back(kernel_size);
	push_constant.push_back(0);
	
	var color_buffer : RID = _render_scene_buffers.get_color_layer(0);
	
	var source_buffer_uniform : RDUniform = RDUniform.new();
	source_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	source_buffer_uniform.binding = 0;
	source_buffer_uniform.add_id(color_buffer);
	
	var destination_buffer_uniform : RDUniform = RDUniform.new();
	destination_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	destination_buffer_uniform.binding = 1;
	destination_buffer_uniform.add_id(pong_texture);
	
	var blur_uniform_set : RID = UniformSetCacheRD.get_cache(box_blur_pass_one_shader, 0, [ source_buffer_uniform, destination_buffer_uniform ]);
	
	var compute_list := rd.compute_list_begin();
	rd.compute_list_bind_uniform_set(compute_list, blur_uniform_set, 0);
	
	for blur_pass in pass_count:
		rd.compute_list_bind_compute_pipeline(compute_list, box_blur_pass_one_pipeline);
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		rd.compute_list_bind_compute_pipeline(compute_list, box_blur_pass_two_pipeline);
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
	
	rd.compute_list_end();


func gaussian_blur(_render_scene_buffers: RenderSceneBuffersRD) -> void:
	var render_size : Vector2i = _render_scene_buffers.get_internal_size();
	
	var x_groups : int = int(float(render_size.x - 1) / 8 + 1);
	var y_groups : int = int(float(render_size.y - 1) / 8 + 1);
	var z_groups : int = 1;
	
	
	var push_constant : PackedByteArray = PackedByteArray();
	push_constant.append_array(PackedInt32Array([render_size.x]).to_byte_array())
	push_constant.append_array(PackedInt32Array([render_size.y]).to_byte_array())
	push_constant.append_array(PackedInt32Array([kernel_size]).to_byte_array())
	push_constant.append_array(PackedFloat32Array([std_deviation]).to_byte_array())
	
	var color_buffer : RID = _render_scene_buffers.get_color_layer(0);
	
	var source_buffer_uniform : RDUniform = RDUniform.new();
	source_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	source_buffer_uniform.binding = 0;
	source_buffer_uniform.add_id(color_buffer);
	
	var destination_buffer_uniform : RDUniform = RDUniform.new();
	destination_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	destination_buffer_uniform.binding = 1;
	destination_buffer_uniform.add_id(pong_texture);
	
	var blur_uniform_set : RID = UniformSetCacheRD.get_cache(gaussian_blur_pass_one_shader, 0, [ source_buffer_uniform, destination_buffer_uniform ]);
	
	var compute_list := rd.compute_list_begin();
	rd.compute_list_bind_uniform_set(compute_list, blur_uniform_set, 0);
	
	for blur_pass in pass_count:
		rd.compute_list_bind_compute_pipeline(compute_list, gaussian_blur_pass_one_pipeline);
		rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size());
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		rd.compute_list_bind_compute_pipeline(compute_list, gaussian_blur_pass_two_pipeline);
		rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size());
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
	
	rd.compute_list_end();


func kawase_blur(_render_scene_buffers: RenderSceneBuffersRD) -> void:
	var render_size : Vector2i = _render_scene_buffers.get_internal_size();
	
	var x_groups : int = int(float(render_size.x - 1) / 8 + 1);
	var y_groups : int = int(float(render_size.y - 1) / 8 + 1);
	var z_groups : int = 1;
	
	var push_constant : PackedInt32Array = PackedInt32Array();
	push_constant.push_back(render_size.x);
	push_constant.push_back(render_size.y);
	push_constant.push_back(kernel_size);
	push_constant.push_back(0);
	
	var color_buffer : RID = _render_scene_buffers.get_color_layer(0);
	
	var ping_pass_source_uniform : RDUniform = RDUniform.new();
	ping_pass_source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
	ping_pass_source_uniform.binding = 0;
	ping_pass_source_uniform.add_id(linear_sampler);
	ping_pass_source_uniform.add_id(color_buffer);
	
	var ping_pass_destination_uniform : RDUniform = RDUniform.new();
	ping_pass_destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	ping_pass_destination_uniform.binding = 1;
	ping_pass_destination_uniform.add_id(pong_texture);
	
	var pong_pass_source_uniform : RDUniform = RDUniform.new();
	pong_pass_source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
	pong_pass_source_uniform.binding = 0;
	pong_pass_source_uniform.add_id(linear_sampler);
	pong_pass_source_uniform.add_id(pong_texture);
	
	var pong_pass_destination_uniform : RDUniform = RDUniform.new();
	pong_pass_destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE;
	pong_pass_destination_uniform.binding = 1;
	pong_pass_destination_uniform.add_id(color_buffer);
	
	var ping_uniform_set : RID = UniformSetCacheRD.get_cache(kawase_blur_pass_one_shader, 0, [ ping_pass_source_uniform, ping_pass_destination_uniform ]);
	var pong_uniform_set : RID = UniformSetCacheRD.get_cache(kawase_blur_pass_two_shader, 0, [ pong_pass_source_uniform, pong_pass_destination_uniform ]);
	
	var compute_list := rd.compute_list_begin();
	
	for blur_pass in pass_count:
		# Source (Ping) -> First Blur (Pong) - Distance: 0
		rd.compute_list_bind_compute_pipeline(compute_list, kawase_blur_pass_one_pipeline);
		rd.compute_list_bind_uniform_set(compute_list, ping_uniform_set, 0);
		push_constant[2] = 0;
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		
		# First Blur (Pong) -> Second Blur (Ping) - Distance: 1
		rd.compute_list_bind_compute_pipeline(compute_list, kawase_blur_pass_two_pipeline);
		rd.compute_list_bind_uniform_set(compute_list, pong_uniform_set, 0);
		push_constant[2] = 1;
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		
		# Second Blur (Ping) -> Third Blur (Pong) - Distance: 2
		rd.compute_list_bind_compute_pipeline(compute_list, kawase_blur_pass_one_pipeline);
		rd.compute_list_bind_uniform_set(compute_list, ping_uniform_set, 0);
		push_constant[2] = 2;
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		
		# Third Blur (Pong) -> Fourth Blur (Ping) - Distance: 2
		rd.compute_list_bind_compute_pipeline(compute_list, kawase_blur_pass_two_pipeline);
		rd.compute_list_bind_uniform_set(compute_list, pong_uniform_set, 0);
		push_constant[2] = 2;
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		
		# Fourth Blur (Ping) -> Fifth Blur (Pong) - Distance: 3
		rd.compute_list_bind_compute_pipeline(compute_list, kawase_blur_pass_one_pipeline);
		rd.compute_list_bind_uniform_set(compute_list, ping_uniform_set, 0);
		push_constant[2] = 3;
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
		
		# Fifth Blur (Pong) -> Sixth Blur (Ping) - Distance: 4
		rd.compute_list_bind_compute_pipeline(compute_list, kawase_blur_pass_two_pipeline);
		rd.compute_list_bind_uniform_set(compute_list, pong_uniform_set, 0);
		push_constant[2] = 4;
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4);
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups);
		rd.compute_list_add_barrier(compute_list);
	
	rd.compute_list_end();


func compile_shaders() -> bool:
	if not rd: return false;
	
	var compilation_success = compile_naive_blur();
	if not compilation_success: return false;
	
	compilation_success = compile_blit_shader();
	if not compilation_success: return false;
	
	compilation_success = compile_unseparated_blur();
	if not compilation_success: return false;
	
	compilation_success = compile_box_blur();
	if not compilation_success: return false;
	
	compilation_success = compile_gaussian_blur();
	if not compilation_success: return false;
	
	compilation_success = compile_kawase_blur();
	if not compilation_success: return false;
	
	return true;


func compile_blit_shader() -> bool:
	if blit_shader.is_valid():
		rd.free_rid(blit_shader);
		blit_shader = RID();
		blit_pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = blit_shader_code();
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	blit_shader = rd.shader_create_from_spirv(shader_spirv);
	if not blit_shader.is_valid(): return false;
	
	blit_pipeline = rd.compute_pipeline_create(blit_shader);
	
	print("Recompiled blit");
	return blit_pipeline.is_valid();


func compile_naive_blur() -> bool:
	if single_buffer_blur_shader.is_valid():
		rd.free_rid(single_buffer_blur_shader);
		single_buffer_blur_shader = RID();
		single_buffer_blur_pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = naive_single_buffer_blur_shader_code();
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	single_buffer_blur_shader = rd.shader_create_from_spirv(shader_spirv);
	if not single_buffer_blur_shader.is_valid(): return false;
	
	single_buffer_blur_pipeline = rd.compute_pipeline_create(single_buffer_blur_shader);
	
	print("Recompiled naive blur");
	return single_buffer_blur_pipeline.is_valid();


func compile_unseparated_blur() -> bool:
	if unseparated_blur_shader.is_valid():
		rd.free_rid(unseparated_blur_shader);
		unseparated_blur_shader = RID();
		unseparated_blur_pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = unseparated_blur_shader_code();
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	unseparated_blur_shader = rd.shader_create_from_spirv(shader_spirv);
	if not unseparated_blur_shader.is_valid(): return false;
	
	unseparated_blur_pipeline = rd.compute_pipeline_create(unseparated_blur_shader);
	
	print("Recompiled unseparated blur");
	return unseparated_blur_pipeline.is_valid();


func compile_box_blur() -> bool:
	if box_blur_pass_one_shader.is_valid():
		rd.free_rid(box_blur_pass_one_shader);
		box_blur_pass_one_shader = RID();
		box_blur_pass_one_pipeline = RID();
	
	if box_blur_pass_two_shader.is_valid():
		rd.free_rid(box_blur_pass_two_shader);
		box_blur_pass_two_shader = RID();
		box_blur_pass_two_pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = box_blur_pass_one_shader_code();
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	box_blur_pass_one_shader = rd.shader_create_from_spirv(shader_spirv);
	if not box_blur_pass_one_shader.is_valid(): return false;
	
	box_blur_pass_one_pipeline = rd.compute_pipeline_create(box_blur_pass_one_shader);
	
	shader_source.source_compute = box_blur_pass_two_shader_code();
	shader_spirv = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	box_blur_pass_two_shader = rd.shader_create_from_spirv(shader_spirv);
	if not box_blur_pass_two_shader.is_valid(): return false;
	
	box_blur_pass_two_pipeline = rd.compute_pipeline_create(box_blur_pass_two_shader);
	
	print("Recompiled box blur");
	return box_blur_pass_one_pipeline.is_valid() and box_blur_pass_two_pipeline.is_valid();


func compile_gaussian_blur() -> bool:
	if gaussian_blur_pass_one_shader.is_valid():
		rd.free_rid(gaussian_blur_pass_one_shader);
		gaussian_blur_pass_one_shader = RID();
		gaussian_blur_pass_one_pipeline = RID();
	
	if gaussian_blur_pass_two_shader.is_valid():
		rd.free_rid(gaussian_blur_pass_two_shader);
		gaussian_blur_pass_two_shader = RID();
		gaussian_blur_pass_two_pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = gaussian_blur_pass_one_shader_code();
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	gaussian_blur_pass_one_shader = rd.shader_create_from_spirv(shader_spirv);
	if not gaussian_blur_pass_one_shader.is_valid(): return false;
	
	gaussian_blur_pass_one_pipeline = rd.compute_pipeline_create(gaussian_blur_pass_one_shader);
	
	shader_source.source_compute = gaussian_blur_pass_two_shader_code();
	shader_spirv = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	gaussian_blur_pass_two_shader = rd.shader_create_from_spirv(shader_spirv);
	if not gaussian_blur_pass_two_shader.is_valid(): return false;
	
	gaussian_blur_pass_two_pipeline = rd.compute_pipeline_create(gaussian_blur_pass_two_shader);
	
	print("Recompiled gaussian blur");
	return gaussian_blur_pass_one_pipeline.is_valid() and gaussian_blur_pass_two_pipeline.is_valid();


func compile_kawase_blur() -> bool:
	if kawase_blur_pass_one_shader.is_valid():
		rd.free_rid(kawase_blur_pass_one_shader);
		kawase_blur_pass_one_shader = RID();
		kawase_blur_pass_one_pipeline = RID();
	
	if kawase_blur_pass_two_shader.is_valid():
		rd.free_rid(kawase_blur_pass_two_shader);
		kawase_blur_pass_two_shader = RID();
		kawase_blur_pass_two_pipeline = RID();
	
	var shader_source: RDShaderSource = RDShaderSource.new();
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL;
	shader_source.source_compute = kawase_blur_pass_one_shader_code();
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	kawase_blur_pass_one_shader = rd.shader_create_from_spirv(shader_spirv);
	if not kawase_blur_pass_one_shader.is_valid(): return false;
	
	kawase_blur_pass_one_pipeline = rd.compute_pipeline_create(kawase_blur_pass_one_shader);
	
	shader_source.source_compute = kawase_blur_pass_two_shader_code();
	shader_spirv = rd.shader_compile_spirv_from_source(shader_source);
	
	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute);
		return false;
	
	kawase_blur_pass_two_shader = rd.shader_create_from_spirv(shader_spirv);
	if not kawase_blur_pass_two_shader.is_valid(): return false;
	
	kawase_blur_pass_two_pipeline = rd.compute_pipeline_create(kawase_blur_pass_two_shader);
	
	print("Recompiled kawase blur");
	return kawase_blur_pass_one_pipeline.is_valid() and kawase_blur_pass_two_pipeline.is_valid();

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if single_buffer_blur_shader.is_valid():
			rd.free_rid(single_buffer_blur_shader);
		
		if linear_sampler.is_valid():
			rd.free_rid(linear_sampler);
		
		if pong_texture.is_valid():
			rd.free_rid(pong_texture);


# Removes serialized variable bloat
func _validate_property(property: Dictionary):
	if property.name == "enabled":
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name == "effect_callback_type":
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name == "needs_motion_vectors":
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name == "needs_normal_roughness":
		property.usage = PROPERTY_USAGE_NO_EDITOR



func blit_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	ivec2 raster_size;
	vec2 reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) return;

	imageStore(destination_image, thread_id, imageLoad(source_image, thread_id));
}
"""

func naive_single_buffer_blur_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

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

	imageStore(color_image, thread_id, color_output);
}
"""

func unseparated_blur_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

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

	vec4 color = imageLoad(source_image, thread_id);

	int kernel_size = params.kernel_size;
	
	int samples = 1;
	vec4 color_sum = color;
	for (int x = -kernel_size; x <= kernel_size; ++x) {
		for (int y = -kernel_size; y <= kernel_size; ++y) {
			if (x == 0 && y == 0) continue;
			
			ivec2 sample_pos = thread_id + ivec2(x, y);
			
			// CLAMP TO EDGE
			//sample_pos = clamp(sample_pos, ivec2(0), size);
			
			// DISCARD OUT OF BOUNDS
			if (sample_pos.x < 0 || size.x <= sample_pos.x || sample_pos.y < 0 || size.y <= sample_pos.y) continue;
			
			color_sum += imageLoad(source_image, sample_pos);
			samples += 1;
		}
	}
	
	vec4 color_output = color_sum / vec4(samples);

	imageStore(destination_image, thread_id, color_output);
}
"""

func box_blur_pass_one_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

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

	vec4 color = imageLoad(source_image, thread_id);

	int kernel_size = params.kernel_size;
	
	int samples = 1;
	vec4 color_sum = color;
	
	for (int x = -kernel_size; x <= kernel_size; ++x) {
		if (x == 0) continue;
			
		ivec2 sample_pos = thread_id + ivec2(x, 0);
			
		// CLAMP TO EDGE
		//sample_pos = clamp(sample_pos.x, ivec2(0), size);
			
		// DISCARD OUT OF BOUNDS
		if (sample_pos.x < 0 || size.x <= sample_pos.x) continue;
			
		color_sum += imageLoad(source_image, sample_pos);
		samples += 1;
	}
	
	vec4 color_output = color_sum / vec4(samples);

	imageStore(destination_image, thread_id, color_output);
}
"""

func box_blur_pass_two_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

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

	vec4 color = imageLoad(destination_image, thread_id);

	int kernel_size = params.kernel_size;
	
	int samples = 1;
	vec4 color_sum = color;
	for (int y = -kernel_size; y <= kernel_size; ++y) {
		if (y == 0) continue;
		
		ivec2 sample_pos = thread_id + ivec2(0, y);
		
		// CLAMP TO EDGE
		//sample_pos = clamp(sample_pos.y, ivec2(0), size);
		
		// DISCARD OUT OF BOUNDS
		if (sample_pos.y < 0 || size.y <= sample_pos.y) continue;
		
		color_sum += imageLoad(destination_image, sample_pos);
		samples += 1;
	}
	
	vec4 color_output = color_sum / vec4(samples);

	imageStore(source_image, thread_id, color_output);
}
"""

func gaussian_blur_pass_one_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	ivec2 raster_size;
	int kernel_size;
	float std_deviation;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) {
		return;
	}
	
	vec2 uv = gl_GlobalInvocationID.xy / params.raster_size;

	vec4 color = imageLoad(source_image, thread_id);

	int kernel_size = params.kernel_size;
	
	float PI = 3.14159265359;
	float sigma = params.std_deviation;
	float sigma_squared = sigma * sigma;
	
	float total_weight = 1.0 / sqrt(2.0 * PI * sigma_squared);
	vec4 color_sum = color * total_weight;
	
	for (int x = -kernel_size; x <= kernel_size; ++x) {
		if (x == 0) continue;
		
		ivec2 sample_pos = thread_id + ivec2(x, 0);
		
		// CLAMP TO EDGE
		//sample_pos = clamp(sample_pos.x, ivec2(0), size);
		
		// DISCARD OUT OF BOUNDS
		if (sample_pos.x < 0 || size.x <= sample_pos.x) continue;
		
		float distance_squared = x * x;
		float gaussian_numerator = exp(-distance_squared / (2.0 * sigma_squared));
		float gaussian_denominator = sqrt(2.0 * PI * sigma_squared);
		float gaussian = gaussian_numerator / gaussian_denominator;
		
		color_sum += imageLoad(source_image, sample_pos) * gaussian;
		total_weight += gaussian;
	}
	
	vec4 color_output = color_sum / vec4(total_weight);

	imageStore(destination_image, thread_id, color_output);
}
"""

func gaussian_blur_pass_two_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	ivec2 raster_size;
	int kernel_size;
	float std_deviation;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) {
		return;
	}
	
	vec2 uv = gl_GlobalInvocationID.xy / params.raster_size;

	vec4 color = imageLoad(destination_image, thread_id);

	int kernel_size = params.kernel_size;
	
	float PI = 3.14159265359;
	float sigma = params.std_deviation;
	float sigma_squared = sigma * sigma;
	
	float total_weight = 1.0 / sqrt(2.0 * PI * sigma_squared);
	vec4 color_sum = color * total_weight;
	
	for (int y = -kernel_size; y <= kernel_size; ++y) {
		if (y == 0) continue;
		
		ivec2 sample_pos = thread_id + ivec2(0, y);
		
		// CLAMP TO EDGE
		//sample_pos = clamp(sample_pos.y, ivec2(0), size);
		
		// DISCARD OUT OF BOUNDS
		if (sample_pos.y < 0 || size.y <= sample_pos.y) continue;
		
		float distance_squared = y * y;
		float gaussian_numerator = exp(-distance_squared / (2.0 * sigma_squared));
		float gaussian_denominator = sqrt(2.0 * PI * sigma_squared);
		float gaussian = gaussian_numerator / gaussian_denominator;
		
		color_sum += imageLoad(destination_image, sample_pos) * gaussian;
		total_weight += gaussian;
	}
	
	vec4 color_output = color_sum / vec4(total_weight);

	imageStore(source_image, thread_id, color_output);
}
"""

func kawase_blur_pass_one_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_texture;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	ivec2 raster_size;
	int sample_distance;
	int reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) {
		return;
	}
	
	// Center of pixel
	vec2 uv = (vec2(thread_id) + 0.5) / vec2(size);
	vec2 texel_size = 1.0 / vec2(size);
	vec2 half_offset = texel_size / 2.0;
	
	vec2 total_offset = half_offset + texel_size * params.sample_distance;
	
	// Pixel corners
	vec2 top_left_uv = uv - total_offset;
	vec2 top_right_uv = uv + vec2(total_offset.x, -total_offset.y);
	vec2 bottom_left_uv = uv + vec2(-total_offset.x, total_offset.y);
	vec2 bottom_right_uv = uv + total_offset;
	
	vec4 top_left = texture(source_texture, top_left_uv);
	vec4 top_right = texture(source_texture, top_right_uv);
	vec4 bottom_left = texture(source_texture, bottom_left_uv);
	vec4 bottom_right = texture(source_texture, bottom_right_uv);

	vec4 color = (top_left + top_right + bottom_left + bottom_right) / 4.0;

	imageStore(destination_image, thread_id, color);
}
"""

func kawase_blur_pass_two_shader_code() -> String:
	return """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_texture;
layout(rgba16f, set = 0, binding = 1) uniform image2D destination_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	ivec2 raster_size;
	int sample_distance;
	int reserved;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 thread_id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (thread_id.x >= size.x || thread_id.y >= size.y) {
		return;
	}
	
	// Center of pixel
	vec2 uv = (vec2(thread_id) + 0.5) / vec2(size);
	vec2 texel_size = 1.0 / vec2(size);
	vec2 half_offset = texel_size / 2.0;
	
	vec2 total_offset = half_offset + texel_size * params.sample_distance;
	
	// Pixel corners
	vec2 top_left_uv = uv - total_offset;
	vec2 top_right_uv = uv + vec2(total_offset.x, -total_offset.y);
	vec2 bottom_left_uv = uv + vec2(-total_offset.x, total_offset.y);
	vec2 bottom_right_uv = uv + total_offset;
	
	vec4 top_left = texture(source_texture, top_left_uv);
	vec4 top_right = texture(source_texture, top_right_uv);
	vec4 bottom_left = texture(source_texture, bottom_left_uv);
	vec4 bottom_right = texture(source_texture, bottom_right_uv);

	vec4 color = (top_left + top_right + bottom_left + bottom_right) / 4.0;
	
	vec4 old_value = texture(source_texture, vec2(thread_id) / vec2(size));

	imageStore(destination_image, thread_id, color);
}
"""
