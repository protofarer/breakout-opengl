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
import sa "core:container/small_array"
import "vendor:glfw"
import ma "vendor:miniaudio"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

pr :: fmt.println

LOGICAL_W :: 800
LOGICAL_H :: 600

GL_MAJOR_VERSION :: 3
GL_MINOR_VERSION :: 3

PLAYER_SIZE :: Vec2{100, 20}
PLAYER_VELOCITY :: 500

BALL_RADIUS :: 12.5
BALL_INITIAL_VELOCITY :: Vec2{100, -350}

MAX_PARTICLES :: 500

Vec2 :: [2]f32
Vec2i :: [2]i32
Vec3 :: [3]f32
Vec4 :: [4]f32

Game :: struct {
    state: Game_State,

    keys: [1024]bool,
    keys_processed: [1024]bool,

    width: u32,
    height: u32,

    player: Game_Object,
    ball: Ball_Object,

    levels: [dynamic]Game_Level,
    level: u32,
    powerups: [dynamic]Powerup_Object,
    lives: i32,

    shake_time: f32,

    screen_width: u32,
    screen_height: u32,
    viewport_x: i32,
    viewport_y: i32,
    viewport_width: i32,
    viewport_height: i32,
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

game: Game

window: glfw.WindowHandle
resman: Resource_Manager
audio_engine: ma.engine

sprite_renderer: Sprite_Renderer
ball_pg: Particle_Generator
effects: Post_Processor
text_renderer: Text_Renderer


main :: proc() {
    init()

    last_frame: f32
	for !glfw.WindowShouldClose(window) {
        current_frame := f32(glfw.GetTime())
        dt := current_frame - last_frame
        last_frame = current_frame

        glfw.PollEvents()

        update(dt)
        render(dt)

        free_all(context.temp_allocator)
	}

    resman_clear()
    text_renderer_cleanup(&text_renderer)
	glfw.Terminate()
	glfw.DestroyWindow(window)
}

update :: proc(dt: f32) {
    process_input(dt)

    ball_move(dt, game.width)
    game_do_collisions()
    particle_generator_update(&ball_pg, dt, game.ball, 2, {game.ball.radius / 2, game.ball.radius / 2})
    powerups_update(dt)

    if game.shake_time > 0 {
        game.shake_time -= dt
        if game.shake_time <= 0 {
            effects.shake = false
        }
    }
    if game.ball.position.y >= f32(game.height) {
        game.lives -= 1
        if game.lives == 0 {
            game_reset_level()
            game.state = .Menu
        }
        game_reset_player()
    }
    if game.state == .Active && game_is_completed(game.levels[game.level]) {
        game_reset_level()
        game_reset_player()
        effects.chaos = true
        game.state = .Win
    }
}

render :: proc(dt: f32) {
    gl.Viewport(0, 0, i32(game.screen_width), i32(game.screen_height))
    gl.ClearColor(.08,.08,.08,1)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    effects_begin_render(effects)
        draw_sprite(resman_get_texture("background"), {0,0}, {f32(game.width), f32(game.height)}, 0)
        game_level_draw(&game.levels[game.level])
        game_object_draw(game.player)
        for p in game.powerups {
            if !p.destroyed {
                game_object_draw(p)
            }
        }
        particle_generator_draw(ball_pg)
        game_object_draw(game.ball.game_object)
    effects_end_render(effects)

    effects_render(effects, f32(glfw.GetTime()))

    gl.Viewport(game.viewport_x, game.viewport_y, game.viewport_width, game.viewport_height)
    lives := fmt.tprintf("Lives:%v", game.lives)
    text_renderer_render_text(&text_renderer, lives, 5.0, 5.0, 1.0)

    if game.state == .Menu {
        text_renderer_render_text(&text_renderer, "Press ENTER to start", 320, LOGICAL_H / 2 + 20, 1)
        text_renderer_render_text(&text_renderer, "Press W or S to select level", 325, LOGICAL_H / 2 + 45, 0.75)
    }

    if game.state == .Win {
        text_renderer_render_text(&text_renderer, "You WON!!!", 320, LOGICAL_H / 2 + 20, 1.2, {0,1,0})
        text_renderer_render_text(&text_renderer, "Press ENTER to retry or ESC to quit", 200, LOGICAL_H / 2+ 60, 1.2, {1,1,0})

    }

    glfw.SwapBuffers(window)
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
            game.keys_processed[key] = false
        }
    }
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
    context = runtime.default_context()
    update_viewport_and_projection(u32(width), u32(height))
}

error_callback :: proc "c" (code: i32, desc: cstring) {
    context = runtime.default_context()
    fmt.println(desc, code)
}

process_input :: proc(dt: f32) {
    if game.state == .Menu {
        if game.keys[glfw.KEY_ENTER] && !game.keys_processed[glfw.KEY_ENTER]{
            game.keys_processed[glfw.KEY_ENTER] = true
            game.state = .Active
        }
        if game.keys[glfw.KEY_W] && !game.keys_processed[glfw.KEY_W] {
            game.keys_processed[glfw.KEY_W] = true
            game.level = (game.level + 1) % 4
        }
        if game.keys[glfw.KEY_S] && !game.keys_processed[glfw.KEY_S] {
            game.keys_processed[glfw.KEY_S] = true
            game.level = (game.level - 1) % 4
        }
    }
    if game.state == .Active {
        dx := PLAYER_VELOCITY * dt
        if game.keys[glfw.KEY_A] {
            if game.player.position.x >= 0 {
                game.player.position.x -= dx
                if game.ball.stuck {
                    game.ball.position.x -= dx
                }
            }
        }
        if game.keys[glfw.KEY_D] {
            if game.player.position.x <= f32(game.width) - game.player.size.x {
                game.player.position.x += dx
                if game.ball.stuck {
                    game.ball.position.x += dx
                }
            }
        }
        if game.keys[glfw.KEY_SPACE] {
            game.ball.stuck = false
        }
        if game.keys[glfw.KEY_R] {
            // win state
            game_reset_level()
            game_reset_player()
            effects.chaos = true
            game.state = .Win
        }
        game.player.position.x = clamp(game.player.position.x, 0, f32(game.width) - game.player.size.x)
    }
    if game.state == .Win {
        if game.keys[glfw.KEY_ENTER] {
            // game.keys_processed[glfw.KEY_ENTER] = true // NOTE: is this needed?
            effects.chaos = false
            game.state = .Menu
        }
    }
}

init :: proc() {
    context.logger = log.create_console_logger()

    glfw.SetErrorCallback(error_callback)

	if !bool(glfw.Init()) {
		log.error("Failed to init GLFW")
		os.exit(-1)
	}

	// glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR_VERSION)  // order matters for macos
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR_VERSION)

	window_handle := glfw.CreateWindow(LOGICAL_W, LOGICAL_H, "Breakout", nil, nil)
	if window_handle == nil {
		log.error("Failed to created window")
		os.exit(-1)
	}

	glfw.MakeContextCurrent(window_handle)
    gl.load_up_to(GL_MAJOR_VERSION, GL_MINOR_VERSION, glfw.gl_set_proc_address)

	glfw.SetKeyCallback(window_handle, key_callback)
	glfw.SetFramebufferSizeCallback(window_handle, framebuffer_size_callback)

    gl.Viewport(0,0,LOGICAL_W, LOGICAL_H)
    gl.Enable(gl.BLEND) // TODO: segfaults here
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    window = window_handle

    game = Game{
       state = .Menu,
       width = LOGICAL_W,
       height = LOGICAL_H,
       screen_width = LOGICAL_W,
       screen_height = LOGICAL_H,
       viewport_width = LOGICAL_W,
       viewport_height = LOGICAL_H,
       lives = 3,
    }

    update_viewport_and_projection(LOGICAL_W, LOGICAL_H)

    projection := linalg.matrix_ortho3d_f32(0, f32(game.width), f32(game.height), 0, -1, 1) // vertex coords == pixel coords

    resman_init(&resman)

    resman_load_shader("shaders/sprite_v.glsl", "shaders/sprite_f.glsl", "", "sprite")
    sprite_shader := resman_get_shader("sprite")
    shader_use(sprite_shader)
    shader_set_int(sprite_shader, "image", 0)
    shader_set_mat4(sprite_shader, "projection", &projection)

    resman_load_shader("shaders/particle_v.glsl", "shaders/particle_f.glsl", "", "particle")
    particle_shader := resman_get_shader("particle")
    shader_use(particle_shader)
    shader_set_int(particle_shader, "sprite", 0)
    shader_set_mat4(particle_shader, "projection", &projection)

    resman_load_shader("shaders/effects_v.glsl", "shaders/effects_f.glsl", "", "effects")
    effects_shader := resman_get_shader("effects")
    shader_use(effects_shader)
    post_processor_init(&effects, effects_shader, game.width, game.height)

    sprite_renderer_init(&sprite_renderer, sprite_shader)

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


    result := ma.engine_init(nil, &audio_engine)
    if result != ma.result.SUCCESS {
        log.error("Failed to initialize audio engine")
    }

    resman_load_sound("assets/music.mp3", "music")
    resman_load_sound("assets/bleep.mp3", "hit-nonsolid")
    resman_load_sound("assets/solid.wav", "hit-solid")
    resman_load_sound("assets/powerup.wav", "get-powerup")
    resman_load_sound("assets/bleep.wav", "hit-paddle")

    particle_tex := resman_get_texture("particle")
    particle_generator_init(&ball_pg, particle_shader, particle_tex)

    text_renderer_init(&text_renderer, LOGICAL_W, LOGICAL_H)
    text_renderer_load(&text_renderer, "assets/arial.ttf", 24)

    one, two, three, four: Game_Level
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
    game.player = game_object_make(player_pos, PLAYER_SIZE, resman_get_texture("paddle"))
    ball_pos := player_pos + Vec2{f32(PLAYER_SIZE.x) / 2 - BALL_RADIUS, -BALL_RADIUS * 2}
    game.ball = ball_object_make(ball_pos, BALL_RADIUS, BALL_INITIAL_VELOCITY, resman_get_texture("face"))
    // ball = ball_object_make(ball_pos, BALL_RADIUS, {0, -450}, resman_get_texture("face"))

    play_sound("music")
}

ball_object_make :: proc(pos: Vec2, radius: f32 = 12.5, velocity: Vec2, sprite: Texture2D) -> Ball_Object {
    return Ball_Object{
        game_object = game_object_make(pos, Vec2{ radius * 2, radius * 2}, sprite, Vec3{1,1,1}, velocity),
        stuck = true,
        radius = radius,
    }
}

sprite_renderer_init :: proc(renderer: ^Sprite_Renderer, shader: Shader) {
    renderer.shader = shader
    init_render_data(renderer)
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
    gl.BindTexture(gl.TEXTURE_2D, 0)
}

texture_bind :: proc(tex: Texture2D) {
    gl.BindTexture(gl.TEXTURE_2D, tex.id)
}

resman_init :: proc(resman: ^Resource_Manager) {
    resman.shaders = make(map[string]Shader)
    resman.textures = make(map[string]Texture2D)
    resman.sounds = make(map[string]^ma.sound)
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
    shader_use(sprite_renderer.shader)
    // NB: odin stores matrices in column-major order AND uses standard math multiplication. The tutorial uses glm which is also column-major BUT uses row-major multiplication syntax. In odin, the transformations (operations) must be in reverse math order Scale -> Rotate -> Translate.
    model := linalg.matrix4_scale(Vec3{size.x, size.y, 1})
    model = linalg.matrix4_translate(Vec3{-0.5 * size.x, -0.5 * size.y, 0}) * model
    model = linalg.matrix4_rotate(math.to_radians(rotate), Vec3{0,0,1}) * model
    model = linalg.matrix4_translate(Vec3{0.5 * size.x, 0.5 * size.y, 0}) * model
    model = linalg.matrix4_translate(Vec3{position.x, position.y, 0}) * model


    shader_set_mat4(sprite_renderer.shader, "model", &model)
    shader_set_vec3(sprite_renderer.shader, "spriteColor", color)

    gl.ActiveTexture(gl.TEXTURE0)
    texture_bind(tex)

    gl.BindVertexArray(sprite_renderer.quad_vao)
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
    gl.DeleteVertexArrays(1, &sprite_renderer.quad_vao)
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

ball_move :: proc(dt: f32, window_width: u32) {
    if !game.ball.stuck {
        game.ball.position += game.ball.velocity * dt
        if game.ball.position.x < 0 {
            game.ball.velocity.x *= -1
            game.ball.position.x = 0
        } else if game.ball.position.x + game.ball.size.x >= f32(window_width) {
            game.ball.velocity.x *= -1
            game.ball.position.x = f32(window_width) - game.ball.size.x
        }
        if game.ball.position.y < 0 {
            game.ball.velocity.y *= -1
            game.ball.position.y = 0
        }
    }
}

ball_reset :: proc(position: Vec2, velocity: Vec2) {
    game.ball.position = position
    game.ball.velocity = velocity
    game.ball.stuck = true
    game.ball.sticky = false
    game.ball.passthrough = false
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
            collision := check_ball_box_collision(game.ball, box)
            if collision.collided {
                if !box.is_solid {
                    box.destroyed = true
                    powerups_spawn(box)
                    play_sound("hit-nonsolid")
                } else {
                    game.shake_time = 0.1
                    effects.shake = true
                    play_sound("hit-solid")
                }
                if !(game.ball.passthrough && !box.is_solid) {
                    dir := collision.direction
                    diff_vector := collision.difference_vector
                    if dir == .Left || dir == .Right {
                        game.ball.velocity.x *= -1
                        penetration := game.ball.radius - abs(diff_vector.x)
                        if dir == .Left {
                            game.ball.position.x += penetration
                        } else {
                            game.ball.position.x -= penetration
                        }
                    } else {
                        game.ball.velocity.y *= -1
                        penetration := game.ball.radius - abs(diff_vector.y)
                        if dir == .Up {
                            game.ball.position.y -= penetration
                        } else {
                            game.ball.position.y += penetration
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
            if check_collision(game.player, p) {
                powerup_activate(&p)
                p.destroyed = true
                play_sound("get-powerup")
            }
        }
    }
    collision := check_ball_box_collision(game.ball, game.player)
    if !game.ball.stuck && collision.collided {
        center_board := game.player.position.x + (game.player.size.x / 2)
        distance := game.ball.position.x + game.ball.radius - center_board
        pct := distance / (game.player.size.x / 2)
        strength :f32= 2
        speed := linalg.length(game.ball.velocity)
        game.ball.velocity.x = BALL_INITIAL_VELOCITY.x * pct * strength
        game.ball.velocity.y = -1 * abs(game.ball.velocity.y)
        game.ball.velocity = linalg.normalize0(game.ball.velocity) * speed
        game.ball.stuck = game.ball.sticky
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
    game.lives = 3
}

game_reset_player :: proc() {
    game.player.size = PLAYER_SIZE
    game.player.position = Vec2{f32(game.width) / 2 - (game.player.size.x / 2), f32(game.height) - PLAYER_SIZE.y}
    ball_reset(game.player.position + Vec2{PLAYER_SIZE.x / 2 - BALL_RADIUS, -(BALL_RADIUS * 2)}, BALL_INITIAL_VELOCITY)
    effects.chaos = false
    effects.confuse = false
    game.ball.passthrough = false
    game.ball.sticky = false
    game.ball.color = {1,1,1}
}

particle_generator_init :: proc(pg: ^Particle_Generator, shader: Shader, texture: Texture2D) {
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
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo)

    gl.BufferData(gl.ARRAY_BUFFER, size_of(particle_quad), &particle_quad, gl.STATIC_DRAW)
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, 4 * size_of(f32), uintptr(0))
    gl.BindVertexArray(0)

    particles: sa.Small_Array(MAX_PARTICLES, Particle)
    particle := particle_make()
    for i in 0..<MAX_PARTICLES {
        sa.push(&particles, particle)
    }
    pg^ = Particle_Generator {
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
    shader_use(pg.shader)
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

post_processor_init :: proc(effects: ^Post_Processor, shader: Shader, width: u32, height: u32) {
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
    shader_use(shader)
    shader_set_int(shader, "scene", 0) // , true) // consider shader set unfiform procs new param: `useShader: bool`  which calls `shader_use` before setting the value
    offset: f32 = 1.0 / 300
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

    effects^ = Post_Processor{
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
        // pos      // tex
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

effects_begin_render :: proc(pp: Post_Processor) {
    gl.Viewport(0, 0, i32(pp.width), i32(pp.height))
    gl.BindFramebuffer(gl.FRAMEBUFFER, pp.msfbo)
    gl.ClearColor(0,0,0,1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

effects_end_render :: proc(pp: Post_Processor) {
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, pp.msfbo)
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, pp.fbo)
    gl.BlitFramebuffer(0, 0, i32(pp.width), i32(pp.height), 0, 0, i32(pp.width), i32(pp.height), gl.COLOR_BUFFER_BIT, gl.NEAREST)
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

effects_render :: proc(pp: Post_Processor, time: f32) {
    gl.Viewport(game.viewport_x, game.viewport_y, game.viewport_width, game.viewport_height)
    shader_use(pp.shader)
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
    switch p.type {
    case .Speed:
        game.ball.velocity *= 1.2
    case .Sticky:
        game.ball.sticky = true
        game.player.color = {1,0.5,1}
    case .Passthrough:
        game.ball.passthrough = true
        game.ball.color = {1,0.5,0.5}
    case .Padsize_Increase:
        game.player.size.x += 50
    case .Confuse:
        if !effects.chaos {
            effects.confuse = true
        }
    case .Chaos:
        if !effects.confuse {
            effects.chaos = true
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
                        game.ball.sticky = false
                        game.player.color = {1,1,1}
                    }
                } else if p.type == .Passthrough {
                    if !is_other_powerup_active(.Passthrough) {
                        game.ball.passthrough = false
                        game.ball.color = {1,1,1}
                    }
                } else if p.type == .Confuse {
                    if !is_other_powerup_active(.Confuse) {
                        effects.confuse = false
                    }
                } else if p.type == .Chaos {
                    if !is_other_powerup_active(.Chaos) {
                        effects.chaos = false
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

Character :: struct {
    texture_id: u32,
    size: Vec2i,
    bearing: Vec2i,
    advance: u32,
}

Text_Renderer :: struct {
    characters: map[rune]Character,
    text_shader: Shader,
    vao, vbo: u32,
}

text_renderer_init :: proc(renderer: ^Text_Renderer, width, height: u32) {
    text_shader := resman_load_shader("shaders/text_v.glsl", "shaders/text_f.glsl", "", "text")
    text_projection := linalg.matrix_ortho3d_f32(0, f32(width), f32(height), 0, -1, 1)
    shader_use(text_shader)
    shader_set_mat4(text_shader, "projection", &text_projection)
    shader_set_int(text_shader, "text", 0)

    renderer.text_shader = text_shader

    vao, vbo: u32
    gl.GenVertexArrays(1, &vao)
    gl.GenBuffers(1, &vbo)
    gl.BindVertexArray(vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
    gl.BufferData(gl.ARRAY_BUFFER, size_of(f32) * 6 * 4, nil, gl.DYNAMIC_DRAW)
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, 4 * size_of(f32), 0)
    gl.BindBuffer(gl.ARRAY_BUFFER, 0)
    gl.BindVertexArray(0)

    renderer.vao = vao
    renderer.vbo = vbo
    renderer.characters = make(map[rune]Character)
}

// pre-compile a list of chars from given font
text_renderer_load :: proc(renderer: ^Text_Renderer, font: string, font_size: i32) {
    clear(&renderer.characters)

    font_data, ok := os.read_entire_file(font)
    if !ok {
        log.error("Failed to load font file")
        return
    }
    defer delete(font_data)

    // Initialize font
    font_info: stbtt.fontinfo
    if !stbtt.InitFont(&font_info, raw_data(font_data), 0) {
        log.error("Failed to init font")
        return
    }

    // Calc scale for desired pixel height
    scale := stbtt.ScaleForPixelHeight(&font_info, f32(font_size))

    ascent, descent, line_gap: i32
    stbtt.GetFontVMetrics(&font_info, &ascent, &descent, &line_gap)

    scaled_ascent := i32(f32(ascent) * scale)

    // Disable byte-alignment restriction
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)

    // Gen textures for ASCII chars (0-127)
    for c: rune = 0; c < 128; c += 1 {
        glyph_index := stbtt.FindGlyphIndex(&font_info, c)
        if glyph_index == 0 && c != ' ' {
            continue
        }

        // Get glyph bitmap
        width, height, xoff, yoff: i32
        bitmap := stbtt.GetCodepointBitmap(
            &font_info,
            scale, scale,
            c,
            &width, &height, &xoff, &yoff,
        )

        if bitmap == nil {
            if c == ' ' {
                // Get advance for space
                advance_width, left_side_bearing: i32
                stbtt.GetCodepointHMetrics(&font_info, c, &advance_width, &left_side_bearing)
                
                // Create 1x1 empty texture for space
                texture_id: u32
                gl.GenTextures(1, &texture_id)
                gl.BindTexture(gl.TEXTURE_2D, texture_id)
                
                empty_pixel: u8 = 0
                gl.TexImage2D(
                    gl.TEXTURE_2D, 0, gl.RED,
                    1, 1, 0,
                    gl.RED, gl.UNSIGNED_BYTE,
                    &empty_pixel
                )
                
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
                
                character := Character{
                    texture_id = texture_id,
                    size = {0, 0},
                    bearing = {0, 0},
                    advance = u32(f32(advance_width) * scale),
                }
                renderer.characters[c] = character
            }
            continue
        }
        defer stbtt.FreeBitmap(bitmap, nil)

        // Gen OpenGL texture
        texture_id: u32
        gl.GenTextures(1, &texture_id)
        gl.BindTexture(gl.TEXTURE_2D, texture_id)

        if bitmap != nil {
            gl.TexImage2D(
                gl.TEXTURE_2D, 0, gl.RED,
                width, height, 0,
                gl.RED, gl.UNSIGNED_BYTE,
                bitmap,
            )
        } 

        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

        // Get horizontal metrics
        advance_width, left_side_bearing: i32
        stbtt.GetCodepointHMetrics(&font_info, c, &advance_width, &left_side_bearing)

        x0, y0, x1, y1: i32
        stbtt.GetCodepointBitmapBox(&font_info, c, scale, scale, &x0, &y0, &x1, &y1)

        // Need to calc bitmap_top equivalent (because ref code uses FreeType)
        // In FreeType, bitmap_top is dist from baseline to top of glyph
        // In stb_truetype, yoff is negative and represents top of bbox
        // y0 is the top of the bitmap relative to the baseline (negative for glyphs above baseline)
        bitmap_top := -y0

        character := Character{
            texture_id = texture_id,
            size = {width, height},
            // bearing = {xoff, yoff},
            bearing = {xoff, bitmap_top},
            advance = u32(f32(advance_width) * scale),
        }
        renderer.characters[c] = character
    }

    gl.BindTexture(gl.TEXTURE_2D, 0)
}

text_renderer_render_text :: proc(renderer: ^Text_Renderer, text: string, x, y, scale: f32, color: [3]f32 = {1.0, 1.0, 1.0}) {
    shader_use(renderer.text_shader)
    shader_set_vec3(renderer.text_shader, "textColor", color)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindVertexArray(renderer.vao)

    h_char, _ := renderer.characters['H']
    cursor_x := x

    for c in text {
        ch, exists := renderer.characters[c]
        if !exists {
            continue // Skip unsupported characters
        }

        // Calculate position
        // WARN: this differs from reference code that uses FreeType
        // xpos := cursor_x + f32(character.bearing.x) * scale
        // ypos := y - f32(character.size.y - character.bearing.y) * scale
        xpos := cursor_x + f32(ch.bearing.x) * scale
        ypos := y + f32(h_char.bearing.y - ch.bearing.y) * scale

        w := f32(ch.size.x) * scale
        h := f32(ch.size.y) * scale

        vertices := [6][4]f32{
            {xpos,     ypos + h, 0.0, 1.0}, // Bottom-left
            {xpos + w, ypos,     1.0, 0.0}, // Top-right
            {xpos,     ypos,     0.0, 0.0}, // Top-left

            {xpos,     ypos + h, 0.0, 1.0}, // Bottom-left
            {xpos + w, ypos + h, 1.0, 1.0}, // Bottom-right
            {xpos + w, ypos,     1.0, 0.0}, // Top-right
        }
        gl.BindTexture(gl.TEXTURE_2D, ch.texture_id)

        gl.BindBuffer(gl.ARRAY_BUFFER, renderer.vbo)
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, size_of(vertices), &vertices[0][0])
        gl.BindBuffer(gl.ARRAY_BUFFER, 0)
        gl.DrawArrays(gl.TRIANGLES, 0, 6)

        // Advance cursor for next character (matching C++ bit shift logic)
        // C++: x += (ch.Advance >> 6) * scale; 
        // Note: stb_truetype doesn't use 26.6 fixed point, so no bit shift needed
        cursor_x += f32(ch.advance) * scale
    }
    gl.BindVertexArray(0)
    gl.BindTexture(gl.TEXTURE_2D, 0)
}

text_renderer_cleanup :: proc(renderer: ^Text_Renderer) {
    for char, &character in renderer.characters {
        gl.DeleteTextures(1, &character.texture_id)
    }
    delete(renderer.characters)

    gl.DeleteVertexArrays(1, &renderer.vao)
    gl.DeleteBuffers(1, &renderer.vbo)
}

game_is_completed :: proc(level: Game_Level) -> bool {
    for tile in level.bricks {
        if !tile.is_solid && !tile.destroyed {
            return false
        }
    }
    return true
}

update_viewport_and_projection :: proc(screen_width: u32, screen_height: u32) {
    game.screen_width = screen_width
    game.screen_height = screen_height

    target_aspect := f32(LOGICAL_W) / f32(LOGICAL_H)
    screen_aspect := f32(screen_width) / f32(screen_height)

    if screen_aspect > target_aspect {
        // Screen is wider than target - letterbox on sides
        game.viewport_height = i32(screen_height)
        game.viewport_width = i32(f32(screen_height) * target_aspect)
        game.viewport_x = (i32(screen_width) - game.viewport_width) / 2
        game.viewport_y = 0
    } else {
        // Screen is taller than target - letterbox on top/bottom
        game.viewport_width = i32(screen_width)
        game.viewport_height = i32(f32(screen_width) / target_aspect)
        game.viewport_x = 0
        game.viewport_y = (i32(screen_height) - game.viewport_height) / 2
    }

    projection := linalg.matrix_ortho3d_f32(0, f32(game.width), f32(game.height), 0, -1, 1)

    sprite_shader := resman_get_shader("sprite")
    shader_use(sprite_shader)
    shader_set_mat4(sprite_shader, "projection", &projection)

    particle_shader := resman_get_shader("particle")
    shader_use(particle_shader)
    shader_set_mat4(particle_shader, "projection", &projection)

    text_shader := resman_get_shader("text")
    shader_use(text_shader)
    shader_set_mat4(text_shader, "projection", &projection)

    gl.Viewport(game.viewport_x, game.viewport_y, game.viewport_width, game.viewport_height)
}
