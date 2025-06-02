package main

import "base:runtime"
import "core:os"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:strings"
import "core:strconv"
import "vendor:glfw"
import ma "vendor:miniaudio"
import sa "core:container/small_array"
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
    powerups: [dynamic]Powerup_Object,
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
    sounds: map[string]^ma.sound,
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
    sticky: bool,
    passthrough: bool,
}

Direction :: enum {
    Up,
    Down,
    Left,
    Right,
}

Direction_Vectors := [Direction]Vec2{
    .Up = {0,1},
    .Down = {0,-1},
    .Left = {-1,0},
    .Right = {1,0},
}

Collision_Data :: struct {
    collided: bool,
    direction: Direction,
    difference_vector: Vec2,
}

Particle :: struct {
    position, velocity: Vec2,
    color: Vec4,
    life: f32,
}

Particle_Generator :: struct {
    particles: sa.Small_Array(MAX_PARTICLES, Particle),
    shader: Shader,
    texture: Texture2D,
    max_particles: int,
    last_used_particle: int,
    vao: u32,
}

PLAYER_SIZE :: Vec2{100, 20}
PLAYER_VELOCITY :: 500

BALL_RADIUS :: 12.5
INITIAL_BALL_VELOCITY :: Vec2{100, -350}

MAX_PARTICLES :: 500

game: Game
g_window: glfw.WindowHandle
resman: Resource_Manager
renderer: Sprite_Renderer
player: Game_Object
ball: Ball_Object
ball_pg: Particle_Generator
post_processor: Post_Processor
g_shake_time: f32

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
    particle_generator_update(&ball_pg, dt, ball, 2, {ball.radius / 2, ball.radius / 2})
    powerups_update(dt)
    if g_shake_time > 0 {
        g_shake_time -= dt
        if g_shake_time <= 0 {
            post_processor.shake = false
        }
    }
    if ball.position.y >= f32(game.height) {
        game_reset_level()
        game_reset_player()
    }
}

render :: proc(dt: f32) {
    if game.state == .Active {
        post_processor_begin_render(post_processor)

            draw_sprite(resman_get_texture("background"), {0,0}, {f32(game.width), f32(game.height)}, 0)
            game_level_draw(&game.levels[game.level])
            game_object_draw(player)
            for p in game.powerups {
                if !p.destroyed {
                    game_object_draw(p)
                }
            }
            particle_generator_draw(ball_pg)
            game_object_draw(ball.game_object)

        post_processor_end_render(post_processor)
        post_processor_render(post_processor, f32(glfw.GetTime()))
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

    projection := linalg.matrix_ortho3d_f32(0, f32(game.width), f32(game.height), 0, -1, 1) // vertex coords == pixel coords

    resman = resman_make()

    resman_load_shader("shaders/sprite_v.glsl", "shaders/sprite_f.glsl", "", "sprite")
    sprite_shader := resman_get_shader("sprite")
    use_program(sprite_shader)
    shader_set_int(sprite_shader, "image", 0)
    shader_set_mat4(sprite_shader, "projection", &projection)

    resman_load_shader("shaders/particle_v.glsl", "shaders/particle_f.glsl", "", "particle")
    particle_shader := resman_get_shader("particle")
    use_program(particle_shader)
    shader_set_int(particle_shader, "sprite", 0)
    shader_set_mat4(particle_shader, "projection", &projection)

    resman_load_shader("shaders/effects_v.glsl", "shaders/effects_f.glsl", "", "effects")
    effects_shader := resman_get_shader("effects")
    use_program(effects_shader)
    post_processor = post_processor_make(effects_shader, game.width, game.height)

    renderer = sprite_renderer_make(sprite_shader)

    resman_load_texture("assets/background.jpg", false, "background")
    resman_load_texture("assets/awesomeface.png", true, "face")
    resman_load_texture("assets/block.png", false, "block")
    resman_load_texture("assets/block_solid.png", false, "block_solid")
    resman_load_texture("assets/paddle.png", true, "paddle")
    resman_load_texture("assets/particle.png", true, "particle")
    resman_load_texture("assets/powerup_chaos.png", true, "chaos")
    resman_load_texture("assets/powerup_confuse.png", true, "confuse")
    resman_load_texture("assets/powerup_increase.png", true, "size")
    resman_load_texture("assets/powerup_passthrough.png", true, "passthrough")
    resman_load_texture("assets/powerup_speed.png", true, "speed")
    resman_load_texture("assets/powerup_sticky.png", true, "sticky")

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
    // ball = ball_object_make(ball_pos, BALL_RADIUS, INITIAL_BALL_VELOCITY, resman_get_texture("face"))
    ball = ball_object_make(ball_pos, BALL_RADIUS, {0, -450}, resman_get_texture("face"))

    particle_tex := resman_get_texture("particle")
    ball_pg = particle_generator_make(particle_shader, particle_tex)

    result := ma.engine_init(nil, &audio_engine)
    if result != ma.result.SUCCESS {
        log.error("Failed to initialize audio engine")
    }

    resman_load_sound("assets/music.mp3", "music")
    resman_load_sound("assets/bleep.mp3", "hit-nonsolid")
    resman_load_sound("assets/solid.wav", "hit-solid")
    resman_load_sound("assets/powerup.wav", "get-powerup")
    resman_load_sound("assets/bleep.wav", "hit-paddle")
    play_sound("music")
}

audio_engine: ma.engine

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

texture2d_make :: proc(alpha: bool) -> Texture2D {
    id: u32
    gl.GenTextures(1, &id)
    return {
        id = id,
        internal_format= alpha ? gl.RGBA : gl.RGB,
        image_format= alpha ? gl.RGBA : gl.RGB,
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
        sounds = make(map[string]^ma.sound)
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

resman_load_sound :: proc(file: string, name: string) -> ^ma.sound {
    sound := new(ma.sound)

    file_cstring := strings.clone_to_cstring(file)
    result := ma.sound_init_from_file(&audio_engine, file_cstring, nil, nil, nil, sound)
    delete(file_cstring)

    if result != ma.result.SUCCESS {
        log.error("Failed to load sound:", file)
        free(sound)
        return nil
    } 

    log.info("Load sound, file:", file, "name:", name)
    resman.sounds[name] = sound
    return resman.sounds[name]
}

play_sound :: proc(name: string, loop: b32 = false) {
    if sound, exists := resman.sounds[name]; exists {
        ma.sound_set_looping(sound, loop)
        ma.sound_seek_to_pcm_frame(sound, 0)
        ma.sound_start(sound)
    } else {
        log.error("Failed to play sound:", name)
    }
}

resman_get_sound :: proc(name: string) -> ^ma.sound {
    sound, exists := resman.sounds[name]; 
    if !exists do log.error("Failed to get sound:", name)
    return sound
}

resman_clear :: proc() {
    for key, val in resman.shaders {
        gl.DeleteProgram(val)
    }
    for key, &val in resman.textures {
        gl.DeleteTextures(1, &val.id)
    }
    for key, &val in resman.sounds {
        ma.sound_uninit(val)
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

    tex := texture2d_make(alpha)

    texture2d_generate(&tex, width, height, tex_data)
    stbi.image_free(tex_data)

    return tex
}

// TODO: use global renderer?
draw_sprite :: proc(tex: Texture2D, position: Vec2, size: Vec2 = {10, 10}, rotate: f32 = 0, color: Vec3 = Vec3{1,1,1}) {
    use_program(renderer.shader)
    // NB: odin stores matrices in column-major order AND uses standard math multiplication. The tutorial uses glm which is also column-major BUT uses row-major multiplication syntax. In odin, the transformations (operations) must be in reverse math order Scale -> Rotate -> Translate.
    model := linalg.matrix4_scale(Vec3{size.x, size.y, 1})
    model = linalg.matrix4_translate(Vec3{-0.5 * size.x, -0.5 * size.y, 0}) * model
    model = linalg.matrix4_rotate(math.to_radians(rotate), Vec3{0,0,1}) * model
    model = linalg.matrix4_translate(Vec3{0.5 * size.x, 0.5 * size.y, 0}) * model
    model = linalg.matrix4_translate(Vec3{position.x, position.y, 0}) * model


    shader_set_mat4(renderer.shader, "model", &model)
    shader_set_vec3(renderer.shader, "spriteColor", color)

    gl.ActiveTexture(gl.TEXTURE0)
    texture_bind(tex)

    gl.BindVertexArray(renderer.quad_vao)
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
    gl.DeleteVertexArrays(1, &renderer.quad_vao)
}

game_object_make :: proc(position: Vec2 = {0,0}, size: Vec2 = {1,1}, sprite: Texture2D, color: Vec3 = {1,1,1}, velocity: Vec2 = {0,0}) -> Game_Object {
    return {
        position = position,
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
    // ball.position.x = clamp(ball.position.x, 0, f32(game.width) - (player.size.x / 2) - ball.radius)
    return ball.position
}

ball_reset :: proc(position: Vec2, velocity: Vec2) {
    ball.position = position
    ball.velocity = velocity
    ball.stuck = true
    ball.sticky = false
    ball.passthrough = false
}

check_collision :: proc(a: Game_Object, b: Game_Object) -> bool {
    return a.position.x + a.size.x >= b.position.x &&
           b.position.x + b.size.x >= a.position.x &&
           a.position.y + a.size.y >= b.position.y &&
           b.position.y + b.size.y >= a.position.y
}

check_ball_box_collision :: proc(ball: Ball_Object, box: Game_Object) -> Collision_Data {
    ball_center := ball.position + ball.radius
    half_extents := Vec2{box.size.x / 2, box.size.y / 2}
    box_center := Vec2{box.position.x + half_extents.x, box.position.y + half_extents.y}
    d := ball_center - box_center
    clamped: Vec2
    clamped.x = clamp(d.x, -half_extents.x, half_extents.x)
    clamped.y = clamp(d.y, -half_extents.y, half_extents.y)
    closest := box_center + clamped
    d = closest - ball_center
    if linalg.length(d) < ball.radius {
        return {
            collided = true,
            direction = vector_direction(d),
            difference_vector = d,
        }
    } else {
        return {
            collided = false,
            direction = .Up,
            difference_vector = {},
        }
    }

}

game_do_collisions :: proc() {
    for &box in game.levels[game.level].bricks {
        if !box.destroyed {
            collision := check_ball_box_collision(ball, box)
            if collision.collided {
                if !box.is_solid {
                    box.destroyed = true
                    powerups_spawn(box)
                    play_sound("hit-nonsolid")
                } else {
                    g_shake_time = 0.1
                    post_processor.shake = true
                    play_sound("hit-solid")
                }
                if !(ball.passthrough && !box.is_solid) {
                    dir := collision.direction
                    diff_vector := collision.difference_vector
                    // horz coll
                    if dir == .Left || dir == .Right {
                        ball.velocity.x *= -1
                        penetration := ball.radius - abs(diff_vector.x)
                        if dir == .Left {
                            ball.position.x += penetration
                        } else {
                            ball.position.x -= penetration
                        }
                        // vert coll
                    } else {
                        ball.velocity.y *= -1
                        penetration := ball.radius - abs(diff_vector.y)
                        if dir == .Up {
                            ball.position.y -= penetration
                        } else {
                            ball.position.y += penetration
                        }

                    }
                }
            }
        }
    }
    for &p in game.powerups {
        if !p.destroyed {
            if p.position.y >= f32(game.height) {
                p.destroyed = true
            }
            if check_collision(player, p) {
                powerup_activate(&p)
                p.destroyed = true
                play_sound("get-powerup")
            }
        }
    }
    collision := check_ball_box_collision(ball, player)
    if !ball.stuck && collision.collided {
        center_board := player.position.x + (player.size.x / 2)
        distance := ball.position.x + ball.radius - center_board
        pct := distance / (player.size.x / 2)
        strength :f32= 2
        speed := linalg.length(ball.velocity)
        ball.velocity.x = INITIAL_BALL_VELOCITY.x * pct * strength
        ball.velocity.y = -1 * abs(ball.velocity.y)
        ball.velocity = linalg.normalize0(ball.velocity) * speed
        ball.stuck = ball.sticky
        play_sound("hit-paddle")
    }
}

vector_direction :: proc(target: Vec2) -> Direction {
    max: f32
    best_match: Direction
    for dir in Direction {
        dot := linalg.dot(linalg.normalize0(target), Direction_Vectors[dir])
        if dot > max {
            max = dot
            best_match = dir
        }
    }
    return best_match
}

game_reset_level :: proc() {
    switch game.level {
    case 0:
        game_level_load(&game.levels[0], "assets/one.lvl", game.width, game.height/2)
    case 1:
        game_level_load(&game.levels[1], "assets/two.lvl", game.width, game.height/2)
    case 2:
        game_level_load(&game.levels[2], "assets/three.lvl", game.width, game.height/2)
    case 3:
        game_level_load(&game.levels[3], "assets/four.lvl", game.width, game.height/2)
    }
    clear(&game.powerups)
}

game_reset_player :: proc() {
    player.size = PLAYER_SIZE
    player.position = Vec2{f32(game.width) / 2 - (player.size.x / 2), f32(game.height) - PLAYER_SIZE.y}
    ball_reset(player.position + Vec2{PLAYER_SIZE.x / 2 - BALL_RADIUS, -(BALL_RADIUS * 2)}, INITIAL_BALL_VELOCITY)
    post_processor.chaos = false
    post_processor.confuse = false
    ball.passthrough = false
    ball.sticky = false
    ball.color = {1,1,1}
}

particle_generator_make :: proc(shader: Shader, texture: Texture2D) -> Particle_Generator {
     // set up mesh and attribute properties
    vbo: u32
    vao: u32
    particle_quad := [?]f32 {
        0.0, 1.0, 0.0, 1.0,
        1.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 0.0,

        0.0, 1.0, 0.0, 1.0,
        1.0, 1.0, 1.0, 1.0,
        1.0, 0.0, 1.0, 0.0
    }
    gl.GenVertexArrays(1, &vao)
    gl.GenBuffers(1, &vbo)
    gl.BindVertexArray(vao)
    // fill mesh buffer
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
    gl.BufferData(gl.ARRAY_BUFFER, size_of(particle_quad), &particle_quad, gl.STATIC_DRAW)
    // set mesh attributes
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, 4 * size_of(f32), uintptr(0))
    gl.BindVertexArray(0)

    // create this->amount default particle instances
    particles: sa.Small_Array(MAX_PARTICLES, Particle)
    particle := particle_make()
    for i in 0..<MAX_PARTICLES {
        sa.push(&particles, particle)
    }
    return Particle_Generator {
        particles = particles,
        shader = shader,
        texture = texture,
        max_particles = MAX_PARTICLES,
        vao = vao,
    }
}

particle_generator_update :: proc(pg: ^Particle_Generator, dt: f32, object: Game_Object, n_new_particles: int, offset: Vec2 = {0,0}) {
    // continuously generate particles
    n_new_particles := 2
    for i in 0..<n_new_particles {
        unused_particle := particle_generator_first_unused_particle(pg)
        particle_generator_respawn_particle(pg, sa.get_ptr(&pg.particles, unused_particle), object, offset)
    }

    // update particles
    for &p in sa.slice(&pg.particles) {
        p.life -= dt
        if p.life > 0 {
            p.position -= p.velocity * dt
            p.color.a -= dt * 2.5
        }
    }
}

particle_generator_first_unused_particle :: proc(pg: ^Particle_Generator) -> int {
    for i in pg.last_used_particle..<sa.len(pg.particles) {
        if sa.get(pg.particles, i).life <= 0 {
            pg.last_used_particle = i
            return i
        }
    }
    for i in 0..<pg.last_used_particle {
        if sa.get(pg.particles, i).life <= 0 {
            pg.last_used_particle = i
            return i
        }
    }
    pg.last_used_particle = 0
    return 0
}

particle_generator_respawn_particle :: proc(pg: ^Particle_Generator, particle: ^Particle, object: Game_Object, offset: Vec2 = {0,0}) {
    rgn := rand.float32_range(-5, 5)
    particle.position = object.position + rgn + offset

    random_color := rand.float32_range(0.5, 1.0)
    particle.color = {random_color, random_color, random_color, 1.0}

    particle.life = 1
    particle.velocity = object.velocity * 0.1
}

particle_generator_draw :: proc(pg: Particle_Generator) {
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE)
    use_program(pg.shader)
    for i in 0..<sa.len(pg.particles) {
        p := sa.get(pg.particles, i)
        if p.life > 0 {
            shader_set_vec2(pg.shader, "offset", p.position)
            shader_set_vec4(pg.shader, "color", p.color)
            texture_bind(pg.texture)
            gl.BindVertexArray(pg.vao)
            gl.DrawArrays(gl.TRIANGLES,0,6)
            gl.BindVertexArray(0)
        }
    }
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
}

particle_make :: proc() -> Particle {
    return {
        color = {1,1,1,1}
    }
}

Post_Processor :: struct {
    shader: Shader,
    texture: Texture2D,
    width: u32,
    height: u32,
    confuse, chaos, shake: bool,
    msfbo, fbo, rbo, vao: u32,
}

post_processor_make :: proc(shader: Shader, width: u32, height: u32) -> Post_Processor {
    // init renderbuffer & framebuffer objects
    msfbo, fbo, rbo: u32
    gl.GenFramebuffers(1, &msfbo)
    gl.GenFramebuffers(1, &fbo)
    gl.GenRenderbuffers(1, &rbo)

    // init renderbuffer storage with a multisampled color buffer, no depth/stencil bufffer
    gl.BindFramebuffer(gl.FRAMEBUFFER, msfbo)
    gl.BindRenderbuffer(gl.RENDERBUFFER, rbo)
    gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, 4, gl.RGB, i32(width), i32(height))
    gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, rbo)
    if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
        log.error("Postprocessor: Failed to initialize MSFBO")
    }

    // init FBO/texture to blit multisampled color buffer to; used for shader ops (postprocessing effects)
    gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
    tex := texture2d_make(true)
    texture2d_generate(&tex, i32(width), i32(height), nil)
    gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex.id, 0)
    if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
        log.error("Postprocessor: Failed to initialize FBO")
    }
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

    // init render data and uniforms
    vao := post_processor_init_render_data()
    use_program(shader)
    shader_set_int(shader, "scene", 0) // , true) // what's with the true?..shader class has new param for its set functions: `useShader: bool`  which calls `use_program` before setting the value
    offset: f32 = 1./300
    offsets := [9][2]f32 {
        { -offset,  offset  },
        { 0,        offset  },
        { offset,   offset  },
        { -offset,  0       },
        { 0,        0       },
        { offset,   0       },
        { -offset,  -offset },
        { 0,        -offset },
        { offset,   -offset },
    }
    gl.Uniform2fv(gl.GetUniformLocation(shader, "offsets"), 9, &offsets[0][0])
    edge_kernel := [9]i32 {
        -1, -1, -1,
        -1,  8, -1,
        -1, -1, -1
    }
    gl.Uniform1iv(gl.GetUniformLocation(shader, "edge_kernel"), 9, &edge_kernel[0]);
    blur_kernel := [9]f32 {
        1./16, 2./16, 1./16,
        2./16, 4./16, 2./16,
        1./16, 2./16, 1./16
    };
    gl.Uniform1fv(gl.GetUniformLocation(shader, "blur_kernel"), 9, &blur_kernel[0]);

    return {
        msfbo = msfbo,
        fbo = fbo,
        rbo = rbo,
        vao = vao,
        texture = tex,
        width = width,
        height = height,
        shader = shader,
    }
}

post_processor_init_render_data :: proc() -> u32 {
    vbo, vao: u32
    gl.GenBuffers(1, &vbo)
    gl.GenVertexArrays(1, &vao)
    vertices := [?]f32 {
         // pos        // tex
        -1.0, -1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 1.0,

        -1.0, -1.0, 0.0, 0.0,
         1.0, -1.0, 1.0, 0.0,
         1.0,  1.0, 1.0, 1.0
    }
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)

    gl.BindVertexArray(vao)
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, 4 * size_of(f32), uintptr(0))
    gl.BindBuffer(gl.ARRAY_BUFFER, 0)
    gl.BindVertexArray(0)
    return vao
}

post_processor_begin_render :: proc(pp: Post_Processor) {
    gl.BindFramebuffer(gl.FRAMEBUFFER, pp.msfbo)
    gl.ClearColor(0,0,0,1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

post_processor_end_render :: proc(pp: Post_Processor) {
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, pp.msfbo)
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, pp.fbo)
    gl.BlitFramebuffer(0, 0, i32(pp.width), i32(pp.height), 0, 0, i32(pp.width), i32(pp.height), gl.COLOR_BUFFER_BIT, gl.NEAREST)
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

post_processor_render :: proc(pp: Post_Processor, time: f32) {
    use_program(pp.shader)
    shader_set_float(pp.shader, "time", time)
    shader_set_bool(pp.shader, "confuse", pp.confuse)
    shader_set_bool(pp.shader, "chaos", pp.chaos)
    shader_set_bool(pp.shader, "shake", pp.shake)
    // render textured quad
    gl.ActiveTexture(gl.TEXTURE0)
    texture_bind(pp.texture)
    gl.BindVertexArray(pp.vao)
    gl.DrawArrays(gl.TRIANGLES, 0, 6)
    gl.BindVertexArray(0)
}

POWERUP_SIZE :: Vec2{60,20}
POWERUP_VELOCITY :: Vec2{0,150}

Powerup_Type :: enum {
     // Speed: increases the velocity of the ball by 20%.
    Speed,
     // Sticky: when the ball collides with the paddle, the ball remains stuck to the paddle unless the spacebar is pressed again. This allows the player to better position the ball before releasing it.
    Sticky,
     // Pass-Through: collision resolution is disabled for non-solid blocks, allowing the ball to pass through multiple blocks.
    Passthrough,
     // Pad-Size-Increase: increases the width of the paddle by 50 pixels.
    Padsize_Increase,
     // Confuse: activates the confuse postprocessing effect for a short period of time, confusing the user
    Confuse,
     // Chaos: activates the chaos postprocessing effect for a short period of time, heavily disorienting the user.
    Chaos,
}

Powerup_Object :: struct {
    using object: Game_Object,
    type: Powerup_Type,
    activated: bool,
    duration: f32,
}

powerup_make :: proc(type: Powerup_Type, color: Vec3, duration: f32, position: Vec2, texture: Texture2D) -> Powerup_Object {
    o := game_object_make(position = position, size = POWERUP_SIZE, sprite = texture, color = color, velocity = POWERUP_VELOCITY)
    return {
        position = o.position,
        size = o.size, 
        velocity = o.velocity,
        color = o.color,
        rotation = o.rotation,
        is_solid = o.is_solid,
        destroyed = o.destroyed,
        sprite = o.sprite,
        // Powerup specific
        type = type,
        duration = duration,
        activated = false,
    }
}

should_spawn :: proc(chance: u32) -> bool {
    chance := 1 / f32(chance)
    rgn := rand.float32()
    return rgn < chance
}

powerups_spawn :: proc(block: Game_Object) {
    if should_spawn(75) { // 1 in 75 chance
        p := powerup_make(.Speed, {0.5,0.5,1.0}, 0, block.position, resman_get_texture("speed"))
        append(&game.powerups, p)
    }
    if should_spawn(75) {
        p := powerup_make(.Sticky, {1,0.5,1.0}, 5, block.position, resman_get_texture("sticky"))
        append(&game.powerups, p)
    }
    if should_spawn(75) {
        p := powerup_make(.Passthrough, {0.5,1.0,0.5}, 10, block.position, resman_get_texture("passthrough"))
        append(&game.powerups, p)
    }
    if should_spawn(75) {
        p := powerup_make(.Padsize_Increase, {1.0,0.6,0.4}, 0, block.position, resman_get_texture("size"))
        append(&game.powerups, p)
    }
    if should_spawn(15) {
        p := powerup_make(.Confuse, {1.0,0.3,0.3}, 15, block.position, resman_get_texture("confuse"))
        append(&game.powerups, p)
    }
    if should_spawn(15) {
        p := powerup_make(.Chaos, {0.9,0.25,0.25}, 15, block.position, resman_get_texture("chaos"))
        append(&game.powerups, p)
    }
}

powerup_activate :: proc(p: ^Powerup_Object) {
    p.activated = true
    // apply effect
    // set timer, ensure is ticked
    switch p.type {
    case .Speed:
        ball.velocity *= 1.2
    case .Sticky:
        ball.sticky = true
        player.color = {1,0.5,1}
    case .Passthrough:
        ball.passthrough = true
        ball.color = {1,0.5,0.5}
    case .Padsize_Increase:
        player.size.x += 50
    case .Confuse:
        if !post_processor.chaos {
            post_processor.confuse = true
        }
    case .Chaos:
        if !post_processor.confuse {
            post_processor.chaos = true
        }
    }
}

powerups_update :: proc(dt: f32) {
    for &p in game.powerups {
        p.position += p.velocity * dt

        if p.activated {
            p.duration -= dt

            if p.duration <= 0 {
                p.activated = false

                if p.type == .Sticky {
                    if !is_other_powerup_active(.Sticky) {
                        ball.sticky = false
                        player.color = {1,1,1}
                    }
                } else if p.type == .Passthrough {
                    if !is_other_powerup_active(.Passthrough) {
                        ball.passthrough = false
                        ball.color = {1,1,1}
                    }
                } else if p.type == .Confuse {
                    if !is_other_powerup_active(.Confuse) {
                        post_processor.confuse = false
                    }
                } else if p.type == .Chaos {
                    if !is_other_powerup_active(.Chaos) {
                        post_processor.chaos = false
                    }
                }
            }
        }
    }
    indices_to_remove: [dynamic]int
    defer delete(indices_to_remove)
    for p, i in game.powerups {
        if p.destroyed && !p.activated {
            append(&indices_to_remove, i)
        }
    }
    for idx in indices_to_remove {
        unordered_remove(&game.powerups, idx)
    }
}

is_other_powerup_active :: proc(type: Powerup_Type) -> bool {
    for p in game.powerups {
        if p.activated && p.type == type {
            return true
        }
    }
    return false
}
