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

inductive InvariantKind | pdb | capacity | antiAffinity
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
          let toRemove := runCount - n
          { s1 with pods := removeNRunning s1.pods d.id toRemove }
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

def postCheck (s' : State) (v : ApiVerb) : Except Reject Unit :=
  if !pdbRespected s' then
    .error (.forbiddenInvariant .pdb (verbTarget v)
              "would violate PodDisruptionBudget minAvailable")
  else if !capacityRespected s' then
    .error (.forbiddenInvariant .capacity (verbTarget v)
              "would exceed node capacity")
  else if !antiAffinityRespected s' then
    .error (.forbiddenInvariant .antiAffinity (verbTarget v)
              "would violate anti-affinity (multiple pods of same deployment on one node)")
  else
    .ok ()

def admit (s : State) (v : ApiVerb) : Except Reject Unit :=
  match preCheck s v with
  | .error r => .error r
  | .ok _   => postCheck (apply s v) v

end SRE
