# pragma version ~=0.4.1b5

# Test Contract

round_id: public(uint256)
decimals: public(uint8)
version: public(uint256)
description: public(String[256])
timestamp: public(uint256)
price: public(int256)

@deploy
def __init__(decimals: uint8, version: uint256, description: String[256],
             timestamp: uint256, initial_price: int256):
    self.decimals = decimals
    self.version = version
    self.description = description
    self.timestamp = timestamp
    self.price = initial_price

@external
def set_price(new_price: int256):
    self.price = new_price

## getRoundData and latestRoundData should both raise "No data present"
## if they do not have data to report, instead of returning unset values
## which could be misinterpreted as actual reported values.
#uint80 roundId,
#int256 answer,
#uint256 startedAt,
#uint256 updatedAt,
#uint80 answeredInRound

@external
@view
def getRoundData(round_id: uint80) -> (uint80, int256, uint256, uint256, uint80):
    answer: int256 =  self.price
    started_at: uint256 = self.timestamp - 1000
    updated_at: uint256 = self.timestamp - 900
    answered_in_round: uint80 = round_id

    return round_id, answer, started_at, updated_at, answered_in_round

@external
@view
def latestRoundData() -> (uint80, int256, uint256, uint256, uint80):
    round_id: uint80 = 10
    answer: int256 =  self.price
    started_at: uint256 = self.timestamp
    updated_at: uint256 = self.timestamp + 100
    answered_in_round: uint80 = 10

    return round_id, answer, started_at, updated_at, answered_in_round
