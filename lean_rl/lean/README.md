# ProvedSRE

## Overview
`ProvedSRE` is a Lean 4 model of a small Kubernetes-style admission
controller. It defines a cluster `State` (nodes, pods, deployments),
an `ApiVerb` surface (create / update / scale / delete), and a list
of safety `invariants` (PodDisruptionBudget, node capacity, and
anti-affinity). The `admit` gate dry-runs each verb through `apply`
and re-checks every invariant before committing. Soundness is proved
in `ProvedSRE/Soundness.lean`: any plan accepted by `admit` is
guaranteed to leave the cluster in a `safe` state, giving an LLM-
emitted action plan a machine-checked safety guarantee.

See the full report here: - [Report](../../reports/00-checkpoint/talk.pdf)

## Origin
This project was built during the **LeanLang for Verified
Autonomy Hackathon** (April 17–18 + online through May 1,
2026) at the **Indian Institute of Science (IISc),
Bangalore**.
Sponsored by **[Emergence AI](https://www.emergence.ai)**
Organized by **[Emergence India Labs]
(https://east.emergence.ai)** in collaboration with
**IISc Bangalore**.

## Acknowledgments
This project was made possible by:
- **Emergence AI** — Hackathon sponsor
- **Emergence India Labs** — Event organizer and
research direction
- **Indian Institute of Science (IISc), Bangalore** —
Academic partner, hackathon co-design, tutorials,
and mentorship

## Links
- [Hackathon Page](https://east.emergence.ai/
hackathon-april2026.html)
- [Emergence India Labs](https://east.emergence.ai)
- [Emergence AI](https://www.emergence.ai)

