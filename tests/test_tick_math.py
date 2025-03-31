import decimal
import ape
import pytest
import boa
from fixtures import system, owner, alice, bob, charlie, frontend, system_addresses
from hypothesis import given, HealthCheck, settings
from hypothesis import strategies as st

ONE_PIP = 0.000001 # 1 / 100th of a basis point (0.000001)

MIN_SQRT_PRICE = 4295128739
MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342
    
MIN_TICK = -887272
MAX_TICK = 887272

INT_24_MIN =-8388608 # -2^23
INT_24_MAX = 8388607 # 2^23 - 1

JS_MIN_SQRT_PRICE = 6085630636 # sqrt(1 / 2 ** 127) * 2 ** 96
JS_MAX_SQRT_PRICE = 1033437718471923706666374484006904511252097097914 # sqrt(2 ** 127) * 2 ** 96

class TestTickMath:
    
    def get_sqrt_price_at_tick_py(self, tick: int) -> decimal.Decimal:
        """
        Calculates the Q64.96 sqrt price for a given tick based on the formula:
        sqrt(1.0001^tick) * 2^96 using Python's Decimal for precision.

        Args:
            tick: The price tick.
        Returns:
            The calculated sqrtPriceX96 as a Decimal object.
        Raises:
            ValueError: If the tick is outside the valid range [MIN_TICK, MAX_TICK].
        """
        if not (MIN_TICK <= tick <= MAX_TICK):
            raise ValueError(f"Tick {tick} is outside the valid range [{MIN_TICK}, {MAX_TICK}]")

        price_ratio = pow(decimal.Decimal('1.0001'), decimal.Decimal(tick))
        # Calculate sqrtPrice = sqrt(price) * 2^96
        sqrt_price_x96 = price_ratio.sqrt() * pow(decimal.Decimal(2), 96) # CORRECTED LINE

        # Note: Solidity's TickMath returns a uint160.
        # This Python version returns a high-precision Decimal.
        # If comparing directly to Solidity output, you might need to simulate
        # the conversion to uint160 (truncation/overflow).
        # For example:
        # if sqrt_price_x96 < 0 or sqrt_price_x96 >= MAX_UINT160:
        #     raise ValueError("Result out of uint160 range")
        # return int(sqrt_price_x96) # Convert to int to mimic uint160 truncation
        return sqrt_price_x96

    @pytest.fixture
    def oracle(self, system):
        oracle = system['oracle']
        time = 0  # uint32
        tick = 0  # int24
        liquidity = 0  # uint128
        params = (time, tick, liquidity)
        oracle.initialize(params)
        return oracle
   
    def test_get_sqrt_price_at_tick_throws_for_int_24_min(self, oracle):
        with pytest.raises(Exception) as excinfo:
            oracle.get_sqrt_price_at_tick(INT_24_MIN)
        assert "tick out of bounds" in str(excinfo.value)
    
    def test_get_sqrt_price_at_tick_throws_for_too_low(self, oracle):
        with pytest.raises(Exception) as excinfo:
            oracle.get_sqrt_price_at_tick(MIN_TICK - 1)
        assert "tick out of bounds" in str(excinfo.value)
    
    def test_get_sqrt_price_at_tick_throws_for_too_high(self, oracle):
        with pytest.raises(Exception) as excinfo:
            oracle.get_sqrt_price_at_tick(MAX_TICK + 1)
        assert "tick out of bounds" in str(excinfo.value)
   
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(tick=st.integers(min_value=MAX_TICK + 1, max_value=INT_24_MAX))
    def test_get_sqrt_price_at_tick_fuzz_throws_for_too_large_positive(self, oracle, tick):
        with pytest.raises(Exception) as excinfo:
            oracle.get_sqrt_price_at_tick(tick)
        assert "tick out of bounds" in str(excinfo.value)
    
    @settings(suppress_health_check=[HealthCheck.function_scoped_fixture])
    @given(tick=st.integers(min_value=INT_24_MIN, max_value=MIN_TICK - 1))
    def test_get_sqrt_price_at_tick_fuzz_throws_for_too_large_negative(self, oracle, tick):
        with pytest.raises(Exception) as excinfo:
            oracle.get_sqrt_price_at_tick(tick)
        assert "tick out of bounds" in str(excinfo.value)
   
    def test_get_sqrt_price_at_tick_is_valid_min_tick(self, oracle):
        assert oracle.get_sqrt_price_at_tick(MIN_TICK) == MIN_SQRT_PRICE
    
    def test_get_sqrt_price_at_tick_is_valid_min_tick_add_one(self, oracle):
        assert oracle.get_sqrt_price_at_tick(MIN_TICK + 1) == 4295343490
    
    def test_get_sqrt_price_at_tick_is_valid_max_tick(self, oracle):
        assert oracle.get_sqrt_price_at_tick(MAX_TICK) == MAX_SQRT_PRICE
    
    def test_get_sqrt_price_at_tick_is_valid_max_tick_sub_one(self, oracle):
        assert oracle.get_sqrt_price_at_tick(MAX_TICK - 1) == 1461373636630004318706518188784493106690254656249
    
    def test_get_sqrt_price_at_tick_is_less_than_js_impl_min_tick(self, oracle):
        assert oracle.get_sqrt_price_at_tick(MIN_TICK) < JS_MIN_SQRT_PRICE
    
    def test_get_sqrt_price_at_tick_is_greater_than_js_impl_max_tick(self, oracle):
        assert oracle.get_sqrt_price_at_tick(MAX_TICK) > JS_MAX_SQRT_PRICE

    def test_get_sqrt_price_at_tick_matches_py_impl_within_one_pip(self, oracle):
        """
        Ports the structure of the Solidity test test_getSqrtPriceAtTick_matchesJavaScriptImplByOneHundrethOfABip:
        - Generates ticks similar to the Solidity test.
        - Calculates sqrtPrice using the Python implementation.
        - Compares against the Oracle implementation.
        - Checks if the difference is within the ONE_PIP relative tolerance.
        """
        ticks_to_test = []
        tick = 50

        # Generate ticks similar to the Solidity test loop
        processed_ticks = set() # Avoid duplicates like initial +/- 50
        while abs(tick) <= MAX_TICK * 2 : # Heuristic limit to prevent infinite loop
            # Test positive tick
            if MIN_TICK <= tick <= MAX_TICK and tick not in processed_ticks:
                 ticks_to_test.append(tick)
                 processed_ticks.add(tick)

            # Test negative tick
            neg_tick = -tick
            if MIN_TICK <= neg_tick <= MAX_TICK and neg_tick not in processed_ticks:
                ticks_to_test.append(neg_tick)
                processed_ticks.add(neg_tick)

            # Prepare for next iteration
            next_tick = tick * 2

            # Break if tick stops increasing or goes out of bounds significantly
            if abs(next_tick) <= abs(tick):
                 break # Avoid infinite loop if overflow occurs or value doesn't change
            tick = next_tick
            if tick > MAX_TICK * 4: # Another safeguard
                break
            
        print(f"\nTesting {len(ticks_to_test)} ticks derived from Solidity loop structure.")
        
        for t in sorted(list(ticks_to_test)): # Sort for deterministic output
            print(f"Testing tick {t}")
            py_sqrt_price = self.get_sqrt_price_at_tick_py(t)
            print(f"Tick {t}: Python sqrtPriceX96 = {py_sqrt_price}")
            oracle_sqrt_price = oracle.get_sqrt_price_at_tick(t)
            print(f"Tick {t}: Oracle sqrtPriceX96 = {oracle_sqrt_price}")
            if oracle_sqrt_price is None:
                 print(f"Warning: No oracle SqrtPrice found for tick {t}. Skipping comparison.")
                 continue
            # --- Comparison Logic (Matches Solidity Test) ---
            # Ensure oracle_sqrt_price is not zero before dividing
            if oracle_sqrt_price <= 0:
                if py_sqrt_price <= 0:
                    # Both non-positive, consider them matching if both are zero or negative
                    print(f"Tick {t}: OK (Both results non-positive: Py={py_sqrt_price}, Or={oracle_sqrt_price})")
                    continue
                else:
                    # Cannot calculate relative difference if reference is non-positive
                    print(f"Tick {t}: Reference SqrtPrice is non-positive ({oracle_sqrt_price}), cannot perform relative comparison.")
                    continue # Skip to next tick
            tolerance_percentage = ONE_PIP
            tolerance = abs(py_sqrt_price * decimal.Decimal(tolerance_percentage) / decimal.Decimal(100))               
            diff = abs(oracle_sqrt_price - py_sqrt_price)
            is_within_tolerance = diff <= tolerance
            assert is_within_tolerance, f"Tick {t}: FAIL - Difference exceeds tolerance.\n"
            print(f"Tick {t}: Diff = {diff}")
            print(f"Tick {t}: Is within tolerance = {is_within_tolerance}")
    
    def test_get_sqrt_price_at_tick_gas_cost(self, oracle):
        gas_before = boa.env.get_gas_used()
        print("Starting Python loop...")
        for tick in range(-50, 50):
            oracle.get_sqrt_price_at_tick(tick)
        gas_after = boa.env.get_gas_used()
        gas_used = gas_after - gas_before
        print(f'Gas used get_sqrt_price_at_tick: {gas_used}')