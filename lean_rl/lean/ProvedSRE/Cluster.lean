namespace SRE

abbrev NodeId       := Nat
abbrev DeploymentId := Nat
abbrev PodId        := Nat
abbrev Image        := Nat   -- monotonically increasing version tag

structure Resources where
  cpu : Nat
  mem : Nat
  deriving DecidableEq, Repr

instance : Add Resources where
  add a b := { cpu := a.cpu + b.cpu, mem := a.mem + b.mem }

instance : LE Resources :=
  ⟨fun a b => a.cpu ≤ b.cpu ∧ a.mem ≤ b.mem⟩

instance (a b : Resources) : Decidable (a ≤ b) := by
  show Decidable (a.cpu ≤ b.cpu ∧ a.mem ≤ b.mem)
  exact inferInstance

inductive PodPhase | Pending | Running | Terminating | Failed
  deriving DecidableEq, Repr

structure Pod where
  id              : PodId
  deployment      : DeploymentId
  node            : NodeId
  image           : Image
  phase           : PodPhase
  request         : Resources
  name            : String := ""
  ns              : String := "default"
  resourceVersion : Nat    := 0
  deriving DecidableEq, Repr

structure Node where
  id        : NodeId
  capacity  : Resources
  cordoned  : Bool
  deriving DecidableEq, Repr

structure Deployment where
  id              : DeploymentId
  desired         : Nat
  image           : Image            -- target image
  request         : Resources
  minAvailable    : Nat              -- PDB
  antiAffinity    : Bool             -- at most one pod per node if true
  name            : String := ""
  ns              : String := "default"
  resourceVersion : Nat    := 0
  deriving DecidableEq, Repr

structure State where
  nodes        : List Node
  deployments  : List Deployment
  pods         : List Pod
  tick         : Nat
  deriving Repr

inductive Action
  | cordon       (n : NodeId)
  | uncordon     (n : NodeId)
  | drain        (n : NodeId)
  | setImage     (d : DeploymentId) (img : Image)
  | scale        (d : DeploymentId) (n : Nat)
  | rolloutUndo  (d : DeploymentId)
  | deletePod    (p : PodId)
  | wait         (ticks : Nat)
  | noop
  deriving DecidableEq, Repr

abbrev Plan := List Action

/-- One-tick advancement for `wait`: Pending pods become Running,
    Terminating pods are removed. Keep deterministic and total. -/
def tickPods (pods : List Pod) : List Pod :=
  pods.filterMap fun p =>
    match p.phase with
    | .Terminating => none
    | .Pending     => some { p with phase := .Running }
    | _            => some p

def step (s : State) : Action → State := fun
  | .wait k =>
      let rec advance (s : State) : Nat → State
        | 0     => s
        | n + 1 =>
            advance { s with pods := tickPods s.pods, tick := s.tick + 1 } n
      advance s k
  | .cordon n =>
      { s with nodes := s.nodes.map fun nd =>
          if nd.id = n then { nd with cordoned := true } else nd }
  | .uncordon n =>
      { s with nodes := s.nodes.map fun nd =>
          if nd.id = n then { nd with cordoned := false } else nd }
  | .drain n =>
      { s with pods := s.pods.map fun p =>
          if p.node = n ∧ p.phase ≠ .Failed
          then { p with phase := .Terminating } else p }
  | .setImage d img =>
      { s with deployments := s.deployments.map fun dep =>
          if dep.id = d then { dep with image := img } else dep }
  | .scale d k =>
      { s with deployments := s.deployments.map fun dep =>
          if dep.id = d then { dep with desired := k } else dep }
  | .rolloutUndo _ => s   -- v1 stub; needs `previousImage` field to be useful
  | .deletePod p =>
      { s with pods := s.pods.filter fun q => q.id ≠ p }
  | .noop => s

def runPlan (s : State) : Plan → State
  | []      => s
  | a :: as => runPlan (step s a) as

def trajectory (s : State) : Plan → List State
  | []      => [s]
  | a :: as => s :: trajectory (step s a) as

end SRE
