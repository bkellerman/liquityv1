# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from ..interfaces.oracles import IChainlinkOracle

# --- Constants ---
NAME: constant(String[16]) = "ChainlinkRelayer"

# --- State variables ---
price_feed: public(IChainlinkOracle)
_sequencer_uptime_feed: IChainlinkOracle
symbol: public(String[256])
multiplier: public(uint256)
stale_threshold: public(uint256)

@deploy
def __init__(
    _price_feed: address,
    __sequencer_uptime_feed: address,
    _stale_threshold: uint256
):
    """ 
    @param _price_feed The address of the Chainlink price feed
    @param __sequencer_uptime_feed The address of the Chainlink sequencer uptime feed
    @param _stale_threshold The threshold after which the price is considered stale
    """
    assert _price_feed != empty(address), "ChainlinkRelayer: Price feed is null"

    assert _stale_threshold != 0, "ChainlinkRelayer: Stale threshold is null"

    self._set_sequencer_uptime_feed(__sequencer_uptime_feed)
    self.price_feed = IChainlinkOracle(_price_feed)
    self.stale_threshold = _stale_threshold
    
    self.multiplier = 18 - convert(staticcall self.price_feed.decimals(), uint256)
    self.symbol = staticcall self.price_feed.description()

@external
@view
def sequencer_uptime_feed() -> IChainlinkOracle:
    """
    @notice Returns the address of the sequencer uptime feed
    @return __sequencer_uptime_feed The address of the sequencer uptime feed
    """
    return self._sequencer_uptime_feed

@external
@view
def get_result_with_validity() -> (uint256, bool):
    """
    @notice Gets the price and validity from the oracle
    @return _result The price from the oracle
    @return _validity Whether the price is valid
    """
    # Fetch values from Chainlink
    round_id: uint80 = 0
    feed_result: int256 = 0
    started_at: uint256 = 0
    feed_timestamp: uint256 = 0
    answered_in_round: uint80 = 0
    
    round_id, feed_result, started_at, feed_timestamp, answered_in_round = staticcall self.price_feed.latestRoundData()
    
    # Parse the quote into 18 decimals format
    result: uint256 = self._parse_result(feed_result)
    
    # Check if the price is valid
    validity: bool = feed_result > 0 and self._is_valid_feed(feed_timestamp)
    
    return result, validity

@external
@view
def read() -> uint256:
    """
    @notice Reads the price from the oracle
    @return _result The price from the oracle
    """
    # Fetch values from Chainlink
    round_id: uint80 = 0
    feed_result: int256 = 0
    started_at: uint256 = 0
    feed_timestamp: uint256 = 0
    answered_in_round: uint80 = 0
    
    round_id, feed_result, started_at, feed_timestamp, answered_in_round = staticcall self.price_feed.latestRoundData()
    
    # Revert if price is invalid
    assert feed_result > 0 and self._is_valid_feed(feed_timestamp), "ChainlinkRelayer: InvalidPriceFeed"
    
    # Parse the quote into 18 decimals format
    return self._parse_result(feed_result)

@internal
@view
def _parse_result(feed_result: int256) -> uint256:
    """
    @notice Parses the result from the price feed into 18 decimals format
    @param feed_result The result from the price feed
    @return _result The parsed result
    """
    return convert(feed_result, uint256) * 10 ** self.multiplier

@internal
@view
def _is_valid_feed(feed_timestamp: uint256) -> bool:
    """
    @notice Checks if the feed is valid, considering the sequencer status, the stale_threshold and the feed timestamp
    @param feed_timestamp The timestamp of the feed
    @return _valid Whether the feed is valid
    """
    # Check the sequencer status
    round_id: uint80 = 0
    feed_status: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    
    round_id, feed_status, started_at, updated_at, answered_in_round = staticcall self._sequencer_uptime_feed.latestRoundData()
    
    # Status == 0: Sequencer is up
    # Status == 1: Sequencer is down
    is_sequencer_up: bool = feed_status == 0
    if not is_sequencer_up:
        return False
    
    # Make sure the stale_threshold has not passed after the feed timestamp
    time_since_feed: uint256 = block.timestamp - feed_timestamp
    return time_since_feed <= self.stale_threshold

@internal
def _set_sequencer_uptime_feed(sequencer_feed: address):
    """
    @notice Sets the Chainlink sequencer uptime feed contract address
    @param sequencer_feed The address of the sequencer uptime feed
    """
    assert sequencer_feed != empty(address), "ChainlinkRelayer: Sequencer feed is null"
    
    self._sequencer_uptime_feed = IChainlinkOracle(sequencer_feed)