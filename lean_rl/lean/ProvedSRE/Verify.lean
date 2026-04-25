import Lean.Data.Json
import ProvedSRE.Soundness
import ProvedSRE.Goals

open Lean (Json FromJson ToJson fromJson? toJson)

namespace SRE

----------------------------------------------------------------
-- JSON instances
----------------------------------------------------------------

private def jObj (pairs : List (String × Json)) : Json := Json.mkObj pairs

deriving instance FromJson, ToJson for Resources

deriving instance FromJson, ToJson for Node

-- PodPhase: serialize as a string ("Pending"/"Running"/"Terminating"/"Failed")
instance : ToJson PodPhase where
  toJson
    | .Pending     => "Pending"
    | .Running     => "Running"
    | .Terminating => "Terminating"
    | .Failed      => "Failed"

instance : FromJson PodPhase where
  fromJson? j := do
    let s ← j.getStr?
    match s with
    | "Pending"     => .ok .Pending
    | "Running"     => .ok .Running
    | "Terminating" => .ok .Terminating
    | "Failed"      => .ok .Failed
    | other         => .error s!"unknown PodPhase: {other}"

----------------------------------------------------------------
-- Manual FromJson for Pod / Deployment so that the identity
-- fields (`name`, `ns`, `resourceVersion`) are optional and
-- default when missing. This preserves back-compat with the
-- pre-API fixtures (t1_ok.json etc).
----------------------------------------------------------------

private def jOptStr (j : Json) (k : String) (dflt : String) : String :=
  match j.getObjValAs? String k with
  | .ok s => s
  | _     => dflt

private def jOptNat (j : Json) (k : String) (dflt : Nat) : Nat :=
  match j.getObjValAs? Nat k with
  | .ok n => n
  | _     => dflt

instance : FromJson Pod where
  fromJson? j := do
    let id          ← j.getObjValAs? Nat "id"
    let deployment  ← j.getObjValAs? Nat "deployment"
    let node        ← j.getObjValAs? Nat "node"
    let image       ← j.getObjValAs? Nat "image"
    let phase       ← j.getObjValAs? PodPhase "phase"
    let request     ← j.getObjValAs? Resources "request"
    return {
      id, deployment, node, image, phase, request,
      name            := jOptStr j "name" "",
      ns              := jOptStr j "ns"   "default",
      resourceVersion := jOptNat j "resourceVersion" 0,
    }

instance : ToJson Pod where
  toJson p := jObj [
    ("id",              toJson p.id),
    ("deployment",      toJson p.deployment),
    ("node",            toJson p.node),
    ("image",           toJson p.image),
    ("phase",           toJson p.phase),
    ("request",         toJson p.request),
    ("name",            toJson p.name),
    ("ns",              toJson p.ns),
    ("resourceVersion", toJson p.resourceVersion),
  ]

instance : FromJson Deployment where
  fromJson? j := do
    let id           ← j.getObjValAs? Nat "id"
    let desired      ← j.getObjValAs? Nat "desired"
    let image        ← j.getObjValAs? Nat "image"
    let request      ← j.getObjValAs? Resources "request"
    let minAvailable ← j.getObjValAs? Nat "minAvailable"
    let antiAffinity ← j.getObjValAs? Bool "antiAffinity"
    return {
      id, desired, image, request, minAvailable, antiAffinity,
      name            := jOptStr j "name" "",
      ns              := jOptStr j "ns"   "default",
      resourceVersion := jOptNat j "resourceVersion" 0,
    }

instance : ToJson Deployment where
  toJson d := jObj [
    ("id",              toJson d.id),
    ("desired",         toJson d.desired),
    ("image",           toJson d.image),
    ("request",         toJson d.request),
    ("minAvailable",    toJson d.minAvailable),
    ("antiAffinity",    toJson d.antiAffinity),
    ("name",            toJson d.name),
    ("ns",              toJson d.ns),
    ("resourceVersion", toJson d.resourceVersion),
  ]

deriving instance FromJson, ToJson for State

----------------------------------------------------------------
-- Action: discriminated union via {"op": "...", ...fields}
----------------------------------------------------------------

instance : ToJson Action where
  toJson
    | .cordon n          => jObj [("op", "cordon"),     ("node", toJson n)]
    | .uncordon n        => jObj [("op", "uncordon"),   ("node", toJson n)]
    | .drain n           => jObj [("op", "drain"),      ("node", toJson n)]
    | .setImage d img    => jObj [("op", "setImage"),   ("deployment", toJson d), ("image", toJson img)]
    | .scale d n         => jObj [("op", "scale"),      ("deployment", toJson d), ("replicas", toJson n)]
    | .rolloutUndo d     => jObj [("op", "rolloutUndo"),("deployment", toJson d)]
    | .deletePod p       => jObj [("op", "deletePod"),  ("pod", toJson p)]
    | .wait k            => jObj [("op", "wait"),       ("ticks", toJson k)]
    | .noop              => jObj [("op", "noop")]

instance : FromJson Action where
  fromJson? j := do
    let op ← j.getObjValAs? String "op"
    match op with
    | "cordon"      => return .cordon      (← j.getObjValAs? Nat "node")
    | "uncordon"    => return .uncordon    (← j.getObjValAs? Nat "node")
    | "drain"       => return .drain       (← j.getObjValAs? Nat "node")
    | "setImage"    => return .setImage    (← j.getObjValAs? Nat "deployment")
                                            (← j.getObjValAs? Nat "image")
    | "scale"       => return .scale       (← j.getObjValAs? Nat "deployment")
                                            (← j.getObjValAs? Nat "replicas")
    | "rolloutUndo" => return .rolloutUndo (← j.getObjValAs? Nat "deployment")
    | "deletePod"   => return .deletePod   (← j.getObjValAs? Nat "pod")
    | "wait"        => return .wait        (← j.getObjValAs? Nat "ticks")
    | "noop"        => return .noop
    | other         => .error s!"unknown action op: {other}"

structure PlanJson where
  actions : List Action
  deriving FromJson, ToJson

structure Request where
  id    : String := ""
  state : State
  plan  : PlanJson
  deriving FromJson

----------------------------------------------------------------
-- API-layer JSON: Kind, ObjectKey, ApiVerb, Reject
----------------------------------------------------------------

instance : ToJson Kind where
  toJson
    | .pod        => "pod"
    | .deployment => "deployment"

instance : FromJson Kind where
  fromJson? j := do
    let s ← j.getStr?
    match s with
    | "pod"        => .ok .pod
    | "deployment" => .ok .deployment
    | other        => .error s!"unknown Kind: {other}"

instance : ToJson ObjectKey where
  toJson k := jObj [
    ("kind", toJson k.kind),
    ("ns",   toJson k.ns),
    ("name", toJson k.name),
  ]

instance : FromJson ObjectKey where
  fromJson? j := do
    let kind ← j.getObjValAs? Kind "kind"
    let name ← j.getObjValAs? String "name"
    return { kind, name, ns := jOptStr j "ns" "default" }

instance : ToJson InvariantKind where
  toJson
    | .pdb          => "pdb"
    | .capacity     => "capacity"
    | .antiAffinity => "antiAffinity"

instance : ToJson ApiVerb where
  toJson
    | .createPod p              =>
        jObj [("op", "createPod"),        ("spec", toJson p)]
    | .createDeployment d       =>
        jObj [("op", "createDeployment"), ("spec", toJson d)]
    | .updateDeployment k rv s  =>
        jObj [("op", "updateDeployment"), ("key", toJson k),
              ("resourceVersion", toJson rv), ("spec", toJson s)]
    | .scaleDeployment k rv n   =>
        jObj [("op", "scaleDeployment"),  ("key", toJson k),
              ("resourceVersion", toJson rv), ("replicas", toJson n)]
    | .deletePodByKey k         =>
        jObj [("op", "deletePodByKey"),   ("key", toJson k)]

instance : FromJson ApiVerb where
  fromJson? j := do
    let op ← j.getObjValAs? String "op"
    match op with
    | "createPod"        =>
        return .createPod (← j.getObjValAs? Pod "spec")
    | "createDeployment" =>
        return .createDeployment (← j.getObjValAs? Deployment "spec")
    | "updateDeployment" =>
        return .updateDeployment
          (← j.getObjValAs? ObjectKey "key")
          (← j.getObjValAs? Nat "resourceVersion")
          (← j.getObjValAs? Deployment "spec")
    | "scaleDeployment"  =>
        return .scaleDeployment
          (← j.getObjValAs? ObjectKey "key")
          (← j.getObjValAs? Nat "resourceVersion")
          (← j.getObjValAs? Nat "replicas")
    | "deletePodByKey"   =>
        return .deletePodByKey (← j.getObjValAs? ObjectKey "key")
    | other              => .error s!"unknown verb op: {other}"

instance : ToJson Reject where
  toJson
    | .parseError msg                       =>
        jObj [("kind", "parseError"), ("msg", toJson msg)]
    | .schemaError path msg                 =>
        jObj [("kind", "schemaError"), ("path", toJson path), ("msg", toJson msg)]
    | .notFound k                           =>
        jObj [("kind", "notFound"), ("key", toJson k)]
    | .conflict have_ got k                 =>
        jObj [("kind", "conflict"), ("have", toJson have_),
              ("got", toJson got), ("key", toJson k)]
    | .forbiddenInvariant ik target reason  =>
        jObj [("kind", "forbiddenInvariant"),
              ("invariant", toJson ik),
              ("target", toJson target),
              ("explanation", toJson reason)]

----------------------------------------------------------------
-- Plan-mode result (existing trajectory verifier)
----------------------------------------------------------------

structure Result where
  id                     : String
  ok                     : Bool
  violation              : Option Json := none
  invariantsClosed       : Nat
  trajectoryLength       : Nat
  violationPrefixLength  : Nat
  error                  : Option String := none

instance : ToJson Result where
  toJson r := jObj [
    ("mode",                  toJson "plan"),
    ("id",                    toJson r.id),
    ("ok",                    toJson r.ok),
    ("violation",             r.violation.getD Json.null),
    ("invariantsClosed",      toJson r.invariantsClosed),
    ("trajectoryLength",      toJson r.trajectoryLength),
    ("violationPrefixLength", toJson r.violationPrefixLength),
    ("error",                 match r.error with | some e => toJson e | none => Json.null)
  ]

private def violationJson (s : State) : Option Json :=
  if !pdbRespected s then
    s.deployments.findSome? (fun d =>
      if availableReplicas s d.id < d.minAvailable then
        some (jObj [("kind", "pdb"), ("target", toJson d.id), ("atTick", toJson s.tick)])
      else none)
  else if !capacityRespected s then
    s.nodes.findSome? (fun n =>
      if !decide (nodeUsage s n.id ≤ n.capacity) then
        some (jObj [("kind", "capacity"), ("target", toJson n.id), ("atTick", toJson s.tick)])
      else none)
  else if !antiAffinityRespected s then
    s.deployments.findSome? (fun d =>
      if d.antiAffinity then
        let pods := s.pods.filter (fun p => p.deployment = d.id ∧ p.phase ≠ .Failed)
        let nodes := pods.map (·.node)
        if nodes.length ≠ nodes.eraseDups.length then
          some (jObj [("kind", "antiAffinity"), ("target", toJson d.id), ("atTick", toJson s.tick)])
        else none
      else none)
  else none

private def walk (s0 : State) (plan : List Action) :
    Option State × Nat × List State :=
  go s0 0 [] plan
where
  go (s : State) (i : Nat) (acc : List State) (rest : List Action) :
      Option State × Nat × List State :=
    let acc' := s :: acc
    match violationJson s with
    | some _ => (some s, i, acc'.reverse)
    | none =>
      match rest with
      | []      => (none, i, acc'.reverse)
      | a :: as => go (step s a) (i + 1) acc' as

private def countClosedInvariants (traj : List State) : Nat :=
  let pdb  := traj.all pdbRespected
  let cap  := traj.all capacityRespected
  let aff  := traj.all antiAffinityRespected
  (if pdb then 1 else 0) + (if cap then 1 else 0) + (if aff then 1 else 0)

def runRequest (req : Request) : Result :=
  let plan := req.plan.actions
  let (vstate?, prefixLen, traj) := walk req.state plan
  match vstate? with
  | some vs =>
      { id                    := req.id,
        ok                    := false,
        violation             := violationJson vs,
        invariantsClosed      := countClosedInvariants traj,
        trajectoryLength      := traj.length,
        violationPrefixLength := prefixLen,
        error                 := none }
  | none =>
      { id                    := req.id,
        ok                    := true,
        violation             := none,
        invariantsClosed      := 3,
        trajectoryLength      := traj.length,
        violationPrefixLength := plan.length,
        error                 := none }

private def errorResult (id : String) (msg : String) : Result :=
  { id                    := id,
    ok                    := false,
    violation             := none,
    invariantsClosed      := 0,
    trajectoryLength      := 0,
    violationPrefixLength := 0,
    error                 := some msg }

----------------------------------------------------------------
-- Verb-mode request/response
----------------------------------------------------------------

structure VerbRequest where
  id    : String := ""
  state : State
  verb  : ApiVerb
  deriving FromJson

/-- Response to a single API verb. `stage` describes where the request
    was rejected (or `"applied"` on success), `reject` carries the
    structured error for the RL loop, and `appliedState` returns the
    new cluster state when the verb was admitted. -/
structure VerbResult where
  id           : String
  ok           : Bool
  stage        : String                -- "wire" | "admission_rejected" | "applied"
  reject       : Option Reject := none
  appliedState : Option State  := none

instance : ToJson VerbResult where
  toJson r := jObj [
    ("mode",         toJson "verb"),
    ("id",           toJson r.id),
    ("ok",           toJson r.ok),
    ("stage",        toJson r.stage),
    ("reject",       match r.reject with
                      | some j => toJson j
                      | none   => Json.null),
    ("appliedState", match r.appliedState with
                      | some s => toJson s
                      | none   => Json.null),
  ]

def runVerbRequest (req : VerbRequest) : VerbResult :=
  match admit req.state req.verb with
  | .error r =>
      { id := req.id, ok := false, stage := "admission_rejected", reject := some r,
        appliedState := none }
  | .ok _ =>
      { id := req.id, ok := true, stage := "applied", reject := none,
        appliedState := some (apply req.state req.verb) }

private def verbWireError (id : String) (msg : String) : VerbResult :=
  { id := id, ok := false, stage := "wire",
    reject := some (.parseError msg), appliedState := none }

----------------------------------------------------------------
-- Goal-mode request/response
----------------------------------------------------------------

instance : ToJson Goal where
  toJson
    | .drainNode n        => jObj [("op", "drainNode"),    ("node", toJson n)]
    | .rolloutImage d img => jObj [("op", "rolloutImage"), ("deployment", toJson d), ("image", toJson img)]
    | .scaleTo d n        => jObj [("op", "scaleTo"),      ("deployment", toJson d), ("replicas", toJson n)]

instance : FromJson Goal where
  fromJson? j := do
    let op ← j.getObjValAs? String "op"
    match op with
    | "drainNode"    => return .drainNode    (← j.getObjValAs? Nat "node")
    | "rolloutImage" => return .rolloutImage (← j.getObjValAs? Nat "deployment")
                                              (← j.getObjValAs? Nat "image")
    | "scaleTo"      => return .scaleTo      (← j.getObjValAs? Nat "deployment")
                                              (← j.getObjValAs? Nat "replicas")
    | other          => .error s!"unknown goal op: {other}"

structure GoalRequest where
  id    : String := ""
  state : State
  goal  : Goal
  deriving FromJson

structure GoalResult where
  id       : String
  ok       : Bool := true
  achieved : Bool

instance : ToJson GoalResult where
  toJson r := jObj [
    ("mode",     toJson "goal"),
    ("id",       toJson r.id),
    ("ok",       toJson r.ok),
    ("achieved", toJson r.achieved),
  ]

def runGoalRequest (req : GoalRequest) : GoalResult :=
  { id := req.id, achieved := goalAchieved req.state req.goal }

private def goalWireError (id : String) (_msg : String) : GoalResult :=
  { id := id, ok := false, achieved := false }

----------------------------------------------------------------
-- Top-level dispatch
----------------------------------------------------------------

private def idFrom (j : Json) : String :=
  (j.getObjValAs? String "id").toOption.getD ""

def handleLine (line : String) : Json :=
  match Json.parse line with
  | .error e => toJson (errorResult "" s!"json parse error: {e}")
  | .ok j    =>
    let mode := (j.getObjValAs? String "mode").toOption.getD "plan"
    match mode with
    | "verb" =>
      match (fromJson? j : Except String VerbRequest) with
      | .error e => toJson (verbWireError (idFrom j) s!"schema error: {e}")
      | .ok req  => toJson (runVerbRequest req)
    | "goal" =>
      match (fromJson? j : Except String GoalRequest) with
      | .error e => toJson (goalWireError (idFrom j) s!"schema error: {e}")
      | .ok req  => toJson (runGoalRequest req)
    | _ =>
      match (fromJson? j : Except String Request) with
      | .error e => toJson (errorResult (idFrom j) s!"schema error: {e}")
      | .ok req  => toJson (runRequest req)

end SRE

partial def runLoop (stdin stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return ()
  let trimmed := line.trimAscii.toString
  if trimmed.isEmpty then
    runLoop stdin stdout
  else
    let result := SRE.handleLine trimmed
    stdout.putStrLn (Lean.Json.compress result)
    stdout.flush
    runLoop stdin stdout

def main : IO Unit := do
  let stdin  ← IO.getStdin
  let stdout ← IO.getStdout
  IO.println "{\"ready\":true}"
  stdout.flush
  runLoop stdin stdout
