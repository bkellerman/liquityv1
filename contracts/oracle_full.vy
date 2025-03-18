# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

# --- Structs ---
struct Observation:
    block_timestamp: uint32
    tick: int24  # Add tick to the observation
    tick_cumulative: int56
    seconds_per_liquidity_cumulative_x128: uint160
    initialized: bool

struct InitializeParams:
    time: uint32
    tick: int24
    liquidity: uint128

struct UpdateParams:
    advance_time_by: uint32
    tick: int24
    liquidity: uint128

# --- Events ---
event ObservationUpdate:
    block_timestamp: uint32
    tick_cumulative: int56
    seconds_per_liquidity_cumulative_x128: uint160
    tick: int24
    initialized: bool

# --- Constants ---
HALF_MAX_UINT32: constant(uint256) = 2147483648  # 0x80000000

# --- Storage Variables ---
observations: public(Observation[65535])
time: public(uint32)
tick: public(int24)
liquidity: public(uint128)
index: public(uint16)
cardinality: public(uint16)
cardinality_next: public(uint16)

# --- Internal Helper Functions ---
@internal
@view
def _lte(time: uint32, a: uint32, b: uint32) -> bool:
    """
    @notice Helper function to compare timestamps, accounting for uint32 overflow
    @param time The timestamp to compare
    @param a The first timestamp
    @param b The second timestamp
    @return True if a is less than or equal to b, false otherwise
    """
    if convert(a, uint256) < HALF_MAX_UINT32 and convert(b, uint256) < HALF_MAX_UINT32:
        return a <= b
    elif convert(a, uint256) >= HALF_MAX_UINT32 and convert(b, uint256) >= HALF_MAX_UINT32:
        return a <= b
    else:
        return convert(a, uint256) >= HALF_MAX_UINT32

@view
@internal
def _transform(last: Observation, block_timestamp: uint32, tick: int24, liquidity: uint128) -> Observation:

    delta: uint32 = block_timestamp - last.block_timestamp
    if block_timestamp < last.block_timestamp:
        delta = convert(
            (convert(block_timestamp, uint256) + convert(max_value(uint32), uint256) + convert(1, uint256) - convert(last.block_timestamp, uint256)),
            uint32
        )

    seconds_per_liquidity_x128: uint160 = last.seconds_per_liquidity_cumulative_x128
    delta_256: uint256 = convert(delta, uint256)
    shifted: uint256 = delta_256 << 128

    # Handle zero liquidity case
    liquidity_256: uint256 = 0
    if liquidity > 0:
        liquidity_256 = convert(liquidity, uint256)
    else:
        liquidity_256 = 1

    result: uint256 = shifted // liquidity_256
    contribution: uint160 = convert(result, uint160)
    
    # Add contribution unless it's the very first observation
    if last.initialized:
        seconds_per_liquidity_x128 = unsafe_add(
            seconds_per_liquidity_x128,
            contribution
        )

    tick_delta: int56 = convert(tick, int56) * convert(delta, int56)
    new_tick_cumulative: int56 = last.tick_cumulative + tick_delta

    return Observation({
        block_timestamp: unsafe_add(last.block_timestamp, delta),
        tick: tick,
        tick_cumulative: new_tick_cumulative,
        seconds_per_liquidity_cumulative_x128: seconds_per_liquidity_x128,
        initialized: True
    })

@internal
def _write(
    index: uint16,
    block_timestamp: uint32,
    tick: int24,
    liquidity: uint128,
    cardinality: uint16,
    cardinality_next: uint16
) -> (Observation, uint16, uint16):
    
    # log Debug(debug_str)
    # print(debug_str)
    """
    @notice Writes a new observation, growing the observation array if necessary
    @param index The index of the observation to write
    @param block_timestamp The timestamp of the new observation
    @param tick The active tick at the time of the new observation
    @param liquidity The total in-range liquidity at the time of the new observation
    @param cardinality The cardinality of the observation array
    @param cardinality_next The cardinality of the next observation
    @return The new observation, the index of the updated observation and the cardinality of the observation array
    """
    self.liquidity = liquidity

    if self.observations[index].block_timestamp == block_timestamp:
        return self.observations[index], index, cardinality

    new_cardinality: uint16 = cardinality
    if cardinality_next > cardinality and index == (cardinality - 1):
        new_cardinality = cardinality_next
    else:
        new_cardinality = cardinality

    # Calculate next index with proper wrapping
    index_updated: uint16 = (index + 1) % new_cardinality

    new_observation: Observation = self._transform(
        self.observations[index],
        block_timestamp,
        tick,
        self.liquidity  # Pass current liquidity instead of new liquidity
    )

    self.observations[index_updated] = new_observation
    log ObservationUpdate(
        new_observation.block_timestamp,
        new_observation.tick_cumulative,
        new_observation.seconds_per_liquidity_cumulative_x128,
        new_observation.tick,
        new_observation.initialized
    )
    return new_observation, index_updated, new_cardinality

@internal
def _grow(current: uint16, next: uint16) -> uint16:
    """
    @notice Grows the observation array to the desired size
    @param current The current next cardinality of the oracle array
    @param next The proposed next cardinality which will be populated in the oracle array
    @return next The next cardinality which will be populated in the oracle array
    """
    assert current != 0, "oracle cardinality cannot be zero"

    # no-op if the passed next value isn't greater than the current value
    if next <= current:
        return current
        
    # store in each slot to prevent fresh SSTOREs in swaps
    # this data will not be used because the initialized boolean is still false
    for i: uint16 in range(65535):
        if i < current:
            continue
        if i >= next:
            break
        self.observations[i].block_timestamp = 1
        
    return next

@internal
@view
def _binary_search(
    time: uint32,
    target: uint32,
    index: uint16,
    cardinality: uint16
) -> (Observation, Observation, uint16):
    """
    @notice Performs a binary search to find the surrounding observations
    @param time The timestamp to search for
    @param target The target timestamp
    @param index The index of the observation to search from
    @param cardinality The cardinality of the observation array
    @return The surrounding observations and the target index
    """
    # Convert to uint256 to avoid underflow issues
    left: uint256 = convert((index + 1) % cardinality, uint256)  # oldest observation
    right: uint256 = left + convert(cardinality, uint256) - 1  # newest observation
    
    # Initialize return values
    before_or_at: Observation = empty(Observation)
    at_or_after: Observation = empty(Observation)
    target_index: uint16 = 0
    
    # Use range-based iteration with a maximum number of iterations based on max possible cardinality
    # log2(65535) ≈ 16, so 20 iterations is more than enough
    for i: uint256 in range(20):
        if left > right:
            break
            
        current: uint256 = (left + right) // 2
        current_index: uint16 = convert(current % convert(cardinality, uint256), uint16)
        before_or_at = self.observations[current_index]
            
        if not before_or_at.initialized:
            left = current + 1
            continue
            
        next_index: uint16 = convert((current + 1) % convert(cardinality, uint256), uint16)
        at_or_after = self.observations[next_index]

        if self._lte(time, before_or_at.block_timestamp, target):
            if self._lte(time, target, at_or_after.block_timestamp):
                target_index = current_index
                return before_or_at, at_or_after, target_index
            left = current + 1
        else:
            right = current - 1
    
    # If we haven't found a valid observation, revert
    assert False, "binary search failed"
    return empty(Observation), empty(Observation), 0  # Unreachable but needed for compilation

@internal
@view
def _get_surrounding_observations(
    time: uint32,
    target: uint32,
    tick: int24,
    index: uint16,
    liquidity: uint128,
    cardinality: uint16
) -> (Observation, Observation, bool):
    """
    @notice Gets the observations surrounding a target timestamp
    @param time The current block.timestamp
    @param target The target timestamp to find observations around
    @param tick The current tick
    @param index The index of the latest observation
    @param liquidity The current in-range liquidity
    @param cardinality The number of populated observations
    @return The surrounding observations and whether the target is counterfactual
    """
    before_or_at: Observation = self.observations[index]
    at_or_after: Observation = empty(Observation)
    is_counterfactual: bool = False

    # Check if we're at or beyond the latest observation
    if self._lte(time, before_or_at.block_timestamp, target):
        if before_or_at.block_timestamp == target:
            # Get the next observation for interpolation
            if index == 0:
                at_or_after = self.observations[cardinality - 1]
            else:
                at_or_after = self.observations[index - 1]
            if not at_or_after.initialized:
                # If next observation isn't initialized, transform the current one
                at_or_after = self._transform(
                    before_or_at,
                    target + 1,
                    tick,
                    liquidity
                )
                is_counterfactual = True
            return before_or_at, at_or_after, is_counterfactual
        else:
            # Need to transform the latest observation to the target timestamp
            at_or_after = self._transform(
                before_or_at,
                target + 1,
                tick,
                liquidity
            )
            is_counterfactual = True
            return before_or_at, at_or_after, is_counterfactual

    # Get the oldest observation
    oldest_index: uint16 = (index + 1) % cardinality
    before_or_at = self.observations[oldest_index]
    if not before_or_at.initialized:
        before_or_at = self.observations[0]

    assert self._lte(time, before_or_at.block_timestamp, target), "target predates oldest observation"

    # Find the observations around target
    search_before_or_at: Observation = empty(Observation)
    search_at_or_after: Observation = empty(Observation)
    target_index: uint16 = 0
    search_before_or_at, search_at_or_after, target_index = self._binary_search(
        time,
        target,
        index,
        cardinality
    )

    before_or_at = search_before_or_at
    at_or_after = search_at_or_after

    if before_or_at.block_timestamp == target:
        if target_index == (cardinality - 1):
            at_or_after = self.observations[0]
        else:
            at_or_after = self.observations[target_index + 1]
        if not at_or_after.initialized:
            # If next observation isn't initialized, transform the current one
            at_or_after = self._transform(
                before_or_at,
                target + 1,
                tick,
                liquidity
            )
            is_counterfactual = True
    elif at_or_after.block_timestamp == target:
        before_or_at = self.observations[target_index - 1]
    else:
        # If we don't have a valid at_or_after observation, transform the before_or_at
        if not at_or_after.initialized:
            at_or_after = self._transform(
                before_or_at,
                target + 1,
                tick,
                liquidity
            )
            is_counterfactual = True

    return before_or_at, at_or_after, is_counterfactual

@internal
@view
def _observe_single(
    time: uint32,
    seconds_ago: uint32,
    tick: int24,
    index: uint16,
    liquidity: uint128,
    cardinality: uint16
) -> (int56, uint160):
    print("Input - time:", time)
    print("Input - seconds_ago:", seconds_ago)
    print("Input - tick:", tick)
    print("Input - liquidity:", liquidity)

    assert seconds_ago <= time, "seconds_ago is greater than time"
    target: uint32 = time - seconds_ago
    print("Target time:", target)

    before_or_at: Observation = empty(Observation)
    at_or_after: Observation = empty(Observation)
    is_counterfactual: bool = False
    before_or_at, at_or_after, is_counterfactual = self._get_surrounding_observations(
        time,
        target,
        tick,
        index,
        liquidity,
        cardinality
    )

    print("Before observation - timestamp:", before_or_at.block_timestamp)
    print("Before observation - tick_cumulative:", before_or_at.tick_cumulative)
    print("Before observation - seconds_per_liquidity:", before_or_at.seconds_per_liquidity_cumulative_x128)
    
    print("After observation - timestamp:", at_or_after.block_timestamp)
    print("After observation - tick_cumulative:", at_or_after.tick_cumulative)
    print("After observation - seconds_per_liquidity:", at_or_after.seconds_per_liquidity_cumulative_x128)
    
    print("Is counterfactual:", is_counterfactual)

    if target == before_or_at.block_timestamp:
        print("Exact match with before_or_at")
        return before_or_at.tick_cumulative, before_or_at.seconds_per_liquidity_cumulative_x128
    else:
        print("Interpolating between observations")
        
        # Handle uint32 overflow in timestamp arithmetic
        observation_time_delta: uint32 = 0
        if at_or_after.block_timestamp < before_or_at.block_timestamp:
            observation_time_delta = convert(
                (convert(at_or_after.block_timestamp, uint256) + convert(max_value(uint32), uint256) + convert(1, uint256) - convert(before_or_at.block_timestamp, uint256)),
                uint32
            )
        else:
            observation_time_delta = at_or_after.block_timestamp - before_or_at.block_timestamp

        target_delta: uint32 = 0
        if target < before_or_at.block_timestamp:
            target_delta = convert(
                (convert(target, uint256) + convert(max_value(uint32), uint256) + convert(1, uint256) - convert(before_or_at.block_timestamp, uint256)),
                uint32
            )
        else:
            target_delta = target - before_or_at.block_timestamp

        print("Interpolation - target_delta:", target_delta)
        print("Interpolation - time_delta:", observation_time_delta)

        if is_counterfactual:
            # For counterfactual observations, use the current tick and liquidity
            tick_cumulative: int56 = before_or_at.tick_cumulative + convert(tick, int56) * convert(target_delta, int56)
            
            # Calculate seconds per liquidity for counterfactual case
            target_delta_scaled: uint256 = convert(target_delta, uint256) << 128
            effective_liquidity: uint256 = convert(liquidity, uint256)
            if effective_liquidity == 0:
                effective_liquidity = 1
            
            seconds_per_liquidity_delta: uint256 = target_delta_scaled // effective_liquidity
            seconds_per_liquidity_cumulative_x128: uint160 = convert(
                convert(before_or_at.seconds_per_liquidity_cumulative_x128, uint256) + seconds_per_liquidity_delta,
                uint160
            )
            
            return tick_cumulative, seconds_per_liquidity_cumulative_x128
        else:
            # For real observations, interpolate between the points
            tick_delta: int56 = at_or_after.tick_cumulative - before_or_at.tick_cumulative
            tick_cumulative: int56 = before_or_at.tick_cumulative + (tick_delta * convert(target_delta, int56)) // convert(observation_time_delta, int56)
            
            # Convert to uint256 for higher precision arithmetic
            before_spl: uint256 = convert(before_or_at.seconds_per_liquidity_cumulative_x128, uint256)
            after_spl: uint256 = convert(at_or_after.seconds_per_liquidity_cumulative_x128, uint256)
            
            print("Interpolation - before_spl:", before_spl)
            print("Interpolation - after_spl:", after_spl)
            
            # Calculate the delta between observations
            spl_delta: uint256 = after_spl - before_spl
            print("Interpolation - spl_delta:", spl_delta)
            
            # Scale up target_delta by 2^128 for precision
            target_delta_scaled: uint256 = convert(target_delta, uint256) << 128
            time_delta_scaled: uint256 = convert(observation_time_delta, uint256) << 128
            
            # First multiply spl_delta by target_delta_scaled
            intermediate: uint256 = spl_delta * target_delta_scaled
            print("Interpolation - intermediate:", intermediate)
            
            # Then divide by time_delta_scaled
            interpolated_delta: uint256 = intermediate // time_delta_scaled
            print("Interpolation - interpolated_delta:", interpolated_delta)
            
            # Add to the base value
            result: uint256 = before_spl + interpolated_delta
            print("Interpolation - result:", result)
            
            return tick_cumulative, convert(result, uint160)
            
# --- External Functions ---
@external
def initialize(params: InitializeParams):
    """
    @notice Initialize the oracle with the first observation
    @param params The initialization parameters
    """
    assert self.cardinality == 0, "already initialized"
    
    # Set initial state
    self.time = params.time
    self.tick = params.tick
    self.liquidity = params.liquidity
    
    # Create and store first observation
    new_observation: Observation = Observation(
        block_timestamp=params.time,
        tick=params.tick,  # Store the initial tick
        tick_cumulative=0,
        seconds_per_liquidity_cumulative_x128=0,
        initialized=True
    )
    
    self.observations[0] = new_observation
    self.cardinality = 1
    self.cardinality_next = 1
    
    # Log the initialization
    log ObservationUpdate(
        new_observation.block_timestamp,
        new_observation.tick_cumulative,
        new_observation.seconds_per_liquidity_cumulative_x128,
        new_observation.tick,
        new_observation.initialized
    )

@external
def advance_time(by: uint32):
    """
    @notice Advance the oracle time by a specified amount
    @param by The amount of time to advance by
    """
    self.time = unsafe_add(self.time, by)

@external
def update(params: UpdateParams):
    """
    @notice Update the oracle with new observations
    @param params The update parameters
    """
    self.time = unsafe_add(self.time, params.advance_time_by)
    old_index: uint16 = self.index
    new_observation: Observation = empty(Observation)
    next_index: uint16 = 0
    new_cardinality: uint16 = 0
    new_observation, next_index, new_cardinality = self._write(
        old_index,
        self.time,
        params.tick,  # Pass the new tick
        params.liquidity,
        self.cardinality,
        self.cardinality_next
    )
    self.index = next_index
    self.cardinality = new_cardinality
    self.tick = params.tick
    self.liquidity = params.liquidity

@external
def batch_update(params: DynArray[UpdateParams, 300]):
    """
    @notice Update the oracle with multiple observations in a batch
    @param params Array of update parameters
    """
    _tick: int24 = self.tick
    _liquidity: uint128 = self.liquidity
    _index: uint16 = self.index
    _cardinality: uint16 = self.cardinality
    _cardinality_next: uint16 = self.cardinality_next
    _time: uint32 = self.time
    params_length: uint256 = len(params)

    for i: uint256 in range(300):
        if i >= params_length:
            break
        _time = unsafe_add(_time, params[i].advance_time_by)
        new_observation: Observation = empty(Observation)
        new_observation, _index, _cardinality = self._write(
            _index,
            _time,
            _tick,
            _liquidity,
            _cardinality,
            _cardinality_next
        )
        _tick = params[i].tick
        _liquidity = params[i].liquidity

    self.tick = _tick
    self.liquidity = _liquidity
    self.index = _index
    self.cardinality = _cardinality
    self.time = _time

@external
def grow(_cardinality_next: uint16):
    """
    @notice Grow the oracle's observation array to a larger size
    @param _cardinality_next The new desired size of the array
    """
    self.cardinality_next = self._grow(self.cardinality_next, _cardinality_next)

@external
@view
def observe(seconds_agos: DynArray[uint32, 256]) -> (DynArray[int56, 256], DynArray[uint160, 256]):
    """
    @notice Get observations from specified seconds ago
    @param seconds_agos Array of seconds ago to query
    @return Arrays of tick cumulatives and seconds per liquidity cumulatives
    """
    assert self.cardinality > 0, "oracle cardinality cannot be zero"
    tick_cumulatives: DynArray[int56, 256] = []
    seconds_per_liquidity_cumulative_x128s: DynArray[uint160, 256] = []
    
    seconds_agos_length: uint256 = len(seconds_agos)
    
    for i: uint256 in range(256):
        if i >= seconds_agos_length:
            break
            
        tick_cumulative: int56 = 0
        seconds_per_liquidity_cumulative_x128: uint160 = 0
        tick_cumulative, seconds_per_liquidity_cumulative_x128 = self._observe_single(
            self.time,
            seconds_agos[i],
            self.tick,
            self.index,
            self.liquidity,
            self.cardinality
        )
        tick_cumulatives.append(tick_cumulative)
        seconds_per_liquidity_cumulative_x128s.append(seconds_per_liquidity_cumulative_x128)

    return tick_cumulatives, seconds_per_liquidity_cumulative_x128s

@external
@view
def get_gas_cost_of_observe(seconds_agos: DynArray[uint32, 256]) -> uint256:
    """
    @notice Calculate the gas cost of an observe operation
    @param seconds_agos Array of seconds ago to query
    @return The gas cost
    """
    gas_before: uint256 = msg.gas
    
    # Implement observation logic directly instead of calling self.observe
    tick_cumulatives: DynArray[int56, 256] = []
    seconds_per_liquidity_cumulative_x128s: DynArray[uint160, 256] = []
    
    seconds_agos_length: uint256 = len(seconds_agos)
    
    for i: uint256 in range(256):
        if i >= seconds_agos_length:
            break
            
        tick_cumulative: int56 = 0
        seconds_per_liquidity_cumulative_x128: uint160 = 0
        tick_cumulative, seconds_per_liquidity_cumulative_x128 = self._observe_single(
            self.time,
            seconds_agos[i],
            self.tick,
            self.index,
            self.liquidity,
            self.cardinality
        )
        tick_cumulatives.append(tick_cumulative)
        seconds_per_liquidity_cumulative_x128s.append(seconds_per_liquidity_cumulative_x128)
    
    return unsafe_sub(gas_before, msg.gas)