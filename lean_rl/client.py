# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

"""Proved-SRE RL client.

Wraps the OpenEnv HTTP/WS surface with typed action/observation. The
agent emits an `SREAction` containing one Lean `ApiVerb`; the server
returns an `SREObservation` with the projected state, the goal, and an
action mask.
"""

from typing import Dict

from openenv.core import EnvClient
from openenv.core.client_types import StepResult
from openenv.core.env_server.types import State

from .models import SREAction, SREObservation


class LeanRlEnv(EnvClient[SREAction, SREObservation, State]):
    """Client for the Proved-SRE RL environment.

    Example:
        >>> with LeanRlEnv(base_url="http://localhost:8000") as env:
        ...     obs = env.reset()
        ...     verb = {"op": "deletePodByKey",
        ...             "key": {"kind": "pod", "ns": "default", "name": "api-1"}}
        ...     result = env.step(SREAction(verb=verb))
    """

    def _step_payload(self, action: SREAction) -> Dict:
        return {"verb": action.verb}

    def _parse_result(self, payload: Dict) -> StepResult[SREObservation]:
        obs_data = payload.get("observation", {})
        observation = SREObservation(
            state=obs_data.get("state", {}),
            goal=obs_data.get("goal", {}),
            mask=obs_data.get("mask", {}),
            done=payload.get("done", False),
            reward=payload.get("reward"),
            metadata=obs_data.get("metadata", {}),
        )
        return StepResult(
            observation=observation,
            reward=payload.get("reward"),
            done=payload.get("done", False),
        )

    def _parse_state(self, payload: Dict) -> State:
        return State(
            episode_id=payload.get("episode_id"),
            step_count=payload.get("step_count", 0),
        )
