from __future__ import annotations

import unittest
from uuid import UUID, uuid4

from commissioners.common.models import DivisionSnapshot
from commissioners.common.protocol import (
    DivisionInfo,
    EpisodeResult,
    EpisodeScore,
    LeagueInfo,
    MembershipInfo,
    RoundStart,
    VariantInfo,
)
from commissioners.common.ruleset_strategy.config import load_ruleset_strategy_config_file

from crewrift_prime_skill_commissioner import (
    NUM_CREW_SEATS,
    NUM_IMPOSTER_SEATS,
    NUM_SEATS,
    CrewriftPrimeSkillCommissioner,
)
from test_observability import _COMPETITION_DIV, _CONFIG_PATH

_IMPOSTERS_DIV = UUID("ac000000-0000-0000-0000-000000000003")
_CREW_DIV = UUID("ac000000-0000-0000-0000-000000000004")


def _commissioner() -> CrewriftPrimeSkillCommissioner:
    return CrewriftPrimeSkillCommissioner(load_ruleset_strategy_config_file(_CONFIG_PATH))


def _all_divisions() -> list[DivisionInfo]:
    return [
        DivisionInfo(id=_COMPETITION_DIV, name="Competition", level=1, type="competition"),
        DivisionInfo(id=_IMPOSTERS_DIV, name="Imposters", level=2, type="competition"),
        DivisionInfo(id=_CREW_DIV, name="Crew", level=3, type="competition"),
    ]


def _all_division_snapshots(league_id: UUID) -> list[DivisionSnapshot]:
    return [
        DivisionSnapshot(id=_COMPETITION_DIV, name="Competition", level=1, league_id=league_id, type="competition"),
        DivisionSnapshot(id=_IMPOSTERS_DIV, name="Imposters", level=2, league_id=league_id, type="competition"),
        DivisionSnapshot(id=_CREW_DIV, name="Crew", level=3, league_id=league_id, type="competition"),
    ]


def _competition_membership_infos(
    league_id: UUID, specs: list[tuple[UUID, str]]
) -> list[MembershipInfo]:
    """Memberships live ONLY in the Competition division (the shared pool)."""
    return [
        MembershipInfo(
            id=uuid4(),
            league_id=league_id,
            division_id=_COMPETITION_DIV,
            policy_version_id=policy_version_id,
            player_id=player_id,
            status="competing",
            substatus="active",
            is_champion=False,
        )
        for policy_version_id, player_id in specs
    ]


def _round_start_for_division(
    memberships: list[MembershipInfo], current_division_id: UUID, num_episodes: int = 12
) -> RoundStart:
    league_id = memberships[0].league_id
    entrant_ids = [str(m.policy_version_id) for m in memberships]
    return RoundStart(
        round_id=uuid4(),
        round_number=1,
        league=LeagueInfo(id=league_id, commissioner_key="container"),
        divisions=_all_divisions(),
        memberships=memberships,
        recent_results=[],
        variants=[
            VariantInfo(
                id="default",
                name="Default",
                game_config={
                    "slots": [
                        {"color": "red"},
                        {"color": "blue"},
                        {"color": "green"},
                        {"color": "pink"},
                        {"color": "orange"},
                        {"color": "yellow"},
                        {"color": "purple"},
                        {"color": "cyan"},
                    ]
                },
            )
        ],
        state={
            "round_config": {
                "current_division_id": str(current_division_id),
                "entrant_policy_version_ids": entrant_ids,
                "stages": [
                    {
                        "label": "Round",
                        "self_play": False,
                        "num_episodes": num_episodes,
                        "min_episodes_per_entrant": num_episodes,
                    }
                ],
            }
        },
    )


class RoleDivisionDetectionTest(unittest.TestCase):
    def test_division_kind_matches_by_name(self) -> None:
        commissioner = _commissioner()
        divisions = _all_division_snapshots(uuid4())
        kinds = {d.name: commissioner._division_kind(d) for d in divisions}
        self.assertEqual(kinds["Competition"], "both")
        self.assertEqual(kinds["Imposters"], "imposters")
        self.assertEqual(kinds["Crew"], "crew")

    def test_non_competition_division_is_none(self) -> None:
        commissioner = _commissioner()
        staging = DivisionSnapshot(
            id=uuid4(), name="Qualifiers", level=-99, league_id=uuid4(), type="staging"
        )
        self.assertIsNone(commissioner._division_kind(staging))


class ImposterSeatingTest(unittest.TestCase):
    def _fillers(self) -> list[UUID]:
        return [uuid4(), uuid4()]

    def test_imposter_seats_reals_on_imposter_seats_and_fillers_on_crew(self) -> None:
        commissioner = _commissioner()
        filler_ids = self._fillers()
        commissioner._filler_policy_version_ids = lambda league_id: list(filler_ids)  # type: ignore[assignment]
        commissioner._sync_league_spend_limit = lambda league_id: None  # type: ignore[assignment]
        league_id = uuid4()
        specs = [(uuid4(), f"ply_{i}") for i in range(NUM_SEATS)]
        memberships = _competition_membership_infos(league_id, specs)
        round_start = _round_start_for_division(memberships, _IMPOSTERS_DIV)

        schedule = commissioner.schedule_episodes_for_round_start(round_start)

        self.assertTrue(schedule.episodes)
        real_policy_ids = {m.policy_version_id for m in memberships}
        for episode in schedule.episodes:
            self.assertEqual(len(episode.policy_version_ids), NUM_SEATS)
            # Roles pinned: first NUM_IMPOSTER_SEATS imposter, rest crew.
            slots = episode.game_config["slots"]
            self.assertEqual(len(slots), NUM_SEATS)
            for seat in range(NUM_IMPOSTER_SEATS):
                self.assertEqual(slots[seat]["role"], "imposter")
            for seat in range(NUM_IMPOSTER_SEATS, NUM_SEATS):
                self.assertEqual(slots[seat]["role"], "crew")
            # Variant colors preserved under the role override.
            self.assertEqual(slots[0].get("color"), "red")
            # The imposter seats (0..NUM_IMPOSTER_SEATS-1) hold REAL entrants.
            for seat in range(NUM_IMPOSTER_SEATS):
                self.assertIn(episode.policy_version_ids[seat], real_policy_ids)
            # Crew seats are fillers, and tagged as such.
            filler_seats = {int(s) for s in episode.tags["filler_seats"].split(",") if s}
            self.assertEqual(filler_seats, set(range(NUM_IMPOSTER_SEATS, NUM_SEATS)))
            self.assertEqual(episode.tags["role_league"], "imposters")
            for seat in filler_seats:
                self.assertIn(episode.policy_version_ids[seat], filler_ids)

    def test_imposter_round_dispatches_when_no_fillers_configured(self) -> None:
        commissioner = _commissioner()
        commissioner._filler_policy_version_ids = lambda league_id: []  # type: ignore[assignment]
        commissioner._sync_league_spend_limit = lambda league_id: None  # type: ignore[assignment]
        league_id = uuid4()
        specs = [(uuid4(), f"ply_{i}") for i in range(NUM_SEATS)]
        memberships = _competition_membership_infos(league_id, specs)
        round_start = _round_start_for_division(memberships, _IMPOSTERS_DIV)

        schedule = commissioner.schedule_episodes_for_round_start(round_start)

        self.assertTrue(schedule.episodes)
        for episode in schedule.episodes:
            self.assertEqual(len(episode.policy_version_ids), NUM_SEATS)


class CrewSeatingTest(unittest.TestCase):
    def test_crew_seats_reals_on_crew_seats_and_fillers_on_imposter(self) -> None:
        commissioner = _commissioner()
        filler_ids = [uuid4(), uuid4()]
        commissioner._filler_policy_version_ids = lambda league_id: list(filler_ids)  # type: ignore[assignment]
        commissioner._sync_league_spend_limit = lambda league_id: None  # type: ignore[assignment]
        league_id = uuid4()
        specs = [(uuid4(), f"ply_{i}") for i in range(NUM_SEATS)]
        memberships = _competition_membership_infos(league_id, specs)
        round_start = _round_start_for_division(memberships, _CREW_DIV)

        schedule = commissioner.schedule_episodes_for_round_start(round_start)

        self.assertTrue(schedule.episodes)
        real_policy_ids = {m.policy_version_id for m in memberships}
        for episode in schedule.episodes:
            self.assertEqual(len(episode.policy_version_ids), NUM_SEATS)
            slots = episode.game_config["slots"]
            for seat in range(NUM_IMPOSTER_SEATS):
                self.assertEqual(slots[seat]["role"], "imposter")
            for seat in range(NUM_IMPOSTER_SEATS, NUM_SEATS):
                self.assertEqual(slots[seat]["role"], "crew")
            # Crew seats hold REAL entrants; imposter seats are fillers.
            for seat in range(NUM_IMPOSTER_SEATS, NUM_SEATS):
                self.assertIn(episode.policy_version_ids[seat], real_policy_ids)
            filler_seats = {int(s) for s in episode.tags["filler_seats"].split(",") if s}
            self.assertEqual(filler_seats, set(range(0, NUM_IMPOSTER_SEATS)))
            self.assertEqual(episode.tags["role_league"], "crew")
            for seat in filler_seats:
                self.assertIn(episode.policy_version_ids[seat], filler_ids)

    def test_crew_fills_empty_target_seats_when_few_players(self) -> None:
        commissioner = _commissioner()
        filler_ids = [uuid4(), uuid4(), uuid4()]
        commissioner._filler_policy_version_ids = lambda league_id: list(filler_ids)  # type: ignore[assignment]
        commissioner._sync_league_spend_limit = lambda league_id: None  # type: ignore[assignment]
        league_id = uuid4()
        # Only 3 real players compete but crew has NUM_CREW_SEATS (6) seats.
        specs = [(uuid4(), f"ply_{i}") for i in range(3)]
        memberships = _competition_membership_infos(league_id, specs)
        round_start = _round_start_for_division(memberships, _CREW_DIV)

        schedule = commissioner.schedule_episodes_for_round_start(round_start)

        self.assertTrue(schedule.episodes)
        real_policy_ids = {m.policy_version_id for m in memberships}
        for episode in schedule.episodes:
            self.assertEqual(len(episode.policy_version_ids), NUM_SEATS)
            # At most 3 real entrants seated; the rest of the 8 seats are fillers.
            real_seated = [
                p for p in episode.policy_version_ids if p in real_policy_ids
            ]
            self.assertLessEqual(len(real_seated), 3)
            self.assertLessEqual(len(real_seated), NUM_CREW_SEATS)


class RoleSchedulingCadenceTest(unittest.TestCase):
    def test_role_entrants_sourced_from_competition_pool(self) -> None:
        commissioner = _commissioner()
        commissioner._filler_policy_version_ids = lambda league_id: [uuid4() for _ in range(6)]  # type: ignore[assignment]
        commissioner._sync_league_spend_limit = lambda league_id: None  # type: ignore[assignment]
        league_id = uuid4()
        specs = [(uuid4(), f"ply_{i}") for i in range(4)]
        memberships = _competition_membership_infos(league_id, specs)
        real_policy_ids = {m.policy_version_id for m in memberships}
        round_start = _round_start_for_division(memberships, _IMPOSTERS_DIV)

        schedule = commissioner.schedule_episodes_for_round_start(round_start)

        # Real seats across the round only ever hold Competition-pool policies.
        seen_reals: set[UUID] = set()
        for episode in schedule.episodes:
            filler_seats = {int(s) for s in episode.tags["filler_seats"].split(",") if s}
            for seat, policy in enumerate(episode.policy_version_ids):
                if seat not in filler_seats:
                    self.assertIn(policy, real_policy_ids)
                    seen_reals.add(policy)
        self.assertTrue(seen_reals.issubset(real_policy_ids))


class RoleScoringTest(unittest.TestCase):
    """A role round is scored on the same win-rate board, keyed to the role
    division, with filler seats excluded."""

    def test_imposter_round_scores_real_entrant_and_excludes_fillers(self) -> None:
        commissioner = _commissioner()
        league_id = uuid4()
        real_a = uuid4()
        real_b = uuid4()
        filler = uuid4()
        memberships = [
            MembershipInfo(
                id=uuid4(),
                league_id=league_id,
                division_id=_COMPETITION_DIV,
                policy_version_id=real_a,
                player_id="ply_a",
                status="competing",
                substatus="active",
                is_champion=False,
            ),
            MembershipInfo(
                id=uuid4(),
                league_id=league_id,
                division_id=_COMPETITION_DIV,
                policy_version_id=real_b,
                player_id="ply_b",
                status="competing",
                substatus="active",
                is_champion=False,
            ),
        ]
        round_start = _round_start_for_division(memberships, _IMPOSTERS_DIV, num_episodes=1)
        # One episode: seats 0,1 are the real imposters (real_a wins), seats 2-7 are
        # filler crew. The scheduled episode marks seats 2-7 filler.
        seat_policies = [real_a, real_b, filler, filler, filler, filler, filler, filler]
        scheduled = commissioner.schedule_episodes_for_round_start(round_start)
        request_id = scheduled.episodes[0].request_id
        # Rebuild a scheduled episode whose seating we control for the scoring path.
        scheduled_episode = scheduled.episodes[0]
        scheduled_episode.policy_version_ids = seat_policies
        scheduled_episode.tags["filler_seats"] = "2,3,4,5,6,7"
        scheduled_episode.tags["filler_policy_version_ids"] = str(filler)
        episode = EpisodeResult(
            request_id=request_id,
            scores=[EpisodeScore(policy_version_id=pid, score=0.0) for pid in seat_policies],
            game_results={
                "win": [True, False, False, False, False, False, False, False],
                "imposter": [1, 1, 0, 0, 0, 0, 0, 0],
                "crew": [0, 0, 1, 1, 1, 1, 1, 1],
            },
        )
        complete = commissioner.complete_round_for_round_start(
            round_start,
            episode_results=[episode],
            scheduled_episodes=[scheduled_episode],
            failed_episodes=[],
        )
        self.assertTrue(complete.leaderboards)
        board = complete.leaderboards[0]
        # The board is keyed to the IMPOSTERS division, not Competition.
        self.assertEqual(board.division_id, _IMPOSTERS_DIV)
        rows = board.views[0].rows
        subjects = {row.subject_id for row in rows}
        # Real players are scored; the filler policy never appears as a subject.
        self.assertIn("ply_a", subjects)
        self.assertNotIn(str(filler), subjects)
        by_player = {row.subject_id: row for row in rows}
        # ply_a won its imposter episode (win rate 1.0); ply_b did not.
        self.assertAlmostEqual(float(by_player["ply_a"].values["win_rate"]), 1.0, places=9)


if __name__ == "__main__":
    unittest.main()
