package main

import "base:runtime"
import "core:os"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:strconv"
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
    width: u32,
    height: u32,
    levels: [dynamic]Game_Level,
    level: u32,
}

Game_State :: enum {
    Active,
    Menu,
    Win,
}

Sprite_Renderer :: struct {
    shader: Shader,
    quad_vao: u32,
}

Resource_Manager :: struct {
    shaders: map[string]Shader,
    textures: map[string]Texture2D,
}

Game_Object :: struct {
    position, size, velocity: Vec2,
    color: Vec3,
    rotation: f32,
    is_solid: bool,
    destroyed: bool,
    sprite: Texture2D,
}

// 0 :: empty space
// 1 :: indestructible brick
// >=2 :: destructable brick, diff colors
Game_Level :: struct {
    bricks: [dynamic]Game_Object,
}

Ball_Object :: struct {
    using game_object: Game_Object,
    radius: f32,
    stuck: bool,
}

PLAYER_SIZE :: Vec2{100, 20}
PLAYER_VELOCITY :: 500

BALL_RADIUS :: 12.5
INITIAL_BALL_VELOCITY :: Vec2{100, -350}

game: Game
g_window: glfw.WindowHandle
resman: Resource_Manager
g_renderer: Sprite_Renderer
player: Game_Object
ball: Ball_Object

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
    ball_move(dt, game.width)
    game_do_collisions()
}

render :: proc(dt: f32) {
    gl.ClearColor(0,0,0,1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    if game.state == .Active {
        tex_bg := resman_get_texture("background")
        draw_sprite(tex_bg, {0,0}, {f32(game.width), f32(game.height)}, 0)
        game_level_draw(&game.levels[game.level])
        game_object_draw(player)
        game_object_draw(ball.game_object)
    }
    glfw.SwapBuffers(g_window)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
		glfw.SetWindowShouldClose(window, glfw.TRUE)
	}

    if key >= 0 && key < 1024 {
        if action == glfw.PRESS {
            game.keys[key] = true
        } else if action == glfw.RELEASE {
            game.keys[key] = false
        }
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
    if game.state != .Active {
        return
    }
    dx := PLAYER_VELOCITY * dt
    if game.keys[glfw.KEY_A] {
        if player.position.x >= 0 {
            player.position.x -= dx
            if ball.stuck {
                ball.position.x -= dx
            }
        }
    }
    if game.keys[glfw.KEY_D] {
        if player.position.x <= f32(game.width) - player.size.x {
            player.position.x += dx
            if ball.stuck {
                ball.position.x += dx
            }
        }
    }
    if game.keys[glfw.KEY_SPACE] {
        ball.stuck = false
    }

    player.position.x = clamp(player.position.x, 0, f32(game.width) - player.size.x)
}

 // initialize game state (load all shaders/textures/levels gameplay state)
init :: proc() {
    context.logger = log.create_console_logger()

    glfw.SetErrorCallback(error_callback)

	if glfw.Init() == glfw.FALSE {
		log.error("Failed to init GLFW")
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
    resman_load_texture("assets/background.jpg", false, "background")
    resman_load_texture("assets/block.png", false, "block")
    resman_load_texture("assets/block_solid.png", false, "block_solid")
    resman_load_texture("assets/paddle.png", true, "paddle")

    one: Game_Level
    two: Game_Level
    three: Game_Level
    four: Game_Level
    game_level_load(&one, "assets/one.lvl", u32(game.width), u32(game.height) / 2)
    game_level_load(&two, "assets/two.lvl", u32(game.width), u32(game.height) / 2)
    game_level_load(&three, "assets/three.lvl", u32(game.width), u32(game.height) / 2)
    game_level_load(&four, "assets/four.lvl", u32(game.width), u32(game.height) / 2)
    append(&game.levels, one)
    append(&game.levels, two)
    append(&game.levels, three)
    append(&game.levels, four)
    game.level = 0
    player_pos := Vec2{ (f32(game.width) / 2) - (PLAYER_SIZE.x / 2), f32(game.height) - PLAYER_SIZE.y}
    player = game_object_make(player_pos, PLAYER_SIZE, resman_get_texture("paddle"))
    ball_pos := player_pos + Vec2{f32(PLAYER_SIZE.x) / 2 - BALL_RADIUS, -BALL_RADIUS * 2}
    ball = ball_object_make(ball_pos, BALL_RADIUS, INITIAL_BALL_VELOCITY, resman_get_texture("face"))
}

ball_object_make :: proc(pos: Vec2, radius: f32 = 12.5, velocity: Vec2, sprite: Texture2D) -> Ball_Object {
    return Ball_Object{
        game_object = game_object_make(pos, Vec2{ radius * 2, radius * 2}, sprite, Vec3{1,1,1}, velocity),
        stuck = true,
        radius = radius,
    }
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
draw_sprite :: proc(tex: Texture2D, position: Vec2, size: Vec2 = {10, 10}, rotate: f32 = 0, color: Vec3 = Vec3{1,1,1}) {
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
    texture_bind(tex)

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

sprite_renderer_destroy :: proc() {
    gl.DeleteVertexArrays(1, &g_renderer.quad_vao)
}

game_object_make :: proc(pos: Vec2 = {0,0}, size: Vec2 = {1,1}, sprite: Texture2D, color: Vec3 = {1,1,1}, velocity: Vec2 = {0,0}) -> Game_Object {
    return {
        position = pos,
        size = size,
        velocity = velocity,
        color = color,
        sprite = sprite,
        rotation = 0,
        is_solid = false,
        destroyed = false,
    }
}

game_object_draw :: proc(obj: Game_Object) {
    draw_sprite(obj.sprite, obj.position, obj.size, obj.rotation, obj.color)
}

game_level_make :: proc() -> Game_Level {
    return {}
}
game_level_load :: proc(game_level: ^Game_Level, file: string, level_width: u32, level_height: u32) {
    // clear bricks
    clear(&game_level.bricks)

    // load file to string
    data_string := read_file_to_string(file)
    defer delete(data_string)

    data_string = strings.trim_space(data_string)

    // read string to brick/space types into tileData
    tile_data: [dynamic][dynamic]Tile_Code
    lines, _ := strings.split(data_string, "\n")
    defer delete(lines)

    for row, y in lines {
        trimmed := strings.trim_space(row)
        if len(trimmed) == 0 do continue

        chars, _ := strings.split(trimmed, " ")
        defer delete(chars)

        row_codes: [dynamic]Tile_Code
        for char, x in chars {
            trimmed := strings.trim_space(char)
            if len(char) == 0 do continue

            val, ok := strconv.parse_int(char)
            if !ok {
                log.error("Failed to parse int from tile_code:", char, "pos:", y, x)
                continue
            }

            code: Tile_Code
            switch val {
                case 0:
                    code = .Space
                case 1:
                    code = .Indestructible_Brick
                case 2:
                    code = .Brick_A
                case 3:
                    code = .Brick_B
                case 4:
                    code = .Brick_C
                case 5:
                    code = .Brick_D
            }
            append(&row_codes, code)
        }
        append(&tile_data, row_codes)
    }
    if len(tile_data) > 0 {
        game_level_init(game_level, tile_data[:], level_width, level_height)
    }
}

game_level_init :: proc(game_level: ^Game_Level, tile_data: [][dynamic]Tile_Code, level_width: u32, level_height: u32) {
    unit_width := f32(level_width) / f32(len(tile_data[0]))
    unit_height := f32(level_height) / f32(len(tile_data))
    for row, r in tile_data {
        for tile_code, c in row {
            pos := Vec2{unit_width * f32(c), unit_height * f32(r)}
            size := Vec2{unit_width, unit_height}
            color := Vec3{1,1,1}
            switch tile_code {
            case .Space:
            case .Indestructible_Brick:
                color = {.8,.8,.7}
                obj := game_object_make(pos, size, resman_get_texture("block_solid"), color)
                obj.is_solid = true
                append(&game_level.bricks, obj)
            case .Brick_A:
                color = {.2,.6,1}
                obj := game_object_make(pos, size, resman_get_texture("block"), color)
                append(&game_level.bricks, obj)
            case .Brick_B:
                color = {.0,.7,.0}
                obj := game_object_make(pos, size, resman_get_texture("block"), color)
                append(&game_level.bricks, obj)
            case .Brick_C:
                color = {.8,.8,.4}
                obj := game_object_make(pos, size, resman_get_texture("block"), color)
                append(&game_level.bricks, obj)
            case .Brick_D:
                color = {1.,.5,.0}
                obj := game_object_make(pos, size, resman_get_texture("block"), color)
                append(&game_level.bricks, obj)
            }
        }
    }
}

Tile_Code :: enum {
    Space = 0,
    Indestructible_Brick = 1,
    Brick_A = 2,
    Brick_B = 3,
    Brick_C = 4,
    Brick_D = 5,
}

game_level_draw :: proc(game_level: ^Game_Level) {
    for tile in game_level.bricks {
        if !tile.destroyed {
            game_object_draw(tile)
        }
    }
}

game_level_is_completed :: proc(game_level: ^Game_Level) -> bool {
    for tile in game_level.bricks {
        if !tile.is_solid && !tile.destroyed {
            return false
        }
    }
    return true
}

read_file_to_string :: proc(path: string) -> string {
	data, ok := os.read_entire_file_from_filename(path)
	if !ok {
		log.error("Failed to read file")
		os.exit(-1)
	}

	return string(data)
}

ball_move :: proc(dt: f32, window_width: u32) -> Vec2 {
    if !ball.stuck {
        ball.position += ball.velocity * dt
        if ball.position.x < 0 {
            ball.velocity.x *= -1
            ball.position.x = 0
        } else if ball.position.x + ball.size.x >= f32(window_width) {
            ball.velocity.x *= -1
            ball.position.x = f32(window_width) - ball.size.x
        }
        if ball.position.y < 0 {
            ball.velocity.y *= -1
            ball.position.y = 0
        }
    }
    return ball.position
}

ball_reset :: proc(position: Vec2, velocity: Vec2) {
    ball.position = position
    ball.velocity = velocity
    ball.stuck = true
}

check_collision :: proc(a: Game_Object, b: Game_Object) -> bool {
    return a.position.x + a.size.x >= b.position.x &&
           b.position.x + b.size.x >= a.position.x &&
           a.position.y + a.size.y >= b.position.y &&
           b.position.y + b.size.y >= a.position.y
}

check_ball_box_collision :: proc(ball: Ball_Object, box: Game_Object) -> bool {
    ball_center := ball.position + ball.radius
    half_extents := Vec2{box.size.x / 2, box.size.y / 2}
    box_center := Vec2{box.position.x + half_extents.x, box.position.y + half_extents.y}
    d := ball_center - box_center
    clamped: Vec2
    clamped.x = clamp(d.x, -half_extents.x, half_extents.x)
    clamped.y = clamp(d.y, -half_extents.y, half_extents.y)
    closest := box_center + clamped
    d = closest - ball_center
    return linalg.length(d) < ball.radius
}

game_do_collisions :: proc() {
    for &box in game.levels[game.level].bricks {
        if !box.destroyed {
            if check_ball_box_collision(ball, box) {
                if !box.is_solid {
                    box.destroyed = true
                }
            }
        }
    }
}
