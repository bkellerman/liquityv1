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

# @dev The minimum tick that may be passed to get_sqrt_price_at_tick computed from log base 1.0001 of 2**-128
MIN_TICK: constant(int24) = -887272
# @dev The maximum tick that may be passed to get_sqrt_price_at_tick computed from log base 1.0001 of 2**128
MAX_TICK: constant(int24) = 887272

# @dev The minimum tick spacing value >= 1
MIN_TICK_SPACING: constant(int24) = 1
# @dev The maximum tick spacing value (int16 max)
MAX_TICK_SPACING: constant(int24) = 32767 # Vyper doesn't have type(int16).max directly as constant

# @dev The minimum value that can be returned from get_sqrt_price_at_tick. Equivalent to get_sqrt_price_at_tick(MIN_TICK)
MIN_SQRT_PRICE: constant(uint160) = 4295128739
# @dev The maximum value that can be returned from get_sqrt_price_at_tick. Equivalent to get_sqrt_price_at_tick(MAX_TICK)
MAX_SQRT_PRICE: constant(uint160) = 1461446703485210103287273052203988822378723970342
# @dev A threshold used for optimized bounds check, equals `MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1`
MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE: constant(uint160) = MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1


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

@internal
@pure
def _transform(
    last: Observation,
    block_timestamp: uint32,
    tick: int24,
    liquidity: uint128
) -> Observation:
    # Handle uint32 overflow in timestamp arithmetic
    delta: uint32 = 0
    if block_timestamp < last.block_timestamp:
        delta = convert(
            (convert(block_timestamp, uint256) + convert(max_value(uint32), uint256) + convert(1, uint256) - convert(last.block_timestamp, uint256)),
            uint32
        )
    else:
        delta = block_timestamp - last.block_timestamp

    # Calculate seconds_per_liquidity_cumulative_x128
    seconds_shifted: uint256 = convert(delta, uint256) << 128
    effective_liquidity: uint256 = 0
    if liquidity > 0:
        effective_liquidity = convert(liquidity, uint256)
    else:
        effective_liquidity = 1

    seconds_per_liquidity_delta: uint256 = seconds_shifted // effective_liquidity
    
    # Handle uint160 overflow for seconds_per_liquidity_cumulative_x128
    mask_160: uint256 = (1 << 160) - 1
    new_seconds_per_liquidity_cumulative: uint160 = convert(
        (convert(last.seconds_per_liquidity_cumulative_x128, uint256) + seconds_per_liquidity_delta) & mask_160,
        uint160
    )
    new_tick_cumulative: int56 = last.tick_cumulative + (convert(tick, int56) * convert(delta, int56))
    return Observation(
        block_timestamp=block_timestamp,
        tick=tick,
        tick_cumulative=new_tick_cumulative,
        seconds_per_liquidity_cumulative_x128=new_seconds_per_liquidity_cumulative,
        initialized=True
    )

@internal
def _write(
    index: uint16,
    block_timestamp: uint32,
    tick: int24,
    liquidity: uint128,
    cardinality: uint16,
    cardinality_next: uint16
) -> (Observation, uint16, uint16):
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
    lastObservation: Observation = self.observations[index]

    # early return if we've already written an observation this block
    if lastObservation.block_timestamp == block_timestamp:
        return lastObservation, index, cardinality

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
        self.liquidity
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
    @notice Find observations around target timestamp using binary search
    @dev Uses for loop with max iterations of log2(65535) ≈ 16
    """
    left: uint256 = convert((index + 1) % cardinality, uint256)
    right: uint256 = left + convert(cardinality, uint256) - 1
    
    # Maximum 20 iterations (more than enough since log2(65535) ≈ 16)
    for i: uint256 in range(20):
        if left > right:
            break
            
        mid: uint256 = (left + right) // 2
        current_index: uint16 = convert(mid % convert(cardinality, uint256), uint16)
        before_or_at: Observation = self.observations[current_index]
        
        if not before_or_at.initialized:
            left = mid + 1
            continue
            
        next_index: uint16 = convert((mid + 1) % convert(cardinality, uint256), uint16)
        at_or_after: Observation = self.observations[next_index]

        if self._lte(time, before_or_at.block_timestamp, target):
            if self._lte(time, target, at_or_after.block_timestamp):
                return before_or_at, at_or_after, current_index
            left = mid + 1
        else:
            right = mid - 1
    
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
            return before_or_at, at_or_after, is_counterfactual
        else:
            # Need to transform the latest observation to the target timestamp
            at_or_after = self._transform(
                before_or_at,
                target,
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
def _calculate_counterfactual(
    before_or_at: Observation,
    target_delta: uint32,
    liquidity: uint128
) -> (int56, uint160):
    """
    @notice Calculate tick and liquidity values for counterfactual case
    @param before_or_at The observation before target
    @param target_delta Time difference from before_or_at to target
    @param liquidity Current liquidity
    @return Calculated tick cumulative and seconds per liquidity cumulative
    """
    # Calculate tick cumulative
    tick_cumulative: int56 = before_or_at.tick_cumulative + convert(before_or_at.tick, int56) * convert(target_delta, int56)
    
    # Calculate seconds per liquidity
    seconds_shifted: uint256 = convert(target_delta, uint256) << 128
    effective_liquidity: uint256 = convert(liquidity, uint256)
    if effective_liquidity == 0:
        effective_liquidity = 1
    seconds_per_liquidity_delta: uint256 = seconds_shifted // effective_liquidity
    seconds_per_liquidity_cumulative_x128: uint160 = convert(
        convert(before_or_at.seconds_per_liquidity_cumulative_x128, uint256) + seconds_per_liquidity_delta,
        uint160
    )
    
    return tick_cumulative, seconds_per_liquidity_cumulative_x128

@internal
@view
def _interpolate(
    before_or_at: Observation,
    at_or_after: Observation,
    target_delta: uint32
) -> (int56, uint160):
    """
    @notice Interpolate values between two observations
    @param before_or_at The observation before target
    @param at_or_after The observation after target
    @param target_delta Time difference from before_or_at to target
    @return Interpolated tick cumulative and seconds per liquidity cumulative
    """
    # Calculate time delta between observations
    observation_time_delta: uint32 = 0
    if at_or_after.block_timestamp < before_or_at.block_timestamp:
        observation_time_delta = convert(
            (convert(at_or_after.block_timestamp, uint256) + convert(max_value(uint32), uint256) + convert(1, uint256) - convert(before_or_at.block_timestamp, uint256)),
            uint32
        )
    else:
        observation_time_delta = at_or_after.block_timestamp - before_or_at.block_timestamp

    # Interpolate tick cumulative
    tick_delta: int56 = at_or_after.tick_cumulative - before_or_at.tick_cumulative
    tick_cumulative: int56 = before_or_at.tick_cumulative + (tick_delta * convert(target_delta, int56)) // convert(observation_time_delta, int56)
    
    # Interpolate seconds per liquidity cumulative
    seconds_per_liquidity_delta: uint256 = convert(
        at_or_after.seconds_per_liquidity_cumulative_x128 - before_or_at.seconds_per_liquidity_cumulative_x128,
        uint256
    )
    seconds_per_liquidity_cumulative_x128: uint160 = convert(
        convert(before_or_at.seconds_per_liquidity_cumulative_x128, uint256) + 
        (seconds_per_liquidity_delta * convert(target_delta, uint256)) // convert(observation_time_delta, uint256),
        uint160
    )
    
    return tick_cumulative, seconds_per_liquidity_cumulative_x128

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
    """
    @notice Get a single observation from seconds ago
    @param time Current timestamp
    @param seconds_ago Number of seconds in the past to look up
    @param tick Current tick
    @param index Current observation index
    @param liquidity Current liquidity
    @param cardinality Number of observations stored
    @return tick_cumulative and seconds_per_liquidity_cumulative_x128
    """
    assert seconds_ago <= time, "seconds_ago is greater than time"
    
    # Case 1: Current timestamp (no historical lookup needed)
    if seconds_ago == 0:
        last_observation: Observation = self.observations[index]
        if last_observation.block_timestamp != time:
            last_observation = self._transform(last_observation, time, tick, liquidity)
        return last_observation.tick_cumulative, last_observation.seconds_per_liquidity_cumulative_x128
    
    # Case 2: Historical timestamp lookup
    target: uint32 = time - seconds_ago
    before_or_at: Observation = empty(Observation)
    at_or_after: Observation = empty(Observation)
    is_counterfactual: bool = False
    before_or_at, at_or_after, is_counterfactual = self._get_surrounding_observations(
        time, target, tick, index, liquidity, cardinality
    )

    # Case 2a: Exact match with existing observation
    if target == before_or_at.block_timestamp:
        return before_or_at.tick_cumulative, before_or_at.seconds_per_liquidity_cumulative_x128
    if target == at_or_after.block_timestamp:
        return at_or_after.tick_cumulative, at_or_after.seconds_per_liquidity_cumulative_x128

    # Case 2b: Interpolation needed
    target_delta: uint32 = target - before_or_at.block_timestamp
    
    if is_counterfactual:
        return self._calculate_counterfactual(before_or_at, target_delta, liquidity)
    else:
        return self._interpolate(before_or_at, at_or_after, target_delta)

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
        self.tick,
        self.liquidity,
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
            self.liquidity,
            _cardinality,
            _cardinality_next
        )
        _tick = params[i].tick
        _liquidity = params[i].liquidity
        self.liquidity = params[i].liquidity

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

@external
def get_sqrt_price_at_tick(tick: int24) -> uint160:
    """
    @notice Calculates sqrt(1.0001^tick) * 2^96
    @dev Throws if |tick| > MAX_TICK
    @param tick The input tick for the above formula
    @return sqrt_price_x96 A Fixed point Q64.96 number representing the sqrt price
    """
    # Calculate absolute value of tick
    abs_tick_int: int256 = abs(convert(tick, int256))
    abs_tick: uint256 = convert(abs_tick_int, uint256)

    # Check if tick is within bounds
    # assert self.cardinality > 0, "oracle cardinality cannot be zero"
    assert abs_tick <= convert(MAX_TICK, uint256), "tick out of bounds"

    # Calculate price iteratively based on bits of abs_tick
    # Start with price = 1 * 2^128 (Q128.128 representation)
    # Constants are 1/sqrt(1.0001^(2^i)) * 2^128, rounded
    price: uint256 = 1 << 128 # Q128.128

    if (abs_tick & convert(0x01, uint256)) != 0:
        price = (price * convert(0xfffcb933bd6fad37aa2d162d1a594001, uint256)) >> 128
    if (abs_tick & convert(0x02, uint256)) != 0:
        price = (price * convert(0xfff97272373d413259a46990580e213a, uint256)) >> 128
    if (abs_tick & convert(0x04, uint256)) != 0:
        price = (price * convert(0xfff2e50f5f656932ef12357cf3c7fdcc, uint256)) >> 128
    if (abs_tick & convert(0x08, uint256)) != 0:
        price = (price * convert(0xffe5caca7e10e4e61c3624eaa0941cd0, uint256)) >> 128
    if (abs_tick & convert(0x10, uint256)) != 0:
        price = (price * convert(0xffcb9843d60f6159c9db58835c926644, uint256)) >> 128
    if (abs_tick & convert(0x20, uint256)) != 0:
        price = (price * convert(0xff973b41fa98c081472e6896dfb254c0, uint256)) >> 128
    if (abs_tick & convert(0x40, uint256)) != 0:
        price = (price * convert(0xff2ea16466c96a3843ec78b326b52861, uint256)) >> 128
    if (abs_tick & convert(0x80, uint256)) != 0:
        price = (price * convert(0xfe5dee046a99a2a811c461f1969c3053, uint256)) >> 128
    if (abs_tick & convert(0x0100, uint256)) != 0:
        price = (price * convert(0xfcbe86c7900a88aedcffc83b479aa3a4, uint256)) >> 128
    if (abs_tick & convert(0x0200, uint256)) != 0:
        price = (price * convert(0xf987a7253ac413176f2b074cf7815e54, uint256)) >> 128
    if (abs_tick & convert(0x0400, uint256)) != 0:
        price = (price * convert(0xf3392b0822b70005940c7a398e4b70f3, uint256)) >> 128
    if (abs_tick & convert(0x0800, uint256)) != 0:
        price = (price * convert(0xe7159475a2c29b7443b29c7fa6e889d9, uint256)) >> 128
    if (abs_tick & convert(0x1000, uint256)) != 0:
        price = (price * convert(0xd097f3bdfd2022b8845ad8f792aa5825, uint256)) >> 128
    if (abs_tick & convert(0x2000, uint256)) != 0:
        price = (price * convert(0xa9f746462d870fdf8a65dc1f90e061e5, uint256)) >> 128
    if (abs_tick & convert(0x4000, uint256)) != 0:
        price = (price * convert(0x70d869a156d2a1b890bb3df62baf32f7, uint256)) >> 128
    if (abs_tick & convert(0x8000, uint256)) != 0:
        price = (price * convert(0x31be135f97d08fd981231505542fcfa6, uint256)) >> 128
    if (abs_tick & convert(0x010000, uint256)) != 0:
        price = (price * convert(0x09aa508b5b7a84e1c677de54f3e99bc9, uint256)) >> 128
    if (abs_tick & convert(0x020000, uint256)) != 0:
        price = (price * convert(0x5d6af8dedb81196699c329225ee604, uint256)) >> 128
    if (abs_tick & convert(0x040000, uint256)) != 0:
        price = (price * convert(0x2216e584f5fa1ea926041bedfe98, uint256)) >> 128
    if (abs_tick & convert(0x080000, uint256)) != 0:
        price = (price * convert(0x048a170391f7dc42444e8fa2, uint256)) >> 128

    # If tick is positive, price = 1 / price (in fixed point)
    # price = (1 * 2^128 * 2^128) / price = 2^256 / price
    if tick > 0:
        # Using max_value(uint256) approximates 2^256 for the division
        # Vyper division truncates, matching Solidity's `div` opcode behaviour here
        price = max_value(uint256) // price

    # Convert Q128.128 to Q64.96 by dividing by 2^32 and rounding up.
    # (price + 2^32 - 1) / 2^32 === shift(price + 2^32 - 1, -32)
    shift_amount: uint256 = 32
    divisor: uint256 = 1 << shift_amount
    price_plus_max_u32: uint256 = price + (divisor - 1)
    # Assuming shift_amount holds the POSITIVE number of bits to shift right (e.g., 96)
    sqrt_price_x96_u256: uint256 = price_plus_max_u32 >> shift_amount
    
    # Result fits in uint160 due to tick constraints
    return convert(sqrt_price_x96_u256, uint160)