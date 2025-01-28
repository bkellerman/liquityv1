# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable
from interfaces import ITellorCaller
from interfaces import AggregatorV3Interface
import base
initializes: ownable

# Constants
NAME: constant(String[10]) = "PriceFeed"
ETHUSD_TELLOR_REQ_ID: constant(uint256) = 1
TARGET_DIGITS: constant(uint8) = 18
TELLOR_DIGITS: constant(uint8) = 6
TIMEOUT: constant(uint256) = 14400  # 4 hours
MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND: constant(uint256) = 5 * 10**17  # 50%
MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES: constant(uint256) = 5 * 10**16  # 5%

# State variables
price_aggregator: public(AggregatorV3Interface)
tellor_caller: public(ITellorCaller)
borrower_operations_address: public(address)
trove_manager_address: public(address)
last_good_price: public(uint256)

# Enum replacement
STATUS_CHAINLINK_WORKING: constant(uint8) = 0
STATUS_USING_TELLOR_CHAINLINK_UNTRUSTED: constant(uint8) = 1
STATUS_BOTH_ORACLES_UNTRUSTED: constant(uint8) = 2
STATUS_USING_TELLOR_CHAINLINK_FROZEN: constant(uint8) = 3
STATUS_USING_CHAINLINK_TELLOR_UNTRUSTED: constant(uint8) = 4

# The current status of the PricFeed, which determines the conditions for the next price fetch attempt
status: public(uint8)

# Events
event LastGoodPriceUpdated:
    last_good_price: uint256

event PriceFeedStatusChanged:
    new_status: uint8

@deploy
def __init__():
    ownable.__init__()

@external
def set_addresses(price_aggregator_address: address, tellor_caller_address: address):
    assert msg.sender == ownable.owner, "Only the owner can call this function"
    
    assert price_aggregator_address != empty(address), "Invalid address"
    assert tellor_caller_address != empty(address), "Invalid address"

    assert price_aggregator_address.is_contract
    assert tellor_caller_address.is_contract

    self.price_aggregator = AggregatorV3Interface(price_aggregator_address)
    self.tellor_caller = ITellorCaller(tellor_caller_address)

    # Explicitly set initial system status
    self.status = STATUS_CHAINLINK_WORKING
    
    chainlink_response: ChainlinkResponse = self._get_current_chainlink_response()
    prev_chainlink_response: ChainlinkResponse = self._get_prev_chainlink_response(chainlink_response.round_id, chainlink_response.decimals)
   
    assert not self._chainlink_is_broken(chainlink_response, prev_chainlink_response) and not self._chainlink_is_frozen(chainlink_response), "PriceFeed: Chainlink must be working and current"
    
    self._store_chainlink_price(chainlink_response)
    ownable.owner = empty(address)

# Placeholder for struct definitions
struct ChainlinkResponse:
    round_id: uint80
    answer: int256
    timestamp: uint256
    success: bool
    decimals: uint8

struct TellorResponse:
    if_retrieve: bool
    value:  uint256
    timestamp: uint256
    success: bool

flag Status:
    chainlink_working
    using_tellor_chainlink_untrusted
    both_oracles_untrusted
    using_tellor_chainlink_frozen
    using_chainlink_tellor_untrusted

@external
def fetch_price() -> uint256:
    chainlink_response: ChainlinkResponse = self._get_current_chainlink_response()
    prev_chainlink_response: ChainlinkResponse = self._get_prev_chainlink_response(chainlink_response.round_id, chainlink_response.decimals)
    tellor_response: TellorResponse = self._get_current_tellor_response()
    # // --- CASE 1: System fetched last price from Chainlink  ---
    if self.status == STATUS_CHAINLINK_WORKING:
        if self._chainlink_is_broken(chainlink_response, prev_chainlink_response):
            if self._tellor_is_broken(tellor_response):
                self._change_status(STATUS_BOTH_ORACLES_UNTRUSTED)
                return self.last_good_price
            if self._tellor_is_frozen(tellor_response):
                self._change_status(STATUS_USING_TELLOR_CHAINLINK_UNTRUSTED)
                return self.last_good_price
            self._change_status(STATUS_USING_TELLOR_CHAINLINK_UNTRUSTED)
            return self._store_tellor_price(tellor_response)
        if self._chainlink_is_frozen(chainlink_response):
            if self._tellor_is_broken(tellor_response):
                self._change_status(STATUS_USING_CHAINLINK_TELLOR_UNTRUSTED)
                return self.last_good_price
            self._change_status(STATUS_USING_TELLOR_CHAINLINK_FROZEN)
            if self._tellor_is_frozen(tellor_response):
                return self.last_good_price
            return self._store_tellor_price(tellor_response)
        return self._store_chainlink_price(chainlink_response)

    # // --- CASE 2: The system fetched last price from Tellor --- 
    if self.status == STATUS_USING_TELLOR_CHAINLINK_UNTRUSTED:
        if self._both_oracles_live_and_unbroken_and_similar_price(chainlink_response, prev_chainlink_response, tellor_response):
            self._change_status(STATUS_CHAINLINK_WORKING)
            return self._store_chainlink_price(chainlink_response)
        if self._tellor_is_broken(tellor_response):
            self._change_status(STATUS_BOTH_ORACLES_UNTRUSTED)
            return self.last_good_price
        return self._store_tellor_price(tellor_response)

    # // --- CASE 3: Both oracles were untrusted at the last price fetch ---
    if self.status == STATUS_BOTH_ORACLES_UNTRUSTED:
        if self._both_oracles_live_and_unbroken_and_similar_price(chainlink_response, prev_chainlink_response, tellor_response):
            self._change_status(STATUS_CHAINLINK_WORKING)
            return self._store_chainlink_price(chainlink_response)
        return self.last_good_price


    # // --- CASE 4: Using Tellor, and Chainlink is frozen ---
    if self.status == STATUS_USING_TELLOR_CHAINLINK_FROZEN:
        if self._chainlink_is_broken(chainlink_response, prev_chainlink_response):
            if self._tellor_is_broken(tellor_response):
                self._change_status(STATUS_BOTH_ORACLES_UNTRUSTED)
                return self.last_good_price
            self._change_status(STATUS_USING_TELLOR_CHAINLINK_UNTRUSTED)
            if self._tellor_is_frozen(tellor_response):
                return self.last_good_price
            return self._store_tellor_price(tellor_response)
        if self._chainlink_is_frozen(chainlink_response):
            if self._tellor_is_broken(tellor_response):
                self._change_status(STATUS_USING_CHAINLINK_TELLOR_UNTRUSTED)
                return self.last_good_price
            if self._tellor_is_frozen(tellor_response):
                return self.last_good_price
            return self._store_tellor_price(tellor_response)
        if self._tellor_is_broken(tellor_response):
            self._change_status(STATUS_USING_CHAINLINK_TELLOR_UNTRUSTED)
            return self._store_chainlink_price(chainlink_response)
        if self._tellor_is_frozen(tellor_response):
            return self.last_good_price
        if self._both_oracles_similar_price(chainlink_response, tellor_response):
            self._change_status(STATUS_CHAINLINK_WORKING)
            return self._store_chainlink_price(chainlink_response)
        self._change_status(STATUS_USING_TELLOR_CHAINLINK_UNTRUSTED)
        return self._store_tellor_price(tellor_response)

    # // --- CASE 5: Using Chainlink, Tellor is untrusted ---
    if self.status == STATUS_USING_CHAINLINK_TELLOR_UNTRUSTED:
        if self._chainlink_is_broken(chainlink_response, prev_chainlink_response):
            self._change_status(STATUS_BOTH_ORACLES_UNTRUSTED)
            return self.last_good_price
        if self._chainlink_is_frozen(chainlink_response):
            return self.last_good_price
        if self._both_oracles_live_and_unbroken_and_similar_price(chainlink_response, prev_chainlink_response, tellor_response):
            self._change_status(STATUS_CHAINLINK_WORKING)
            return self._store_chainlink_price(chainlink_response)
        if self._chainlink_price_change_above_max(chainlink_response, prev_chainlink_response):
            self._change_status(STATUS_BOTH_ORACLES_UNTRUSTED)
            return self.last_good_price
        return self._store_chainlink_price(chainlink_response)

    return 0

# --- Helper functions ---

# Chainlink is considered broken if its current or previous round data is in any way bad. We check the previous round
# for two reasons:
#
# 1) It is necessary data for the price deviation check in case 1,
# and
# 2) Chainlink is the PriceFeed's preferred primary oracle - having two consecutive valid round responses adds
# peace of mind when using or returning to Chainlink.
##


@internal
@view
def _chainlink_is_broken(current_response: ChainlinkResponse, prev_response: ChainlinkResponse) -> bool:
    return self._bad_chainlink_response(current_response) or self._bad_chainlink_response(prev_response)

@internal
@view
def _bad_chainlink_response(response: ChainlinkResponse) -> bool:
    if not response.success:
        return True
    if response.round_id == 0:
        return True
    if response.timestamp == 0 or response.timestamp > block.timestamp:
        return True
    if response.answer <= 0:
        return True
    return False

@internal
@view
def _chainlink_is_frozen(response: ChainlinkResponse) -> bool:
    return block.timestamp - response.timestamp > TIMEOUT

@internal
@pure
def _chainlink_price_change_above_max(current_response: ChainlinkResponse, prev_response: ChainlinkResponse) -> bool:
    current_scaled_price: uint256 = self._scale_chainlink_price_by_digits(convert(current_response.answer, uint256), current_response.decimals)
    prev_scaled_price: uint256 = self._scale_chainlink_price_by_digits(convert(prev_response.answer, uint256), prev_response.decimals)

    min_price: uint256 = min(current_scaled_price, prev_scaled_price)
    max_price: uint256 = max(current_scaled_price, prev_scaled_price)

    percent_deviation: uint256 = (max_price - min_price) * base.DECIMAL_PRECISION // max_price
    return percent_deviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND

@internal
@view
def _tellor_is_broken(response: TellorResponse) -> bool:
    if not response.success:
        return True
    if response.timestamp == 0 or response.timestamp > block.timestamp:
        return True
    if response.value == 0:
        return True
    return False

@internal
@view
def _tellor_is_frozen(tellor_response: TellorResponse) -> bool:
    return block.timestamp - tellor_response.timestamp > TIMEOUT

@internal
@view
def _both_oracles_live_and_unbroken_and_similar_price(
    chainlink_response: ChainlinkResponse,
    prev_chainlink_response: ChainlinkResponse,
    tellor_response: TellorResponse
) -> bool:
    if (
        self._tellor_is_broken(tellor_response)
        or self._tellor_is_frozen(tellor_response)
        or self._chainlink_is_broken(chainlink_response, prev_chainlink_response)
        or self._chainlink_is_frozen(chainlink_response)
    ):
        return False
    return self._both_oracles_similar_price(chainlink_response, tellor_response)

@internal
@pure
def _both_oracles_similar_price(chainlink_response: ChainlinkResponse, tellor_response: TellorResponse) -> bool:
    scaled_chainlink_price: uint256 = self._scale_chainlink_price_by_digits(convert(chainlink_response.answer, uint256), chainlink_response.decimals)
    scaled_tellor_price: uint256 = self._scale_tellor_price_by_digits(tellor_response.value)
    min_price: uint256 = min(scaled_tellor_price, scaled_chainlink_price)
    max_price: uint256 = max(scaled_tellor_price, scaled_chainlink_price)
    percent_price_difference: uint256 = (max_price - min_price) * base.DECIMAL_PRECISION // min_price
    return percent_price_difference <= MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES

@internal
@pure
def _scale_chainlink_price_by_digits(price: uint256, answer_digits: uint8) -> uint256:
    if answer_digits >= TARGET_DIGITS:
        return price // convert(10 ** (answer_digits - TARGET_DIGITS), uint256)
    elif answer_digits < TARGET_DIGITS:
        return price * convert(10 ** (TARGET_DIGITS - answer_digits), uint256)
    return price

@internal
@pure
def _scale_tellor_price_by_digits(price: uint256) -> uint256:
    return price * 10 ** convert((TARGET_DIGITS - TELLOR_DIGITS), uint256)

@internal
def _change_status(new_status: uint8):
    self.status = new_status
    log PriceFeedStatusChanged(new_status)

@internal
def _store_price(current_price: uint256):
    self.last_good_price = current_price
    log LastGoodPriceUpdated(current_price)

@internal
def _store_tellor_price(tellor_response: TellorResponse) -> uint256:
    scaled_tellor_price: uint256 = self._scale_tellor_price_by_digits(tellor_response.value)
    self._store_price(scaled_tellor_price)
    return scaled_tellor_price

@internal
def _store_chainlink_price(chainlink_response: ChainlinkResponse) -> uint256:
    scaled_chainlink_price: uint256 = self._scale_chainlink_price_by_digits(convert(chainlink_response.answer, uint256), chainlink_response.decimals)
    self._store_price(scaled_chainlink_price)
    return scaled_chainlink_price

@internal
@view
def _get_current_tellor_response() -> TellorResponse:
    if_retrieve: bool = False
    value: uint256 = 0
    timestamp_retrieved: uint256 = 0
    success: bool = False
    response: Bytes[65] = b"" 

    success, response = raw_call(
        self.tellor_caller.address,
        abi_encode(ETHUSD_TELLOR_REQ_ID, method_id=method_id("getTellorCurrentValue(uint256)")),
        max_outsize=65,
        is_static_call=True,
        revert_on_failure=False
    )
    if success:
        if_retrieve = convert(slice(response, 0, 1), bool)
        value = convert(slice(response, 1, 32), uint256)
        timestamp_retrieved = convert(slice(response, 33, 32), uint256)
        return TellorResponse(if_retrieve=if_retrieve,
                              value=value,
                              timestamp=timestamp_retrieved,
                              success=True)
    else:
        return TellorResponse(if_retrieve=False, value=0, timestamp=0, success=False)

@internal
@view
def _get_current_chainlink_response() -> ChainlinkResponse:
    chainlink_response: ChainlinkResponse = empty(ChainlinkResponse)

    success: bool = False
    response: Bytes[32] = b"" 

    success, response = raw_call(
        self.price_aggregator.address,
        method_id("decimals()"),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False
    )
    if success:
        chainlink_response.decimals = convert(response, uint8)
    else:
        return chainlink_response

    response_data: Bytes[128] = b""

    success, response_data = raw_call(
        self.price_aggregator.address,
        method_id("latestRoundData()"),
        max_outsize=128,
        is_static_call=True,
        revert_on_failure=False
    )
    if success:
        chainlink_response.round_id = convert(slice(response_data, 0, 32), uint80)
        chainlink_response.answer = convert(slice(response_data, 32, 32), int256)
        chainlink_response.timestamp = convert(slice(response_data, 64, 32), uint256)
        chainlink_response.success = True
        return chainlink_response
    else:
        return chainlink_response


@internal
@view
def _get_prev_chainlink_response(current_round_id: uint80, current_decimals: uint8) -> ChainlinkResponse:
    prev_chainlink_response: ChainlinkResponse = empty(ChainlinkResponse)

    success: bool = False
    response: Bytes[128] = b"" 

    success, response = raw_call(
        self.price_aggregator.address,
        abi_encode(current_round_id - 1, method_id=method_id("getRoundData(uint80)")),
        max_outsize=128,
        is_static_call=True,
        revert_on_failure=False
    )
    assert success
    if success:
        prev_chainlink_response.round_id = convert(slice(response, 0, 32), uint80)
        prev_chainlink_response.answer = convert(slice(response, 32, 32), int256)
        prev_chainlink_response.timestamp = convert(slice(response, 64, 32), uint256)
        prev_chainlink_response.decimals = current_decimals
        prev_chainlink_response.success = True
        return prev_chainlink_response
    else:
        return prev_chainlink_response

