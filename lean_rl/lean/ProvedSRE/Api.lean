import ProvedSRE.Invariants

namespace SRE

/-! ## K8s-style API layer

A small slice of the Kubernetes REST surface for Pods and Deployments.
The LLM emits one `ApiVerb` as JSON; the verifier runs `admit` then `apply`
and either commits the new state or returns a structured `Reject`.

Soundness is proved separately in `ProvedSRE.Soundness` for the PDB
invariant: `admit s v = .ok () → pdbRespected (apply s v) = true`.
-/

inductive Kind | pod | deployment
  deriving DecidableEq, Repr

structure ObjectKey where
  kind : Kind
  ns   : String := "default"
  name : String
  deriving DecidableEq, Repr

inductive ApiVerb
  | createPod         (spec : Pod)
  | createDeployment  (spec : Deployment)
  | updateDeployment  (key : ObjectKey) (rv : Nat) (spec : Deployment)
  | scaleDeployment   (key : ObjectKey) (rv : Nat) (replicas : Nat)
  | deletePodByKey    (key : ObjectKey)
  deriving Repr

inductive Reject
  | parseError         (msg : String)
  | schemaError        (path : String) (msg : String)
  | notFound           (key : ObjectKey)
  | conflict           (have_ : Nat) (got : Nat) (key : ObjectKey)
  | forbiddenInvariant (kind : InvariantKind) (target : String) (explanation : String)
  deriving Repr

/-! ### Helpers -/

def findDeployment (s : State) (k : ObjectKey) : Option Deployment :=
  s.deployments.find? (fun d => d.ns = k.ns ∧ d.name = k.name)

def findPod (s : State) (k : ObjectKey) : Option Pod :=
  s.pods.find? (fun p => p.ns = k.ns ∧ p.name = k.name)

/-- Monotonic resourceVersion: strictly greater than every existing object. -/
def nextRV (s : State) : Nat :=
  let podRVs := s.pods.map (·.resourceVersion)
  let depRVs := s.deployments.map (·.resourceVersion)
  ((podRVs ++ depRVs).foldl max 0) + 1

def verbTarget : ApiVerb → String
  | .createPod p              => s!"{p.ns}/{p.name}"
  | .createDeployment d       => s!"{d.ns}/{d.name}"
  | .updateDeployment k _ _   => s!"{k.ns}/{k.name}"
  | .scaleDeployment  k _ _   => s!"{k.ns}/{k.name}"
  | .deletePodByKey   k       => s!"{k.ns}/{k.name}"

/-- Remove the first `k` Running pods belonging to deployment `dId`,
    preserving order of the remaining pods. -/
def removeNRunning : List Pod → DeploymentId → Nat → List Pod
  | [],      _,   _     => []
  | p :: ps, _,   0     => p :: ps
  | p :: ps, dId, k + 1 =>
      if p.deployment = dId ∧ p.phase = .Running
      then removeNRunning ps dId k
      else p :: removeNRunning ps dId (k + 1)

/-- Next free PodId: max existing id + 1 (1 if no pods). -/
def nextPodId (s : State) : PodId :=
  (s.pods.map (·.id)).foldl max 0 + 1

/-- Pick a node for a new pod of deployment `d`. Prefer a non-cordoned node
    not already hosting a live pod of `d` when `d.antiAffinity = true`.
    Falls back to the first non-cordoned node, then any node, then 0. -/
def pickNode (s : State) (d : Deployment) : NodeId :=
  let busy : List NodeId :=
    if d.antiAffinity then
      (s.pods.filter (fun p => p.deployment = d.id ∧ p.phase ≠ .Failed)).map (·.node)
    else []
  let cands := s.nodes.filter (fun n => !n.cordoned ∧ !busy.contains n.id)
  match cands with
  | n :: _ => n.id
  | []     =>
      match s.nodes.filter (fun n => !n.cordoned) with
      | n :: _ => n.id
      | []     =>
          match s.nodes with
          | n :: _ => n.id
          | []     => 0

/-- Append one Pending pod for deployment `d`, deterministically. -/
def addOnePod (s : State) (d : Deployment) : State :=
  let newId := nextPodId s
  let p : Pod := {
    id              := newId,
    deployment      := d.id,
    node            := pickNode s d,
    image           := d.image,
    phase           := .Pending,
    request         := d.request,
    name            := s!"{d.name}-{newId}",
    ns              := d.ns,
    resourceVersion := nextRV s,
  }
  { s with pods := s.pods ++ [p] }

/-- Append `k` Pending pods for deployment `d`. -/
def addNPods : State → Deployment → Nat → State
  | s, _, 0     => s
  | s, d, k + 1 => addNPods (addOnePod s d) d k

/-! ### apply

Pure, deterministic state transition for a single verb. Bumps
`resourceVersion` on touched objects. Scale-down removes excess Running
pods synchronously (we have no controller layer in v1). -/

def apply (s : State) : ApiVerb → State
  | .createPod p =>
      let p' := { p with resourceVersion := nextRV s }
      { s with pods := s.pods ++ [p'] }
  | .createDeployment d =>
      let d' := { d with resourceVersion := nextRV s }
      { s with deployments := s.deployments ++ [d'] }
  | .updateDeployment k _rv newSpec =>
      { s with deployments := s.deployments.map fun e =>
          if e.ns = k.ns ∧ e.name = k.name
          then { newSpec with id := e.id, resourceVersion := e.resourceVersion + 1 }
          else e }
  | .scaleDeployment k _rv n =>
      match findDeployment s k with
      | none   => s
      | some d =>
          let s1 : State :=
            { s with deployments := s.deployments.map fun e =>
                if e.ns = k.ns ∧ e.name = k.name
                then { e with desired := n, resourceVersion := e.resourceVersion + 1 }
                else e }
          let runCount :=
            (s1.pods.filter (fun p => p.deployment = d.id ∧ p.phase = .Running)).length
          if n ≥ runCount then
            -- Scale up: append (n - runCount) Pending pods, deterministically
            -- placed via `pickNode`. This matches kwok's controller observation
            -- after re-projection (count + per-node placement) and lets
            -- postCheck reject scale-ups that would violate capacity / anti-affinity.
            addNPods s1 d (n - runCount)
          else
            -- Scale down: drop the first (runCount - n) Running pods.
            { s1 with pods := removeNRunning s1.pods d.id (runCount - n) }
  | .deletePodByKey k =>
      { s with pods := s.pods.filter (fun p => ¬(p.ns = k.ns ∧ p.name = k.name)) }

/-! ### admit

Two-stage gate: pre-checks (existence, resourceVersion conflicts) followed
by post-state invariant verification. The post-state check happens by
running `apply` once and re-evaluating each invariant. This is sufficient
for soundness and matches how a real K8s admission webhook would dry-run
a request. -/

def preCheck (s : State) : ApiVerb → Except Reject Unit
  | .createPod _        => .ok ()
  | .createDeployment _ => .ok ()
  | .updateDeployment k rv _ =>
      match findDeployment s k with
      | none   => .error (.notFound k)
      | some d =>
          if d.resourceVersion = rv then .ok ()
          else .error (.conflict d.resourceVersion rv k)
  | .scaleDeployment k rv _ =>
      match findDeployment s k with
      | none   => .error (.notFound k)
      | some d =>
          if d.resourceVersion = rv then .ok ()
          else .error (.conflict d.resourceVersion rv k)
  | .deletePodByKey k =>
      match findPod s k with
      | none   => .error (.notFound k)
      | some _ => .ok ()

def invariantReason : InvariantKind → String
  | .pdb          => "would violate PodDisruptionBudget minAvailable"
  | .capacity     => "would exceed node capacity"
  | .antiAffinity => "would violate anti-affinity (multiple pods of same deployment on one node)"

def postCheck (s' : State) (v : ApiVerb) : Except Reject Unit :=
  invariants.foldlM (init := ()) fun _ ⟨ik, p⟩ =>
    if p s' then .ok ()
    else .error (.forbiddenInvariant ik (verbTarget v) (invariantReason ik))

def admit (s : State) (v : ApiVerb) : Except Reject Unit :=
  match preCheck s v with
  | .error r => .error r
  | .ok _   => postCheck (apply s v) v

end SRE
