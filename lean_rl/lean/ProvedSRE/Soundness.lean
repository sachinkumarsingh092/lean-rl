import ProvedSRE.Api

namespace SRE

/-! ## Admission soundness for PDB

We prove `pdbAdmissionSound`: if the admission gate accepts a verb, then
applying that verb yields a state that respects every PDB. This is the
single end-to-end soundness theorem for v1; capacity and anti-affinity
are runtime-checked but not yet proved sound. -/

theorem postCheck_ok_pdb {s' : State} {v : ApiVerb}
    (h : postCheck s' v = .ok ()) : pdbRespected s' = true := by
  unfold postCheck at h
  -- Case split on `pdbRespected s'` to clear the outer guard.
  cases hp : pdbRespected s' with
  | false =>
      -- The `if !false then .error ...` branch fires; .error ≠ .ok.
      rw [hp] at h
      simp at h
  | true  => rfl

theorem pdbAdmissionSound (s : State) (v : ApiVerb)
    (h : admit s v = .ok ()) : pdbRespected (apply s v) = true := by
  unfold admit at h
  -- preCheck either errors (contradiction) or yields .ok () and we
  -- continue with postCheck on the post-state.
  cases hpre : preCheck s v with
  | error r =>
      rw [hpre] at h
      cases h
  | ok _ =>
      rw [hpre] at h
      exact postCheck_ok_pdb h

end SRE
