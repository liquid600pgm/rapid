#--
# rapid
# a game engine optimized for rapid prototyping
# copyright (c) 2019, iLiquid
# licensed under the MIT license - see LICENSE file for more information
#--

## This module has everything related to windows.
## **Do not import this directly, it's included by the gfx module.**
##
## You can use ``-d:RGlDebugOutput`` to enable OpenGL debug output.

import times
import unicode

import ../lib/glad/gl
import ../lib/sdl
import ../debug
import ../shutdown
import window/window_enums
import opengl

export window_enums
export times.cpuTime
export unicode.Rune

#--
# Initialization
#--

proc onGlDebug(source, kind: GLenum, id: GLuint, severity: GLenum,
               length: GLsizei, msgPtr: ptr GLchar,
               userParam: pointer) {.stdcall, used.} =
  var msg = newString(length)
  copyMem(msg[0].unsafeAddr, msgPtr, length)
  let kindStr =
    case kind.int
    of 0x824c: "error"
    of 0x824d: "deprecated behavior"
    of 0x824e: "undefined behavior"
    of 0x824f: "portability"
    of 0x8250: "performance"
    of 0x8251: "marker"
    of 0x8252: "push group"
    of 0x8253: "pop group"
    of 0x8254: "other"
    else: "<unknown type>"
  case severity.int
  of 0x9146: error("(GL) ", kindStr, ": ", msg)
  of 0x9147, 0x9148: warn("(GL) ", kindStr, ": ", msg)
  of 0x826B: info("(GL) ", kindStr, ": ", msg)
  else: discard
  when defined(glDebugBacktrace):
    writeStackTrace()

proc initGl(win: sdl.Window) =
  doAssert gladLoadGL(sdl.GL_GetProcAddress), "OpenGL could not be loaded"
  when defined(RGlDebugOutput):
    if GLAD_GL_KHR_debug:
      glEnable(GL_DEBUG_OUTPUT)
      glDebugMessageCallback(onGlDebug, nil)
    else:
      warn("KHR_debug is not present. OpenGL debug info will not be available")
  if not GLAD_GL_ARB_separate_shader_objects:
    error("ARB_separate_shader_objects is not available. ",
          "Please update your graphics drivers")
    quit(QuitFailure)
  return ieOK

#--
# Window building
#--

type
  #--
  # Building
  #--
  WindowOptions = object
    width, height: Natural
    title: string
    resizable, visible, decorated, focused, floating, maximized: bool
    antialiasLevel: int
  #--
  # Events
  #--
  RModKeys* = set[RModKey]
  RCharProc* = proc (rune: Rune, mods: RModKeys)
  RCursorEnterProc* = proc ()
  RCursorMoveProc* = proc (x, y: float)
  RFilesDroppedProc* = proc (filenames: seq[string])
  RKeyProc* = proc (key: RKeycode, scancode: RScancode, mods: RModKeys)
  RMouseProc* = proc (button: RMouseButton, mods: RModKeys)
  RScrollProc* = proc (x, y: float)
  RCloseProc* = proc (): bool
  RResizeProc* = proc (width, height: Natural)
  WindowCallbacks = object
    onChar: seq[RCharProc]
    onCursorEnter, onCursorLeave: seq[RCursorEnterProc]
    onCursorMove: seq[RCursorMoveProc]
    onFilesDropped: seq[RFilesDroppedProc]
    onKeyPress, onKeyRelease, onKeyRepeat: seq[RKeyProc]
    onMousePress, onMouseRelease: seq[RMouseProc]
    onScroll: seq[RScrollProc]
    onClose: seq[RCloseProc]
    onResize: seq[RResizeProc]
  #--
  # Windows
  #--
  RWindowObj = object
    handle: ptr sdl.Window
    callbacks: WindowCallbacks
  RWindow* = ref RWindowObj

using
  wopt: WindowOptions

proc initRWindow*(): WindowOptions =
  ## Initializes a new ``RWindow``.
  once:
    if sdl.initSubSystem(0x20 #[SDL_INIT_VIDEO]#) != 0:
      raise newException(SDLError, $sdl.getError())
  result = WindowOptions(
    width: 800, height: 600,
    title: "rapid",
    resizable: true, visible: true,
    decorated: true, focused: true,
    floating: false, maximized: false
  )

proc size*(wopt; width, height: int): WindowOptions =
  ## Builds the window with the specified dimensions.
  result = wopt
  result.width = width
  result.height = height

proc title*(wopt; title: string): WindowOptions =
  ## Builds the window with the specified title.
  result = wopt
  result.title = title

template builderBool(param: untyped, doc: untyped): untyped {.dirty.} =
  proc param*(wopt; param: bool): WindowOptions =
    doc
    result = wopt
    result.param = param
builderBool(resizable):
  ## Defines if the built window will be resizable.
builderBool(visible):
  ## Defines if the built window will be visible.
builderBool(decorated):
  ## Defines if the built window will be decorated.
builderBool(focused):
  ## Defines if the built window will be focused.
builderBool(floating):
  ## Defines if the built window will float (stay on top of other windows).
builderBool(maximized):
  ## Defines if the built window will be maximized.

proc antialiasLevel*(wopt; level: int): WindowOptions =
  ## Builds the window with the specified antialiasing level.
  result = wopt
  result.antialiasLevel = level

converter toModsSet(mods: int32): RModKeys =
  result = {}
  const
    Shifts = KMOD_LSHIFT or KMOD_RSHIFT
    Ctrls = KMOD_LCTRL or KMOD_RCTRL
    Alts = KMOD_LALT or KMOD_RALT
    Guis = KMOD_LGUI or KMOD_RGUI
  if (mods and Shifts) > 0: result.incl(rmkShift)
  if (mods and Ctrls) > 0: result.incl(rmkCtrl)
  if (mods and Alts) > 0: result.incl(rmkAlt)
  if (mods and Guis) > 0: result.incl(rmkGui)
  if (mods and KMOD_NUM) > 0: result.incl(rmkNumLock)
  if (mods and KMOD_CAPS) > 0: result.incl(rmkCapsLock)
  if (mods and KMOD_MODE) > 0: result.incl(rmkMode)

proc open*(wopt): RWindow =
  ## Builds a window using the specified options and opens it.
  result = RWindow()

  let
    mon = glfw.getPrimaryMonitor()
    mode = glfw.getVideoMode(mon)

  glfw.windowHint(glfw.hRedBits, mode.redBits)
  glfw.windowHint(glfw.hGreenBits, mode.greenBits)
  glfw.windowHint(glfw.hBlueBits, mode.blueBits)
  glfw.windowHint(glfw.hAlphaBits, 8)
  glfw.windowHint(glfw.hDepthBits, 24)
  glfw.windowHint(glfw.hStencilBits, 8)
  if wopt.antialiasLevel != 0:
    glfw.windowHint(glfw.hSamples, wopt.antialiasLevel.int32)

  glfw.windowHint(glfw.hResizable, wopt.resizable.int32)
  glfw.windowHint(glfw.hVisible, false.int32)
  glfw.windowHint(glfw.hDecorated, wopt.decorated.int32)
  glfw.windowHint(glfw.hFocused, wopt.focused.int32)
  glfw.windowHint(glfw.hFloating, wopt.floating.int32)
  glfw.windowHint(glfw.hMaximized, wopt.maximized.int32)

  glfw.windowHint(glfw.hContextVersionMajor, 3)
  glfw.windowHint(glfw.hContextVersionMinor, 3)
  glfw.windowHint(glfw.hOpenglProfile, glfw.opCoreProfile.int32)
  glfw.windowHint(glfw.hOpenglDebugContext, 1)
  const
    PosCentered = 0x2FFF0000.cint
  result.handle = createWindow(wopt.title, PosCentered, PosCentered,
                               wopt.width.cint, wopt.height.cint, 0)
  if currentGlc.isNil:
    result.context.makeCurrent()

  # center the window
  glfw.setWindowPos(result.handle,
    int32(mode.width / 2 - wopt.width / 2),
    int32(mode.height / 2 - wopt.height / 2))

  if wopt.visible: glfw.showWindow(result.handle)

  once:
    let status = initGl(result.handle)
    if status != ieOK:
      raise newException(GLError, $status)

  glfw.setWindowUserPointer(result.handle, cast[pointer](result))
  glfwCallbacks(result)

proc destroy*(win: RWindow) =
  ## Destroys a window.
  glfw.destroyWindow(win.handle)

#--
# Window attributes
#--

proc close*(win: var RWindow) =
  ## Tells the window it should close. This doesn't immediately close the window;
  ## the application might prevent the window from being closed.
  glfw.setWindowShouldClose(win.handle, 1)

proc pos*(win: RWindow): tuple[x, y: int] =
  var x, y: int32
  glfw.getWindowPos(win.handle, addr x, addr y)
  result = (int x, int y)
proc x*(win: RWindow): int = win.pos().x
proc y*(win: RWindow): int = win.pos().y
proc `pos=`*(win: var RWindow, pos: tuple[x, y: int]) =
  glfw.setWindowSize(win.handle, int32 pos.x, int32 pos.y)
proc `x=`*(win: var RWindow, x: int) = win.pos = (x, win.x)
proc `y=`*(win: var RWindow, y: int) = win.pos = (y, win.y)

type
  IntDimensions* = tuple[width, height: int]
proc size*(win: RWindow): IntDimensions =
  var w, h: int32
  glfw.getWindowSize(win.handle, addr w, addr h)
  result = (int w, int h)
proc width*(win: RWindow): int = win.size().width
proc height*(win: RWindow): int = win.size().height
proc `size=`*(win: var RWindow, size: IntDimensions) =
  glfw.setWindowSize(win.handle, int32 size.width, int32 size.height)
proc `width=`*(win: var RWindow, width: int) = win.size = (width, win.width)
proc `height=`*(win: var RWindow, height: int) = win.size = (win.width, height)
proc limitSize*(win: var RWindow, min, max: IntDimensions) =
  glfw.setWindowSizeLimits(win.handle,
    int32 min.width, int32 min.height, int32 max.width, int32 max.height)

proc fbSize*(win: RWindow): IntDimensions =
  var w, h: int32
  glfw.getFramebufferSize(win.handle, addr w, addr h)
  result = (int w, int h)

proc iconify*(win: var RWindow) = glfw.iconifyWindow(win.handle)
proc restore*(win: var RWindow) = glfw.restoreWindow(win.handle)
proc maximize*(win: var RWindow) = glfw.maximizeWindow(win.handle)
proc show*(win: var RWindow) = glfw.showWindow(win.handle)
proc hide*(win: var RWindow) = glfw.hideWindow(win.handle)
proc focus*(win: var RWindow) = glfw.focusWindow(win.handle)

proc focused*(win: RWindow): bool =
  result = bool glfw.getWindowAttrib(win.handle, glfw.hFocused)
proc iconified*(win: RWindow): bool =
  result = bool glfw.getWindowAttrib(win.handle, glfw.Iconified)
proc maximized*(win: RWindow): bool =
  result = bool glfw.getWindowAttrib(win.handle, glfw.hMaximized)
proc visible*(win: RWindow): bool =
  result = bool glfw.getWindowAttrib(win.handle, glfw.hVisible)
proc decorated*(win: RWindow): bool =
  result = bool glfw.getWindowAttrib(win.handle, glfw.hDecorated)
proc floating*(win: RWindow): bool =
  result = bool glfw.getWindowAttrib(win.handle, glfw.hFloating)

#~~
# Input
#~~

template callbackProc(name, T, doc: untyped): untyped {.dirty.} =
  proc name*(win: RWindow, callback: T) =
    doc
    win.callbacks.name.add(callback)
callbackProc(onChar, RCharProc):
  ## Adds a callback executed when a character is typed on the keyboard.
callbackProc(onCursorEnter, RCursorEnterProc):
  ## Adds a callback executed when the cursor enters the window.
callbackProc(onCursorLeave, RCursorEnterProc):
  ## Adds a callback executed when the cursor leaves the window.
callbackProc(onCursorMove, RCursorMoveProc):
  ## Adds a callback executed when the cursor moves in the window.
callbackProc(onFilesDropped, RFilesDroppedProc):
  ## Adds a callback executed when files are dropped onto the window.
callbackProc(onKeyPress, RKeyProc):
  ## Adds a callback executed when a key is pressed on the keyboard.
callbackProc(onKeyRelease, RKeyProc):
  ## Adds a callback executed when a key is released on the keyboard.
callbackProc(onKeyRepeat, RKeyProc):
  ## Adds a callback executed when a repeat is triggered by holding down a key \
  ## on the keyboard.
callbackProc(onMousePress, RMouseProc):
  ## Adds a callback executed when a mouse button is pressed.
callbackProc(onMouseRelease, RMouseProc):
  ## Adds a callback executed when a mouse button is released.
callbackProc(onScroll, RScrollProc):
  ## Adds a callback executed when the scroll wheel is moved.
callbackProc(onClose, RCloseProc):
  ## Adds a callback executed when there's an attempt to close the window.
  ## The callback should return ``true`` if the window is to be closed, or \
  ## ``false`` if closing should be canceled.
callbackProc(onResize, RResizeProc):
  ## Adds a callback executed when the window is resized.

proc key*(win: RWindow, key: glfw.Key): glfw.KeyAction =
  glfw.KeyAction(glfw.getKey(win.handle, int32(key)))

proc mouseButton*(win: RWindow, btn: glfw.MouseButton): glfw.KeyAction =
  glfw.KeyAction(glfw.getMouseButton(win.handle, int32(btn)))

proc mousePos*(win: RWindow): tuple[x, y: float] =
  var x, y: float64
  glfw.getCursorPos(win.handle, addr x, addr y)
  result = (x, y)
proc mouseX*(win: RWindow): float = win.mousePos.x
proc mouseY*(win: RWindow): float = win.mousePos.y

proc `mousePos=`*(win: var RWindow, x, y: float) =
  glfw.setCursorPos(win.handle, float64 x, float64 y)

proc time*(): float =
  ## Returns the current process's time.
  ## This should be used instead of ``cpuTime()``, because it properly deals \
  ## with the game loop.
  result = glfw.getTime().float

proc makeCurrent*(win: RWindow) =
  ## Makes the window the current one for drawing actions.
  win.context.makeCurrent()

template with*(win: RWindow, body: untyped) =
  ## Does the specified actions on the window's contents.
  ## ``render`` should be preferred over this.
  let prevGlc = currentGlc
  win.makeCurrent()
  body
  prevGlc.makeCurrent()
