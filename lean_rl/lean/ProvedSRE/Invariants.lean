import ProvedSRE.Cluster

namespace SRE

def availableReplicas (s : State) (d : DeploymentId) : Nat :=
  (s.pods.filter fun p => p.deployment = d ∧ p.phase = .Running).length

def pdbRespected (s : State) : Bool :=
  s.deployments.all fun d => availableReplicas s d.id ≥ d.minAvailable

def nodeUsage (s : State) (n : NodeId) : Resources :=
  (s.pods.filter fun p => p.node = n ∧ p.phase ≠ .Failed).foldl
    (fun acc p => acc + p.request) { cpu := 0, mem := 0 }

def capacityRespected (s : State) : Bool :=
  s.nodes.all fun n => decide (nodeUsage s n.id ≤ n.capacity)

def antiAffinityRespected (s : State) : Bool :=
  s.deployments.all fun d =>
    !d.antiAffinity ||
    let pods  := s.pods.filter fun p => p.deployment = d.id ∧ p.phase ≠ .Failed
    let nodes := pods.map (·.node)
    nodes.length = nodes.eraseDups.length

inductive InvariantKind | pdb | capacity | antiAffinity
  deriving DecidableEq, Repr

def invariants : List (InvariantKind × (State → Bool)) :=
  [ (.pdb, pdbRespected), (.capacity, capacityRespected), (.antiAffinity, antiAffinityRespected) ]

def safe (s : State) : Bool := invariants.all (·.2 s)

end SRE
