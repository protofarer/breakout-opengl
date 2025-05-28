package main

import "base:runtime"
import "core:os"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

pr :: fmt.println

WINDOW_W :: 800
WINDOW_H :: 600

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

Sprite_Renderer :: struct {
    shader: Shader,
    quad_vao: u32,
}

g_renderer: Sprite_Renderer


Resource_Manager :: struct {
    shaders: map[string]Shader,
    textures: map[string]Texture2D,
}

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
    tex := resman_get_texture("face")
    // renderer, texture, pos, size, rotation, color
    draw_sprite(&tex, Vec2{200,200}, Vec2{300, 400}, 45, Vec3{0,1,0})
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
    resman_load_shader("shaders/sprite_v.glsl", "shaders/sprite_f.glsl", "", "sprite")


    sprite_shader := resman_get_shader("sprite")
    use_program(sprite_shader)
    shader_set_int(sprite_shader, "image", 0)
    projection := linalg.matrix_ortho3d_f32(0, f32(game.width), f32(game.height), 0, -1, 1) // vertex coords == pixel coords
    shader_set_mat4(sprite_shader, "projection", &projection)

    g_renderer = sprite_renderer_make(sprite_shader)

    resman_load_texture("assets/awesomeface.png", true, "face")
}

sprite_renderer_make :: proc(shader: Shader) -> Sprite_Renderer {
    renderer := Sprite_Renderer{
        shader = shader
    }
    init_render_data(&renderer)
    return renderer
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

texture_bind :: proc(tex: Texture2D) {
    gl.BindTexture(gl.TEXTURE_2D, tex.id)
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
    log.info("Load texture, file:", file, "name:", name)
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
    // stbi.set_flip_vertically_on_load(1)
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

// TODO: use global renderer?
draw_sprite :: proc(tex: ^Texture2D, position: Vec2, size: Vec2 = {10, 10}, rotate: f32 = 0, color: Vec3 = Vec3{1,1,1}) {
    use_program(g_renderer.shader)
    // NB: odin stores matrices in column-major order AND uses standard math multiplication. The tutorial uses glm which is also column-major BUT uses row-major multiplication syntax. In odin, the transformations (operations) must be in reverse math order Scale -> Rotate -> Translate.
    model := linalg.matrix4_scale(Vec3{size.x, size.y, 1})
    model = linalg.matrix4_translate(Vec3{-0.5 * size.x, -0.5 * size.y, 0}) * model
    model = linalg.matrix4_rotate(math.to_radians(rotate), Vec3{0,0,1}) * model
    model = linalg.matrix4_translate(Vec3{0.5 * size.x, 0.5 * size.y, 0}) * model
    model = linalg.matrix4_translate(Vec3{position.x, position.y, 0}) * model


    shader_set_mat4(g_renderer.shader, "model", &model)
    shader_set_vec3(g_renderer.shader, "spriteColor", color)

    gl.ActiveTexture(gl.TEXTURE0)
    texture_bind(tex^)

    gl.BindVertexArray(g_renderer.quad_vao)
    gl.DrawArrays(gl.TRIANGLES, 0, 6)
    gl.BindVertexArray(0)
}

init_render_data :: proc(sprite_renderer: ^Sprite_Renderer) {
    vbo: u32
    vertices := [?]f32{
        0.0, 1.0, 0.0, 1.0,
        1.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 

        0.0, 1.0, 0.0, 1.0,
        1.0, 1.0, 1.0, 1.0,
        1.0, 0.0, 1.0, 0.0
    }

    gl.GenVertexArrays(1, &sprite_renderer.quad_vao)
    gl.GenBuffers(1, &vbo)

    gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)

    gl.BindVertexArray(sprite_renderer.quad_vao)
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, 4 * size_of(f32), uintptr(0))

    // clear
    gl.BindBuffer(gl.ARRAY_BUFFER, 0)
    gl.BindVertexArray(0)
}

sprite_renderer_destroy :: proc(renderer: ^Sprite_Renderer) {
    gl.DeleteVertexArrays(1, &renderer.quad_vao)
}
