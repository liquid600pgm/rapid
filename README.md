# rapid

A game engine written in Nim, optimized for rapid game development and
easy prototyping.

## Installing

To install rapid, use the following command:
```
$ nimble install https://github.com/liquid600pgm/rapid
```

### Linux

On Linux, the development headers for the following libraries must be installed:
 - GL
 - X11
 - Xrandr
 - Xxf86vm
 - Xi
 - Xcursor
 - Xinerama

#### Debian and Ubuntu
```
sudo apt install \
  libgl-dev libx11-dev libxrandr-dev libxxf86vm-dev libxi-dev libxcursor-dev \
  libxinerama-dev
```

#### Fedora
```
sudo dnf install \
  mesa-libGL-devel libX11-devel libXrandr-devel libXxf86vm-devel \
  libXinerama-devel libXi-devel libXcursor-devel
```

#### openSUSE
```
sudo zypper in \
  Mesa-libGL-devel libX11-devel libXrandr-devel libXxf86vm-devel \
  libXinerama-devel libXi-devel libXcursor-devel
```

## Examples

### Opening a window

```nim
import rapid/gfx/surface

# Building a window is fairly straightforward:
var win = initRWindow()
  .title("My Game")
  .size(800, 600)
  .open()

# We need to get a handle to the underlying framebuffer in order to draw on the
# screen
var gfx = win.openGfx()

# Then we can begin a game loop
gfx.loop:
  draw ctx, step:
    ctx.clear(gray(255))
  update step:
    discard
```

### Loading data

```nim
import rapid/gfx/surface
import rapid/res/textures

var win = initRWindow()
  .title("My Game")
  .size(800, 600)
  .open()

var gfx = win.openGfx()

let
  # As of now, only PNGs are supported
  hello = loadRTexture("data/hello.png")

gfx.loop:
  draw ctx, step:
    ctx.clear(gray(0))
    ctx.texture = hello
    ctx.rect(32, 32, 32, 32)
  update step:
    discard
```

### Drawing in batches

rapid does not have a distinct sprite batch, you just add more than 1 shape and
call `draw()`.

```nim
import rapid/gfx/surface
import rapid/gfx/texpack
import rapid/res/textures

var win = initRWindow()
  .title("My Game")
  .size(800, 600)
  .open()

var gfx = win.openGfx()

let
  # RImages are not textures, but rather raw image data
  sheet1 = loadRImage("spritesheet1.png")
  sheet2 = loadRImage("spritesheet2.png")

# You usually want to use a texture packer here. Its job is to place multiple
# images onto a single texture as efficiently as possible. rapid's packer
# doesn't use the most performance nor space efficient algorithm, but it allows
# for dynamic insertion of textures, and so, is suitable for rendering text
# without pre-rendering the whole font
var packer = newRTexturePacker(128, 128)
let
  sprite1 = packer.place [
    # Placing an array allows the packer to sort the textures by size, which
    # allows for more efficient packing. It also binds the texture only once,
    # so it's slightly more performant (although not much).
    sheet1.subimg(0, 0, 8, 8),
    sheet1.subimg(0, 8, 8, 8),
    sheet1.subimg(0, 16, 8, 8),
    sheet1.subimg(0, 24, 8, 8)
  ]
  sprite2 = packer.place [
    sheet2.subimg(0, 0, 16, 16),
    sheet2.subimg(16, 0, 8, 8)
  ]

gfx.loop:
  draw ctx, step:
    ctx.clear(gray(0))

    ctx.begin()
    ctx.texture = packer.texture
    for y in 0..<4:
      for x in 0..<16:
        ctx.rect(x * 8, y * 8, 8, 8, sprite1[y])
    ctx.rect(32, 32, 16, 16, sprite2[0])
    ctx.draw()
  update step:
    discard

```
