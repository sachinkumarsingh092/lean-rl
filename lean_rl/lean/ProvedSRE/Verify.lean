import Lean.Data.Json
import ProvedSRE.Invariants

open Lean (Json FromJson ToJson fromJson? toJson)

namespace SRE

----------------------------------------------------------------
-- JSON instances
----------------------------------------------------------------
-- Plain records: derive automatically.
-- Lean's auto-derive emits {"field": value, ...}, which matches our schema.

deriving instance FromJson, ToJson for Resources

-- Node uses field name `id`, `capacity`, `cordoned` — matches schema.
deriving instance FromJson, ToJson for Node

deriving instance FromJson, ToJson for Deployment

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

deriving instance FromJson, ToJson for Pod
deriving instance FromJson, ToJson for State

----------------------------------------------------------------
-- Action: discriminated union via {"op": "...", ...fields}
-- Manual instance because auto-derive uses constructor-name shape.
----------------------------------------------------------------

private def jObj (pairs : List (String × Json)) : Json := Json.mkObj pairs

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
-- Verification result
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
    ("id",                    toJson r.id),
    ("ok",                    toJson r.ok),
    ("violation",             r.violation.getD Json.null),
    ("invariantsClosed",      toJson r.invariantsClosed),
    ("trajectoryLength",      toJson r.trajectoryLength),
    ("violationPrefixLength", toJson r.violationPrefixLength),
    ("error",                 match r.error with | some e => toJson e | none => Json.null)
  ]

----------------------------------------------------------------
-- Core verification: walk the trajectory, accumulate evidence
----------------------------------------------------------------

private def violationJson (s : State) : Option Json :=
  if !pdbRespected s then
    -- find offending deployment
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

/-- Walk the trajectory action by action.
    Returns (firstViolationStateOpt, prefixLen, traj). -/
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

/-- For each invariant, did it hold at every state in the trajectory? -/
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

----------------------------------------------------------------
-- CLI loop: line in, line out
----------------------------------------------------------------

private def errorResult (id : String) (msg : String) : Result :=
  { id                    := id,
    ok                    := false,
    violation             := none,
    invariantsClosed      := 0,
    trajectoryLength      := 0,
    violationPrefixLength := 0,
    error                 := some msg }

def handleLine (line : String) : Result :=
  match Json.parse line with
  | .error e => errorResult "" s!"json parse error: {e}"
  | .ok j    =>
    match (fromJson? j : Except String Request) with
    | .error e => errorResult (j.getObjValAs? String "id" |>.toOption.getD "") s!"schema error: {e}"
    | .ok req  => runRequest req

end SRE

partial def runLoop (stdin stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return ()
  let trimmed := line.trim
  if trimmed.isEmpty then
    runLoop stdin stdout
  else
    let result := SRE.handleLine trimmed
    stdout.putStrLn (Lean.Json.compress (Lean.toJson result))
    stdout.flush
    runLoop stdin stdout

def main : IO Unit := do
  let stdin  ← IO.getStdin
  let stdout ← IO.getStdout
  IO.println "{\"ready\":true}"
  stdout.flush
  runLoop stdin stdout
