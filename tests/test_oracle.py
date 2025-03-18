import ape
import pytest
import sys
from pathlib import Path
import boa
from fixtures import system, owner, alice, bob, charlie, frontend, system_addresses
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
    def assert_observation(oracle, index, expected):
        """
        Helper function to assert that an observation matches expected values

        Args:
            oracle: The oracle contract instance
            idx: The index of the observation to check
            expected: Dict containing expected values with keys:
                - block_timestamp (uint32)
                - tick_cumulative (int56) 
                - seconds_per_liquidity_cumulative_x128 (uint160)
                - tick (int24)
                - initialized (bool)
        """
        observation = oracle.observations(index)
        # print(observation)
        assert observation[0] == expected['block_timestamp'], "block_timestamp mismatch"
        assert observation[1] == expected['tick'], "tick mismatch" 
        assert observation[2] == expected['tick_cumulative'], "tick_cumulative mismatch"
        assert observation[3] == expected['seconds_per_liquidity_cumulative_x128'], "seconds_per_liquidity_cumulative_x128 mismatch"
        assert observation[4] == expected['initialized'], "initialized mismatch" 
        
    @staticmethod
    def setup_oracle_with_many_observations(oracle, starting_time):
        """
        Sets up an oracle with multiple observations over time.
    
        Args:
            oracle: The oracle contract instance
            starting_time: Initial timestamp for the oracle
        """
        # Initialize oracle with starting parameters
        oracle.initialize((starting_time, -5, 5))
        oracle.grow(5)
        oracle.update((3, 1, 2))
        oracle.update((2, -6, 4))
        oracle.update((4, -2, 4))
        oracle.update((1, -2, 9))
        oracle.update((3, 4, 2))
        oracle.update((6, 6, 7))
        return oracle
    
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

    @pytest.fixture
    def initialized_oracle(self, system):
        oracle = system['oracle']
        time = 0  # uint32
        tick = 0  # int24
        liquidity = 0  # uint128
        params = (time, tick, liquidity)
        oracle.initialize(params)
        return oracle

    @pytest.fixture
    def initialized_oracle_with_many_observations(self, system):
        oracle = system['oracle']
        time = 0  # uint32
        tick = 0  # int24
        liquidity = 0  # uint128
        params = (time, tick, liquidity)
        oracle.initialize((time, tick, liquidity))
        oracle.grow(5)
        oracle.update((1, 2, 5))
        oracle.update((5, -1, 8))
        oracle.update((3, 2, 3))
        oracle.update((6, 3, 2))
        
        return oracle

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_initialize(self, initialized_oracle):
        assert initialized_oracle.index() == 0
        assert initialized_oracle.cardinality() == 1
        assert initialized_oracle.cardinality_next() == 1
        print(initialized_oracle.observations(0))
        self.assert_observation(initialized_oracle, 0, {'block_timestamp': 0, 'tick': 0, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 0, 'initialized': True })
       

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_grow(self, initialized_oracle):
        initialized_oracle.grow(5)
        assert initialized_oracle.index() == 0
        assert initialized_oracle.cardinality() == 1
        assert initialized_oracle.cardinality_next() == 5

        # Check first slot
        self.assert_observation(initialized_oracle, 0, {'block_timestamp': 0, 'tick': 0, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 0, 'initialized': True})
        
        # Check additional slots
        for i in range(1, 5):
            self.assert_observation(initialized_oracle, i, {'block_timestamp': 1, 'tick': 0, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 0, 'initialized': False})

        # Test noop if already at size
        initialized_oracle.grow(3)
        
        assert initialized_oracle.index() == 0
        assert initialized_oracle.cardinality() == 1
        assert initialized_oracle.cardinality_next() == 5

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_grow_after_wrap(self, initialized_oracle):
        initialized_oracle.grow(2)
        assert initialized_oracle.index() == 0
        initialized_oracle.update((2, 1, 1))
        # index is now 1
        assert initialized_oracle.index() == 1
        initialized_oracle.update((2, 1, 1))
        # index is now 0 again
        assert initialized_oracle.index() == 0
        initialized_oracle.grow(3)
        assert initialized_oracle.index() == 0
        assert initialized_oracle.cardinality() == 2
        assert initialized_oracle.cardinality_next() == 3
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_grow_1_slot(self, initialized_oracle):
        gas_before = boa.env.get_gas_used()
        initialized_oracle.grow(2)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used grow 1 slot: {gas_used}')
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_grow_10_slots(self, initialized_oracle):
        gas_before = boa.env.get_gas_used()
        initialized_oracle.grow(11)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used grow 10 slots: {gas_used}')
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_grow_1_slot_cardinality_greater(self, initialized_oracle):
        initialized_oracle.grow(2)
        gas_before = boa.env.get_gas_used()
        initialized_oracle.grow(3)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used grow 1 slot cardinality greater: {gas_used}')
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_grow_10_slots_cardinality_greater(self, initialized_oracle):
        initialized_oracle.grow(2)
        gas_before = boa.env.get_gas_used()
        initialized_oracle.grow(12)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used grow 10 slots cardinality greater: {gas_used}')
        
    # # @pytest.mark.skip(reason="temporarily disabled")
    def test_write(self, initialized_oracle):
        initialized_oracle.update((1, 2, 5))
        assert initialized_oracle.index() == 0
        self.assert_observation(initialized_oracle, 0, {'block_timestamp': 1, 'tick': 2, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 340282366920938463463374607431768211456, 'initialized': True})
        initialized_oracle.update((5, -1, 8)) 
        assert initialized_oracle.index() == 0
        self.assert_observation(initialized_oracle, 0, {'block_timestamp': 6, 'tick': -1, 'tick_cumulative': 10, 'seconds_per_liquidity_cumulative_x128': 680564733841876926926749214863536422912, 'initialized': True})
        initialized_oracle.update((3, 2, 3)) 
        assert initialized_oracle.index() == 0
        self.assert_observation(initialized_oracle, 0, {'block_timestamp': 9, 'tick': 2, 'tick_cumulative': 7, 'seconds_per_liquidity_cumulative_x128': 808170621437228850725514692650449502208, 'initialized': True})
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_write_adds_nothing_if_time_unchanged(self, initialized_oracle):
        initialized_oracle.grow(2)
        initialized_oracle.update((1, 3, 2))
        assert initialized_oracle.index() == 1
        initialized_oracle.update((0, -5, 9))
        assert initialized_oracle.index() == 1

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_write_time_changed(self, initialized_oracle):
        initialized_oracle.grow(3)
        initialized_oracle.update((6, 3, 2))
        assert initialized_oracle.index() == 1
        initialized_oracle.update((4, -5, 9))
        assert initialized_oracle.index() == 2
        self.assert_observation(initialized_oracle, 1, {'block_timestamp': 6, 'tick': 3, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 2041694201525630780780247644590609268736, 'initialized': True})
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_write_grows_cardinality_writing_past(self, initialized_oracle):
        initialized_oracle.grow(2)
        initialized_oracle.grow(4)
        assert initialized_oracle.cardinality() == 1
        initialized_oracle.update((3, 5, 6))
        assert initialized_oracle.cardinality() == 4
        initialized_oracle.update((4, 6, 4))
        assert initialized_oracle.cardinality() == 4
        assert initialized_oracle.index() == 2
        self.assert_observation(initialized_oracle, 2, {'block_timestamp': 7,'tick': 6, 'tick_cumulative': 20, 'seconds_per_liquidity_cumulative_x128': 1247702012043441032699040227249816775338, 'initialized': True})

    # @pytest.mark.skip(reason="temporarily disabled")   
    def test_write_wraps_around(self, initialized_oracle):
        initialized_oracle.grow(3)
        initialized_oracle.update((3, 1, 2))
        initialized_oracle.update((4, 2, 3))
        initialized_oracle.update((5, 3, 4))
        assert initialized_oracle.index() == 0
        self.assert_observation(initialized_oracle, 0, {'block_timestamp': 12, 'tick': 3, 'tick_cumulative': 14, 'seconds_per_liquidity_cumulative_x128': 2268549112806256423089164049545121409706, 'initialized': True})

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_write_accumulates_liquidity(self, initialized_oracle):
        initialized_oracle.grow(4)
        initialized_oracle.update((3, 3, 2))
        initialized_oracle.update((4, -7, 6))
        initialized_oracle.update((5, -2, 4))
        assert initialized_oracle.index() == 3
        self.assert_observation(initialized_oracle, 1, {'block_timestamp': 3, 'tick': 3, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 1020847100762815390390123822295304634368, 'initialized': True})
        self.assert_observation(initialized_oracle, 2, {'block_timestamp': 7, 'tick': -7, 'tick_cumulative': 12, 'seconds_per_liquidity_cumulative_x128': 1701411834604692317316873037158841057280, 'initialized': True})
        self.assert_observation(initialized_oracle, 3, {'block_timestamp': 12, 'tick': -2, 'tick_cumulative': -23, 'seconds_per_liquidity_cumulative_x128': 1984980473705474370203018543351981233493, 'initialized': True})
        self.assert_observation(initialized_oracle, 4, {'block_timestamp': 0, 'tick': 0, 'tick_cumulative': 0, 'seconds_per_liquidity_cumulative_x128': 0, 'initialized': False})

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_observe_fails_before_initialize(self, system):
        oracle = system['oracle']
        with pytest.raises(Exception) as excinfo:
            oracle.observe([0])
        assert "<oracle cardinality cannot be zero>" in str(excinfo.value)

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_observe_fails_if_older_does_not_exist(self, system):
        oracle = system['oracle']
        oracle.initialize((4, 2, 5))
        with pytest.raises(Exception) as excinfo:
            oracle.observe([1])
        assert "<target predates oldest observation>" in str(excinfo.value)

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_does_not_fail_across_overflow_boundary(self, system):
        oracle = system['oracle']
        oracle.initialize((2**32 - 1, 2, 4))
        oracle.advance_time(2)
        result = self.observe_single(oracle, 1)
        assert result[0] == 2
        assert result[1] == 85070591730234615865843651857942052864
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_interpolation_max_liquidity(self, system):
        oracle = system['oracle']
        oracle.initialize((0, 0, 2**128 - 1))
        oracle.grow(2)
        oracle.update((13, 0, 0))
        result = self.observe_single(oracle, 0)
        assert result[1] == 13
        result = self.observe_single(oracle, 6)
        assert result[1] == 7
        result = self.observe_single(oracle, 12)
        assert result[1] == 1
        result = self.observe_single(oracle, 13)
        assert result[1] == 0
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_interpolates_same_0_and_1_liquidity(self, system):
        oracle = system['oracle']
        oracle.initialize((0, 0, 1)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((13, 0, 0))
        result = self.observe_single(oracle, 0)
        assert result[1] == 13 << 128
        result = self.observe_single(oracle, 6)
        assert result[1] == 7 << 128
        result = self.observe_single(oracle, 12)
        assert result[1] == 1 << 128
        result = self.observe_single(oracle, 13)
        assert result[1] == 0

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_interpolates_across_chunk_boundaries(self, system):
        oracle = system['oracle']
        oracle.initialize((0, 0, 0)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((2 ** 32 - 6, 0, 0))
        result = self.observe_single(oracle, 0)
        assert result[1] == (2 ** 32 - 6) << 128
        oracle.update((13, 0, 0))
        result = self.observe_single(oracle, 0)
        assert result[1] == 7 << 128

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_single_observation_at_current_time(self, system):
        oracle = system['oracle']
        oracle.initialize((5, 2, 4)) # time, tick, liquidity
        result = self.observe_single(oracle, 0)
        assert result[0] == 0
        assert result[1] == 0
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_single_observation_in_recent_past(self, system):
        oracle = system['oracle']
        oracle.initialize((5, 2, 4)) # time, tick, liquidity
        oracle.advance_time(3)
        with pytest.raises(Exception) as excinfo:
            self.observe_single(oracle, 4)
        assert "<target predates oldest observation>" in str(excinfo.value)
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_single_observation_seconds_ago(self, system):
        oracle = system['oracle']
        oracle.initialize((5, 2, 4)) # time, tick, liquidity
        oracle.advance_time(3)
        result = self.observe_single(oracle, 3)
        assert result[0] == 0
        assert result[1] == 0

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_single_observation_in_past_counterfactual_in_past(self, system):
        oracle = system['oracle']
        oracle.initialize((5, 2, 4)) # time, tick, liquidity
        oracle.advance_time(3)
        result = self.observe_single(oracle, 1)
        assert result[0] == 4
        assert result[1] == 170141183460469231731687303715884105728
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_single_observation_in_past_counterfactual_now(self, system):
        oracle = system['oracle']
        oracle.initialize((5, 2, 4)) # time, tick, liquidity
        oracle.advance_time(3)
        result = self.observe_single(oracle, 0)
        assert result[0] == 6
        assert result[1] == 255211775190703847597530955573826158592
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_chronological_zero_seconds_ago_exact(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        result = self.observe_single(oracle, 0)
        assert result[0] == -20
        assert result[1] == 272225893536750770770699685945414569164
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_chronological_zero_seconds_ago_counterfactual(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.advance_time(7)
        result = self.observe_single(oracle, 0)
        assert result[0] == -13
        assert result[1] == 1463214177760035392892510811956603309260
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_chronological_seconds_ago_exactly_first_observation(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.advance_time(7)
        result = self.observe_single(oracle, 11)
        assert result[0] == 0
        assert result[1] == 0

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_chronological_seconds_ago_between(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.advance_time(7)
        result = self.observe_single(oracle, 9)
        assert result[0] == -10
        assert result[1] == 136112946768375385385349842972707284582
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_reverse_order_zero_seconds_ago_exact(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.update((3, -5, 4))
        result = self.observe_single(oracle, 0)
        assert result[0] == -17
        assert result[1] == 782649443918158465965761597093066886348
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_reverse_order_zero_seconds_ago_counterfactual(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.update((3, -5, 4))
        oracle.advance_time(7)
        result = self.observe_single(oracle, 0)
        assert result[0] == -52
        assert result[1] == 1378143586029800777026667160098661256396
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_reverse_order_seconds_ago_exactly_on_first_observation(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.update((3, -5, 4))
        oracle.advance_time(7)
        result = self.observe_single(oracle, 10)
        assert result[0] == -20
        assert result[1] == 272225893536750770770699685945414569164
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_two_observations_reverse_order_seconds_ago_between(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.grow(2)
        oracle.update((4, 1, 2))
        oracle.update((3, -5, 4))
        oracle.advance_time(7)
        result = self.observe_single(oracle, 9)
        assert result[0] == -19
        assert result[1] == 442367076997220002502386989661298674892
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_can_fetch_multiple_observations(self, system):
        oracle = system['oracle']
        oracle.initialize((5, 2, 2 ** 15)) # time, tick, liquidity
        oracle.grow(4)
        oracle.update((13, 6, 2 ** 12))
        oracle.advance_time(5)
        seconds_agos = [0, 3, 8, 13, 15, 18]
        tick_cumulatives, seconds_per_liquidity_cumulatives = oracle.observe(seconds_agos)
        assert tick_cumulatives[0] == 56
        assert tick_cumulatives[1] == 38
        assert tick_cumulatives[2] == 20
        assert tick_cumulatives[3] == 10
        assert tick_cumulatives[4] == 6
        assert tick_cumulatives[5] == 0
        assert seconds_per_liquidity_cumulatives[0] == 550383467004691728624232610897330176
        assert seconds_per_liquidity_cumulatives[1] == 301153217795020002454768787094765568
        assert seconds_per_liquidity_cumulatives[2] == 103845937170696552570609926584401920
        assert seconds_per_liquidity_cumulatives[3] == 51922968585348276285304963292200960
        assert seconds_per_liquidity_cumulatives[4] == 31153781151208965771182977975320576
        assert seconds_per_liquidity_cumulatives[5] == 0

    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_since_most_recent(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5)) # time, tick, liquidity
        oracle.advance_time(2)
        gas_before = boa.env.get_gas_used()
        self.observe_single(oracle, 1)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe since most recent: {gas_used}')
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_current_time(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5))
        gas_before = boa.env.get_gas_used()
        self.observe_single(oracle, 0)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe current time: {gas_used}')
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_current_time_counterfactual(self, system):
        oracle = system['oracle']
        oracle.initialize((5, -5, 5))
        oracle.advance_time(5)
        gas_before = boa.env.get_gas_used()
        self.observe_single(oracle, 0)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe current time counterfactual: {gas_used}')
       
    # @pytest.mark.skip(reason="temporarily disabled") 
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_simple_reads(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        assert oracle.index() == 1
        assert oracle.cardinality() == 5
        assert oracle.cardinality_next() == 5
    
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_latest_observation_same_time_as_latest(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 0)
        assert tick_cumulative == -21
        assert seconds_per_liquidity_cumulative_x128 == 2104079302127802832415199655953100107502
    
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_latest_observation_5_seconds_after_latest(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        oracle.advance_time(5)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 5)
        assert tick_cumulative == -21
        assert seconds_per_liquidity_cumulative_x128 == 2104079302127802832415199655953100107502
        
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_current_observation_5_seconds_after_latest(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        oracle.advance_time(5)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 0)
        assert tick_cumulative == 9
        assert seconds_per_liquidity_cumulative_x128 == 2347138135642758877746181518404363115684
    
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_between_latest_observation_at_latest(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 3)
        assert tick_cumulative == -33
        assert seconds_per_liquidity_cumulative_x128 == 1593655751746395137220137744805447790318
        
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_between_latest_observation_after_latest(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        oracle.advance_time(5)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 8)
        assert tick_cumulative == -33
        assert seconds_per_liquidity_cumulative_x128 == 1593655751746395137220137744805447790318

    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_older_than_oldest_reverts(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        seconds_ago = 15
        
        with pytest.raises(Exception) as excinfo:
            oracle.observe([seconds_ago])
        assert "<target predates oldest observation>" in str(excinfo.value)
        
        oracle.advance_time(5)
        seconds_agos = 20
        
        with pytest.raises(Exception) as excinfo:
            oracle.observe([seconds_agos])
        assert "<target predates oldest observation>" in str(excinfo.value)
        
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_oldest(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 14)
        assert tick_cumulative == -13
        assert seconds_per_liquidity_cumulative_x128 == 544451787073501541541399371890829138329
        
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_oldest_after_time(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        oracle.advance_time(6)
        (tick_cumulative, seconds_per_liquidity_cumulative_x128) = self.observe_single(oracle, 20)
        assert tick_cumulative == -13
        assert seconds_per_liquidity_cumulative_x128 == 544451787073501541541399371890829138329
    
    # @pytest.mark.skip(reason="temporarily disabled")
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(starting_time=st.integers(min_value=0, max_value=2**32 - 1))
    def test_many_observations_fetch_many_values(self, system, starting_time):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, starting_time)
        oracle.advance_time(6)
        seconds_agos = [20, 17, 13, 10, 5, 1, 0]
        (tick_cumulatives, seconds_per_liquidity_cumulatives) = oracle.observe(seconds_agos)
        assert tick_cumulatives[0] == -13
        assert seconds_per_liquidity_cumulatives[0] == 544451787073501541541399371890829138329
        assert tick_cumulatives[1] == -31
        assert seconds_per_liquidity_cumulatives[1] == 799663562264205389138930327464655296921
        assert tick_cumulatives[2] == -43
        assert seconds_per_liquidity_cumulatives[2] == 1045423049484883168306923099498710116305
        assert tick_cumulatives[3] == -37
        assert seconds_per_liquidity_cumulatives[3] == 1423514568285925905488450441089563684590
        assert tick_cumulatives[4] == -15
        assert seconds_per_liquidity_cumulatives[4] == 2152691068830794041481396028443352709138
        assert tick_cumulatives[5] == 9
        assert seconds_per_liquidity_cumulatives[5] == 2347138135642758877746181518404363115684
        assert tick_cumulatives[6] == 15
        assert seconds_per_liquidity_cumulatives[6] == 2395749902345750086812377890894615717321
   
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_last_20_seconds(self, system):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, 0)
        oracle.advance_time(6);
        seconds_agos = [20 - i for i in range(20)]
        gas_before = boa.env.get_gas_used()
        oracle.observe(seconds_agos)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe last 20 seconds: {gas_used}')
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_latest_equal(self, system):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, 5)
        gas_before = boa.env.get_gas_used()
        oracle.observe([0])
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe latest equal: {gas_used}')
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_latest_transform(self, system):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, 5)
        oracle.advance_time(5)
        gas_before = boa.env.get_gas_used()
        oracle.observe([0])
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe latest transform: {gas_used}')
      
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_oldest(self, system):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, 5)
        gas_before = boa.env.get_gas_used()
        oracle.observe([14])
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe oldest: {gas_used}')
        
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_between_oldest_and_oldest_plus_one(self, system):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, 5)
        gas_before = boa.env.get_gas_used()
        oracle.observe([13])
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe between oldest and oldest plus one: {gas_used}')
    
    # @pytest.mark.skip(reason="temporarily disabled")
    def test_gas_cost_of_observe_middle(self, system):
        base_oracle = system['oracle']
        oracle = self.setup_oracle_with_many_observations(base_oracle, 5)
        gas_before = boa.env.get_gas_used()
        oracle.observe([5])
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used observe middle: {gas_used}')