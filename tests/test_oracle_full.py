import ape
import pytest
import sys
from pathlib import Path
import boa
from fixtures import system, owner, alice, bob, charlie, frontend, system_addresses
from dataclasses import dataclass
from typing import Tuple, List
from hypothesis import given, HealthCheck, settings
from hypothesis import strategies as st


class TestOracle:
    
    @staticmethod
    def observe_single(oracle, seconds_ago):
        """
        Helper function to get a single observation from the oracle

        Args:
            oracle: The initialized oracle contract instance
            seconds_ago (int): Number of seconds ago to get the observation from

        Returns:
            tuple: (tick_cumulative, seconds_per_liquidity_cumulative)
        """
        seconds_agos = [seconds_ago]
        tick_cumulatives, seconds_per_liquidity_cumulatives = oracle.observe(seconds_agos)
        return tick_cumulatives[0], seconds_per_liquidity_cumulatives[0]

    @staticmethod
    def setup_full_oracle(oracle):
        """
        Sets up an oracle with 65535 observations.
        """
        
        oracle.initialize((
            1601906400,  # Monday, October 5, 2020 9:00:00 AM GMT-05:00
            0,  # initial liquidity
            0  # initial tick
        ))
        
        # Grow to full size first
        BATCH_SIZE = 300
        GROW_BATCH_SIZE = 3000
        TOTAL_SIZE = 65535
        
        # First grow to full capacity
        cardinality_next = oracle.cardinality_next()
        while cardinality_next < TOTAL_SIZE:
            if (cardinality_next + GROW_BATCH_SIZE < TOTAL_SIZE):
                grow_to = cardinality_next + GROW_BATCH_SIZE
            else:
                grow_to = TOTAL_SIZE
            oracle.grow(grow_to)
            print(f'grow_to: {grow_to}')
            cardinality_next = grow_to
            
        # Only write complete batches of 300 observations
        # This will write exactly 218 batches (218 * 300 = 65400) + 1 batch (300)
        # The index will end up at 65700 % 65535 = 165
        num_complete_batches = TOTAL_SIZE // BATCH_SIZE  # This is 218
        MAX_UINT128 = 2**128 - 1
        # 300
        for i in range(0, (num_complete_batches + 1) * BATCH_SIZE, BATCH_SIZE):
            batch = []
            for j in range(BATCH_SIZE):
                batch.append((
                    13,  # advanceTimeBy: 13 seconds
                    -(i + j),  # tick: -i - j
                    i + j  # liquidity: uint128(int128(i) + int128(j))
                ))
            oracle.batch_update(batch)
            print(f"After batch {i//BATCH_SIZE}: index={oracle.index()}, cardinality={oracle.cardinality()}")
        return oracle

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_full_oracle(self, system):
        base_oracle = system['oracle_full']
        oracle = self.setup_full_oracle(base_oracle)
        
        assert oracle.cardinality_next() == 65535
        assert oracle.cardinality() == 65535
        assert oracle.index() == 165
        
        tolerance_percentage = 0.005  # 0.005% tolerance
        
        # can observe into the ordered portion with exact seconds ago
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 100 * 13)
        expected_cumulative = -27970560813
        tolerance = abs(expected_cumulative * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_cumulative) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_cumulative} by {abs(tick_cumulative - expected_cumulative) / abs(expected_cumulative) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_cumulative = 60465049086512033878831623038233202591033
        tolerance_percentage = 0.005  # 0.005% tolerance
        tolerance = abs(expected_cumulative * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_cumulative) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_cumulative} by {abs(seconds_per_liquidity_cumulative_x128 - expected_cumulative) / abs(expected_cumulative) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe into the ordered portion with unexact seconds ago
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 100 * 13 + 5)
        expected_tick = -27970232823
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 60465023149565257990964350912969670793706
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe at exactly the latest observation
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 0)
        expected_tick = -28055903863
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 60471787506468701386237800669810720099776
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe into the unordered portion of array at exact seconds ago
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 200 * 13)
        expected_tick = -27885347763
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 60458300386499273141628780395875293027404
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe into the unordered portion of array at seconds ago between observations
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 200 * 13 + 5)
        expected_tick = -27885020273
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 60458274409952896081377821330361274907140
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe the oldest observation
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 13 * 65534)
        expected_tick = -175890
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 33974356747348039873972993881117400879779
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe at exactly the latest observation after some time passes
        oracle.advance_time(5)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 5)
        expected_tick = -28055903863
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 60471787506468701386237800669810720099776
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe after the latest observation counterfactual
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 3)
        expected_tick = -28056035261
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 60471797865298117996489508104462919730461
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        # can observe the oldest observation after time passes
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 13 * 65534 + 5)
        expected_tick = -175890
        tolerance = abs(expected_tick * tolerance_percentage / 100)
        assert abs(tick_cumulative - expected_tick) <= tolerance, f"Cumulative value {tick_cumulative} differs from expected {expected_tick} by {abs(tick_cumulative - expected_tick) / abs(expected_tick) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"

        expected_spl = 33974356747348039873972993881117400879779
        tolerance = abs(expected_spl * tolerance_percentage / 100)
        assert abs(seconds_per_liquidity_cumulative_x128 - expected_spl) <= tolerance, f"Cumulative value {seconds_per_liquidity_cumulative_x128} differs from expected {expected_spl} by {abs(seconds_per_liquidity_cumulative_x128 - expected_spl) / abs(expected_spl) * 100:.4f}% (tolerance: ±{tolerance_percentage}%)"