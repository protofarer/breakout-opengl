package main

import "core:log"
import "core:os"
import "core:c"
import "core:fmt"
import "core:math"
import "vendor:glfw"
import gl "vendor:OpenGL"
import "core:strings"

Shader_Object :: u32
Shader :: u32

shader_make :: proc( vertex_shader_filepath: string, fragment_shader_filepath: string, geometry_shader_filepath: string) -> (Shader, bool) {
	vertex_shader_object, vert_ok := load_shader_object_from_file(vertex_shader_filepath, gl.VERTEX_SHADER)
	if !vert_ok {
		return {}, false
	}
    defer gl.DeleteShader(vertex_shader_object)

	fragment_shader_object, frag_ok := load_shader_object_from_file(fragment_shader_filepath, gl.FRAGMENT_SHADER)
	if !frag_ok {
		return {}, false
	}
    defer gl.DeleteShader(fragment_shader_object)

    geometry_shader_object: Shader_Object
    if geometry_shader_filepath != "" {
        geo_ok: bool
        geometry_shader_object, geo_ok = load_shader_object_from_file(geometry_shader_filepath, gl.GEOMETRY_SHADER)
        if !geo_ok {
            return {}, false
        }
    }
    defer gl.DeleteShader(geometry_shader_object) // WARN: what if failed?

	// Link shaders to shader program object
	shader_program: u32
	shader_program = gl.CreateProgram()
	gl.AttachShader(shader_program, vertex_shader_object)
	gl.AttachShader(shader_program, fragment_shader_object)
    if geometry_shader_object != {} {
        gl.AttachShader(shader_program, geometry_shader_object)
    }
	gl.LinkProgram(shader_program)

	success: i32
	info_log: u8
	gl.GetProgramiv(shader_program, gl.LINK_STATUS, &success) 
	if success == 0 {
		gl.GetProgramInfoLog(shader_program, 1024, nil, &info_log)
		log.error("Shader link-time error:", info_log)
		os.exit(-1)
	}

	return Shader(shader_program), true
}

use_program :: proc(shader: Shader) {
	gl.UseProgram(shader)
}

load_shader_object_from_file :: proc(filepath: string, shader_type: u32) -> (shader_out: Shader_Object, shader_ok: bool) {
    data, ok := os.read_entire_file(filepath)
    if !ok {
        log.error("Failed to read shader file:", filepath)
        return {}, false
    }

    str := strings.clone_from_bytes(data)
    shader_source := strings.clone_to_cstring(str)
    delete(data)
    delete(str)

    shader_object := gl.CreateShader(shader_type)
    gl.ShaderSource(shader_object, 1, &shader_source, nil)
    gl.CompileShader(shader_object)

    // Check compilation
    success: i32
    info_log: u8
    gl.GetShaderiv(shader_object, gl.COMPILE_STATUS, &success)
    if success == 0 {
        gl.GetShaderInfoLog(shader_object, 512, nil, &info_log)
        log.error("Shader compilation failed for file", filepath, ": ", info_log)
        os.exit(-1)
    }

    return shader_object, true
}

shader_set_bool :: proc(program: u32, name: string, value: bool) {
	gl.Uniform1i(gl.GetUniformLocation(program, strings.clone_to_cstring(name)),i32(value))
}

shader_set_int :: proc(program: u32, name: string, value: i32) {
    cstring := strings.clone_to_cstring(name)
	gl.Uniform1i(gl.GetUniformLocation(program, cstring), value)
    delete(cstring)
}

shader_set_float :: proc(program: u32, name: string, value: f32) {
    cstring := strings.clone_to_cstring(name)
	gl.Uniform1f(gl.GetUniformLocation(program, cstring), value)
    delete(cstring)
}

shader_set_mat4 :: proc(program: u32, name: string, value: ^Mat4) {
    cstring := strings.clone_to_cstring(name)
	gl.UniformMatrix4fv(gl.GetUniformLocation(program, cstring), 1, false, &value[0,0])
    delete(cstring)
}

shader_set_vec2 :: proc(program: u32, name: string, value: Vec2) {
    cstring := strings.clone_to_cstring(name)
	gl.Uniform2f(gl.GetUniformLocation(program, cstring), value.x, value.y)
    delete(cstring)
}

shader_set_vec3 :: proc(program: u32, name: string, value: Vec3) {
    cstring := strings.clone_to_cstring(name)
	gl.Uniform3f(gl.GetUniformLocation(program, cstring), value.x, value.y, value.z)
    delete(cstring)
}

shader_set_vec4 :: proc(program: u32, name: string, value: Vec4) {
    cstring := strings.clone_to_cstring(name)
	gl.Uniform4f(gl.GetUniformLocation(program, cstring), value.x, value.y, value.z, value.w)
    delete(cstring)
}
