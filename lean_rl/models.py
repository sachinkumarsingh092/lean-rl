# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

"""Action and observation types for the Proved-SRE RL environment.

The action is a single Lean `ApiVerb` encoded as JSON. The observation
exposes the projected `SRE.State`, the episode `Goal`, an action mask
(addressable deployments / pods), and step bookkeeping.
"""

from typing import Any

from openenv.core.env_server.types import Action, Observation
from pydantic import Field


class SREAction(Action):
    """One ApiVerb. Shape matches Lean's `FromJson ApiVerb` (see Verify.lean).

    Examples:
        {"op": "deletePodByKey", "key": {"kind": "pod", "ns": "default", "name": "api-1"}}
        {"op": "scaleDeployment", "key": {...}, "resourceVersion": 7, "replicas": 2}
    """

    verb: dict[str, Any] = Field(..., description="ApiVerb JSON")


class SREObservation(Observation):
    """Projected cluster state plus goal and action mask."""

    state: dict[str, Any] = Field(default_factory=dict, description="SRE.State JSON")
    goal: dict[str, Any] = Field(default_factory=dict, description="Goal JSON")
    mask: dict[str, Any] = Field(default_factory=dict, description="Per-verb addressability hints")
