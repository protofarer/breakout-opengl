package main

import "base:runtime"
import "core:os"
import "core:c"
import "core:fmt"
import "core:log"
import "vendor:glfw"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

pr :: fmt.println

WINDOW_W :: 1080
WINDOW_H :: 1080

GL_MAJOR_VERSION :: 3
GL_MINOR_VERSION :: 3

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Mat4 :: matrix[4,4]f32

Game :: struct {
    state: Game_State,
    keys: [1024]bool,
    width: i32,
    height: i32,
}

Game_State :: enum {
    Active,
    Menu,
    Win,
}

game: Game
resman: Resource_Manager
g_window: glfw.WindowHandle

main :: proc() {
    init()

    last_frame: f32

	for !glfw.WindowShouldClose(g_window) {
        current_frame := f32(glfw.GetTime())
        dt := current_frame - last_frame
        last_frame = current_frame

        glfw.PollEvents()

        update(dt)
        render(dt)

        free_all(context.temp_allocator)
	}

    resman_clear()
	glfw.Terminate()
	glfw.DestroyWindow(g_window)
}

update :: proc(dt: f32) {
    process_input(dt)
}

render :: proc(dt: f32) {
    gl.ClearColor(0,0,0,1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    glfw.SwapBuffers(g_window)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
		glfw.SetWindowShouldClose(window, glfw.TRUE)
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	gl.Viewport(0,0,width,height)
}

error_callback :: proc "c" (code: i32, desc: cstring) {
    context = runtime.default_context()
    fmt.println(desc, code)
}

process_input :: proc(dt: f32) {
}

 // initialize game state (load all shaders/textures/levels gameplay state)
init :: proc() {
    context.logger = log.create_console_logger()

    glfw.SetErrorCallback(error_callback)

	if glfw.Init() == glfw.FALSE {
		pr("Failed to init GLFW")
		os.exit(-1)
	}

	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR_VERSION)  // order matters for macos
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR_VERSION)

	window := glfw.CreateWindow(WINDOW_W, WINDOW_H, "Breakout", nil, nil)
	if window == nil {
		log.error("Failed to created window")
		os.exit(-1)
	}
	glfw.MakeContextCurrent(window)

	glfw.SetKeyCallback(window, key_callback)
	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)

    // OpenGL config
    gl.load_up_to(GL_MAJOR_VERSION, GL_MINOR_VERSION, glfw.gl_set_proc_address)
    gl.Viewport(0,0,WINDOW_W, WINDOW_H)
    gl.Enable(gl.BLEND) // TODO: segfaults here
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    g_window = window

    game = Game{
       state = .Active,
       width = WINDOW_W,
       height = WINDOW_H,
       // keys: [1024]bool,
    }

    resman = resman_make()
}

Texture2D :: struct {
    id: u32,
    width: i32,
    height: i32,
    internal_format: i32,
    image_format: u32,
    wrap_s: i32,
    wrap_t: i32,
    filter_min: i32,
    filter_max: i32,
}

texture2d_make :: proc() -> Texture2D {
    id: u32
    gl.GenTextures(1, &id)
    return {
        id = id,
        internal_format= gl.RGB,
        image_format= gl.RGB,
        wrap_s= gl.REPEAT,
        wrap_t= gl.REPEAT,
        filter_min= gl.LINEAR,
        filter_max= gl.LINEAR,
    }
}

texture2d_generate :: proc(tex: ^Texture2D, width, height: i32, data: rawptr) {
    tex.width = width
    tex.height = height

    gl.BindTexture(gl.TEXTURE_2D, tex.id)
    gl.TexImage2D(gl.TEXTURE_2D, 0, tex.internal_format, width, height, 0, tex.image_format, gl.UNSIGNED_BYTE, data)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, tex.wrap_s)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, tex.wrap_t)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, tex.filter_min)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, tex.filter_max)

    // unbind
    gl.BindTexture(gl.TEXTURE_2D, 0)
}

texture2d_bind :: proc(tex: Texture2D) {
    gl.BindTexture(gl.TEXTURE_2D, tex.id)
}

// TODO:
Resource_Manager :: struct {
    shaders: map[string]Shader,
    textures: map[string]Texture2D,
}

resman_make :: proc() -> Resource_Manager {
    return {
        shaders = make(map[string]Shader),
        textures = make(map[string]Texture2D),
    }
}

resman_load_shader :: proc(v_shader_file: string, f_shader_file: string, g_shader_file: string, name: string) -> Shader {
    resman.shaders[name] = _resman_load_shader_from_file(v_shader_file, f_shader_file, g_shader_file)
    return resman.shaders[name]
}

resman_get_shader :: proc(name: string) -> Shader {
    return resman.shaders[name]
}

resman_load_texture :: proc(file: string, alpha: bool, name: string) -> Texture2D {
    resman.textures[name] = load_texture_from_file(file, alpha)
    return resman.textures[name]
}

resman_get_texture :: proc(name: string) -> Texture2D {
    return resman.textures[name]
}

resman_clear :: proc() {
    for key, val in resman.shaders {
        gl.DeleteProgram(val)
    }
    for key, &val in resman.textures {
        gl.DeleteTextures(1, &val.id)
    }
}

_resman_load_shader_from_file :: proc(v_shader_file: string, f_shader_file: string, g_shader_file: string) -> Shader {
    shader, ok := shader_make(v_shader_file, f_shader_file, g_shader_file)
	if !ok {
		log.error("Failed to create shader")
		os.exit(-1) // TODO: dont exit
	}
    return shader
}

load_texture_from_file :: proc(file: string, alpha: bool) -> Texture2D {
    width, height, n_channels: i32
    file := fmt.ctprintf("%v", file)
    stbi.set_flip_vertically_on_load(1)
    tex_data := stbi.load(file, &width, &height, &n_channels, 0)
    if tex_data == nil {
        log.error("Failed to load jpg")
        os.exit(-1)
    }

    tex := texture2d_make()
    if alpha {
        tex.internal_format = gl.RGBA
        tex.image_format = gl.RGBA
    }

    texture2d_generate(&tex, width, height, tex_data)
    stbi.image_free(tex_data)

    return tex
}

