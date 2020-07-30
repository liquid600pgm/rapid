## ``ecs`` macro for creating ECS worlds.

import std/hashes
import std/macros
import std/sets
import std/sugar
import std/options
import std/tables

import common

type
  Endpoint = object
    impl: NimNode
    signature: NimNode
  EndpointImpl = object
    sysName: string
    impl: SystemImpl

macro useSyms(sym: varargs[typed]) =
  ## Shuts the compiler up about unused symbols.
  ## ``discard`` can't be used for this as it raises an error.

proc useSystems(systemList: NimNode): NimNode =
  ## Generates a ``useSyms`` call to shut up the compiler about unused
  ## imports.

  result = newCall(bindSym"useSyms")
  for sysName in systemList:
    if sysName.strVal notin ecsSystems:
      error("undeclared system " & sysName.strVal, sysName)
    let procName = ident("system:" & sysName.strVal)
    procName.copyLineInfo(sysName)
    result.add(procName)

proc genHasEnum(typeName, componentList: NimNode): NimNode =
  ## Generates the EntityHas enum from a list of components.

  result = newTree(nnkEnumTy, newEmptyNode())

  for comp in componentList:
    result.add(comp)

proc genWorldObject(typeName, componentList, entityHas: NimNode): NimNode =
  ## Generates the @world object from a list of components.

  var fields = newNimNode(nnkRecList)

  let hasSet = newTree(nnkBracketExpr, ident"set", entityHas)
  fields.add(newIdentDefs(ident"entityComponents",
                          newTree(nnkBracketExpr, ident"seq", hasSet)))

  for comp in componentList:
    fields.add(newIdentDefs(ident("comp" & comp.repr),
                            newTree(nnkBracketExpr, bindSym"seq", comp)))

  result = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), fields)

proc genTypeToHasEnumProc(entityHas, componentList: NimNode): NimNode =
  ## Generates a proc for converting ``type`` to ``EntityHas``.

  result = newProc(name = ident"toHasEnum",
                   params = [entityHas, newIdentDefs(ident"T", bindSym"type")])

  var whenStmt = newTree(nnkWhenStmt)
  for comp in componentList:
    let branch = newTree(nnkElifBranch, infix(ident"T", "is", comp),
                         newAssignment(ident"result",
                                       newDotExpr(entityHas, comp)))
    whenStmt.add(branch)
  whenStmt.add(newTree(nnkElse,
                       newTree(nnkPragma,
                               newColonExpr(ident"error",
                                            newLit("invalid component type")))))

  result.body.add(whenStmt)

proc genGetComponentProcs(worldType, entityType,
                          componentList: NimNode): NimNode =
  ## Generates the ``component`` and ``mcomponent`` procs for retrieving
  ## entities' components.

  result = newStmtList()

  proc make(name: string, worldTy, returnTy: NimNode): NimNode =
    result = newProc(name = name.ident,
                     params = [returnTy,
                               newIdentDefs(ident"world", worldTy),
                               newIdentDefs(ident"entity", entityType)])
    result[2] = newTree(nnkGenericParams,
                        newIdentDefs(ident"T", newEmptyNode()))
    result.addPragma(ident"used")

    result.body.add quote do:
      assert T.toHasEnum in world.entityComponents[EntityBase(entity)],
        "entity must have the given component"

    var whenStmt = newNimNode(nnkWhenStmt)
    for comp in componentList:
      var branch = newTree(nnkElifBranch, infix(ident"T", "is", comp))
      let
        components = newDotExpr(ident"world", ident("comp" & comp.repr))
        index = newDotExpr(ident"entity", bindSym"EntityBase")
        component = newTree(nnkBracketExpr, components, index)
        assignment = newAssignment(ident"result", component)
      branch.add(assignment)
      whenStmt.add(branch)
    result.body.add(whenStmt)

  result.add(make("component", worldType, ident"T"),
             make("mcomponent", newTree(nnkVarTy, worldType),
                  newTree(nnkVarTy, ident"T")))

proc genBaseSysInterface(sysInterface: NimNode,
                         worldType: NimNode): Table[string, seq[Endpoint]] =
  ## Reads the system interface list and assembles base AST for endpoints.

  for signature in sysInterface:
    signature.expectKind(nnkProcDef)
    if signature.params[0].kind != nnkEmpty:
      error("endpoints must not return anything", signature.params[0])

    var impl = copy(signature)
    impl.params.insert(1, newIdentDefs(ident"world",
                                       newTree(nnkVarTy, worldType)))
    impl.body =
      if impl.body.kind == nnkEmpty: newStmtList()
      else: newStmtList(impl.body)

    let strName = impl.name.repr
    if strName notin result:
      result[strName] = @[]
    result[strName].add(Endpoint(impl: impl, signature: signature))

proc checkRequiredComponents(systemList, componentList: NimNode) =
  ## Checks whether all components required by systems are present in
  ## the ECS world.

  var components = collect(initHashSet):
    for nameIdent in componentList:
      {nameIdent.repr}

  for sysNameIdent in systemList:
    let
      sysName = sysNameIdent.strVal
      sys = ecsSystems[sysName]
      requireSet = collect(initHashSet):
        for require in sys.requires:
          let ty = require[^2].extractVarType
          if not (ty.eqIdent("@world") or ty.eqIdent("@entity")):
            {ty.repr}
    if not (requireSet <= components):
      let missing = requireSet - components
      var missingStr = ""
      for name in missing:
        if missingStr.len > 0: missingStr.add(", ")
        missingStr.add(name)
      error("ECS does not have all components required by " & sysName & ". " &
            "missing: {" & missingStr & "}", sysNameIdent)

proc getAllImplementations(systemList: NimNode): seq[EndpointImpl] =
  ## Looks up systems and flattens all of their endpoint implementations to a
  ## single list. Raises a compile error if a system can't be found.

  for sysNameIdent in systemList:
    let
      sysName = sysNameIdent.strVal
      sys = ecsSystems[sysName]
    for impl in sys.implements:
      result.add(EndpointImpl(sysName: sysName, impl: impl))

proc obliterateTypedesc(ty: NimNode): NimNode =
  ## Obliterates ``typeDesc[T]`` nodes and returns the ``T`` part.

  result = ty.getImpl[1]

proc flattenParams(params: NimNode): seq[NimNode] =
  ## Flattens a parameter list (of nnkIdentDefs) to a seq of their types.

  params.expectKind({nnkGenericParams, nnkFormalParams})
  let startIndex =
    if params.kind == nnkFormalParams: 1
    else: 0
  for defs in params[startIndex..^1]:
    let ty = defs[^2]
    for _ in defs[0..^3]:
      result.add(ty)

proc sameParams(a, b: NimNode): bool =
  ## Checks if two param list nodes contain params of the same type.

  result = true
  if a.kind != b.kind: return false
  if a.kind == nnkEmpty: return true

  let
    # XXX: slow. cache this!
    flatA = a.flattenParams
    flatB = b.flattenParams
  if flatA.len != flatB.len: return false

  let startIndex =
    if a.kind == nnkFormalParams: 1
    else: 0
  for index in startIndex..<a.len:
    let
      aType = flatA[index].obliterateTypedesc
      bType = flatB[index].obliterateTypedesc
    if not sameType(aType, bType): return false

proc stripExportMarker(name: NimNode): NimNode =
  ## Strips the * export marker off a node.
  if name.kind == nnkPostfix: name[1]
  else: name

proc sameSignature(a, b: NimNode): bool =
  ## Checks if the signatures of procs ``a`` and ``b`` match.

  a.expectKind(nnkProcDef)
  b.expectKind(nnkProcDef)

  if a.name != b.name: return false
  if not sameParams(a[2], b[2]): return false  # generic params
  if not sameParams(a[3], b[3]): return false  # formal params
  result = true

proc findMatchingEndpoint(endpoints: Table[string, seq[Endpoint]],
                          signature: NimNode): Option[Endpoint] =
  ## Finds an endpoint that matches the signature of the proc ``signature``.
  ## Returns ``none`` if there is no matching endpoint.

  let strName = signature.name.strVal
  if strName in endpoints:
    for endpoint in endpoints[strName]:
      if sameSignature(endpoint.signature, signature):
        return some(endpoint)

proc genEntityLoop(sys: SystemInfo, endpoint: Endpoint,
                   implSym, entityType, entityHasType: NimNode): NimNode =
  ## Generates a loop over all entities that executes the given system's
  ## endpoint implementation.

  var body = newStmtList()
  result = newTree(nnkForStmt, ident"index", ident"hasSet",
                   newDotExpr(ident"world", ident"entityComponents"),
                   body)

  var requireHasSet = newNimNode(nnkCurly)
  for req in sys.requires:
    let
      ty = req[^2].extractVarType
      hasValue = newDotExpr(entityHasType, ty)
    requireHasSet.add(hasValue)

  var call = newCall(implSym)
  for defs in endpoint.signature.params[1..^1]:
    for name in defs[0..^3]:
      call.add(name)
  let entity = newCall(entityType, ident"index")
  for req in sys.requires:
    let
      isVar = req[^2].kind == nnkVarTy
      ty = req[^2].extractVarType
      componentProc =
        if isVar: ident"mcomponent"
        else: ident"component"
      componentInst = newTree(nnkBracketExpr, componentProc, ty)
      componentCall = newCall(componentInst, ident"world", entity)
    call.add(componentCall)

  let
    cond = infix(requireHasSet, "<=", ident"hasSet")
    ifStmt = newIfStmt({cond: call})
  body.add(ifStmt)

proc addImplsToEndpoints(impls: seq[EndpointImpl],
                         endpoints: Table[string, seq[Endpoint]],
                         entityType, worldType, entityHasType: NimNode) =
  ## Appends all implementations with signatures matching those of endpoints to
  ## respective endpoints.

  for endpointImpl in impls:
    let
      sys = ecsSystems[endpointImpl.sysName]
      impl = endpointImpl.impl
      maybeEndpoint = findMatchingEndpoint(endpoints, impl.abstract)
    if maybeEndpoint.isSome:
      let endpoint = maybeEndpoint.get
      var concreteImpl =
        if impl.concrete != nil: impl.concrete
        else: getConcrete(impl.abstract, sys, entityType, worldType)
      let implSym = genSym(nskProc,
                            endpointImpl.sysName & "_" &
                            concreteImpl.name.repr)
      concreteImpl.name = implSym
      concreteImpl.addPragma(ident"inline")
      endpoint.impl.body.add(concreteImpl)
      endpoint.impl.body.add(genEntityLoop(sys, endpoint, implSym,
                                           entityType, entityHasType))

macro ecs*(body: untyped{nkStmtList}) =
  ## Generates an ECS world.
  ## The body must contain the following:
  ##
  ## - a type section with declaration for types ``@world`` and ``@entity``,
  ##   see example for details
  ## - a ``components`` block, where each statement is a component type
  ## - a ``systemInterface`` block, defining all the procedures that systems can
  ##   implement.
  ## - a ``systems`` block, where each statement is a system name.
  ##
  ## Systems' endpoints get executed sequentially in their respective world
  ## procedures.
  ##
  ## **Remarks:**
  ##
  ## ``systemInterface`` procs can have a body. Procs implemented by systems are
  ## simply appended to the existing body, so it's possible to define something
  ## to do *before* all systems execute. This feature also enables docgen for
  ## generated procedures (see example below).
  ## Right now there is no way of specifying actions to do *after* systems
  ## execute. Syntax for that will probably be added in the future, but time
  ## will tell if such a feature is needed at all.
  runnableExamples:
    import rapid/ecs/components/basic
    import rapid/ecs/physics

    ecs:
      type
        Entity* = @entity
        World* = @world

      components:
        Position
        Size
        PhysicsBody
        Gravity

      systemInterface:
        proc update*() =
          ## Ticks all entities in the world once.
          echo "updating!"  # will execute before system updates
          # ← system updates will occur here
          # usually, there's no need to add any extra logic to interface procs,
          # so unless it's absolutely necessary, don't do it.
          # use entities, components, and systems instead

      systems:
        applyGravity
        tickPhysics

  result = newStmtList()

  var
    worldTypeName, entityTypeName: NimNode
    componentList, systemList, systemInterfaceList: NimNode

  for stmt in body:
    stmt.expectKind({nnkTypeSection, nnkCall})
    case stmt.kind
    of nnkTypeSection:
      for typedef in stmt:
        typedef[1].expectKind(nnkEmpty)
        typedef[2].expectKind(nnkPrefix)
        typedef[2][0].expectIdent("@")
        typedef[2][1].expectKind(nnkIdent)
        let what = typedef[2][1]
        if what.eqIdent("world"):
          worldTypeName = typedef[0]
        elif what.eqIdent("entity"):
          entityTypeName = typedef[0]
    of nnkCall:
      stmt[0].expectKind(nnkIdent)
      stmt[1].expectKind(nnkStmtList)
      if stmt[0].eqIdent("components"):
        componentList = stmt[1]
      elif stmt[0].eqIdent("systems"):
        systemList = stmt[1]
      elif stmt[0].eqIdent("systemInterface"):
        systemInterfaceList = stmt[1]
    else: assert false, "unreachable"

  if worldTypeName == nil: error("missing @world type", body)
  if entityTypeName == nil: error("missing @entity type", body)
  if componentList == nil: error("missing components list", body)
  if systemList == nil: error("missing systems list", body)
  if systemInterfaceList == nil: error("missing systemInterface list", body)

  let
    worldType = stripExportMarker(worldTypeName)
    entityType = stripExportMarker(entityTypeName)

  result.add(useSystems(systemList))

  let
    entityHasName = ident(entityType.strVal & "Has")
    entityHasEnum = genHasEnum(entityType, componentList)
    worldObject = genWorldObject(worldType, componentList, entityHasName)
    typeToHasEnumProc = genTypeToHasEnumProc(entityHasName, componentList)
    getComponentProcs = genGetComponentProcs(worldType, entityType,
                                             componentList)

  result.add quote do:
    type
      `entityTypeName` = distinct EntityBase
      `entityHasName` {.pure.} = `entityHasEnum`
      `worldTypeName` = `worldObject`

    `typeToHasEnumProc`
    `getComponentProcs`

  checkRequiredComponents(systemList, componentList)
  var endpointTable = genBaseSysInterface(systemInterfaceList, worldType)
  let impls = getAllImplementations(systemList)
  addImplsToEndpoints(impls, endpointTable,
                      entityType, worldType, entityHasName)

  for _, endpoints in endpointTable:
    for endpoint in endpoints:
      result.add(endpoint.impl)

  echo result.repr

when isMainModule:
  import glm/vec

  import components/basic
  import physics

  ecs:
    type
      Entity* = @entity
      World* = @world

    components:
      Position
      Size
      PhysicsBody
      Gravity

    systemInterface:
      proc update*() =
        ## Ticks all entities in the world once.

    systems:
      applyGravity
      tickPhysics
