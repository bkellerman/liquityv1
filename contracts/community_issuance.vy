# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable

from interfaces import ILQTYToken
import math
import base

initializes: ownable
# Constants
NAME: constant(String[18]) = "CommunityIssuance"
SECONDS_IN_ONE_MINUTE: constant(uint256) = 60
ISSUANCE_FACTOR: constant(uint256) = 999998681227695000
LQTY_SUPPLY_CAP: constant(uint256) = 32 * 10**24  # 32 million

# State variables
gov_token: public(address)
stability_pool_address: public(address)
total_gov_issued: public(uint256)
deployment_time: public(uint256)

# Events
event LQTYTokenAddressSet:
    gov_token_address: address

event StabilityPoolAddressSet:
    stability_pool_address: address

event TotalLQTYIssuedUpdated:
    total_gov_issued: uint256

@deploy
def __init__():
    ownable.__init__()
    self.deployment_time = block.timestamp

@external
def set_addresses(gov_token_address: address, stability_pool_address: address):
    ownable._check_owner()

    self.gov_token = gov_token_address
    self.stability_pool_address = stability_pool_address

    gov_balance: uint256 = staticcall ILQTYToken(self.gov_token).balanceOf(self)
    assert gov_balance >= LQTY_SUPPLY_CAP, "Insufficient LQTY balance"

    log LQTYTokenAddressSet(gov_token_address)
    log StabilityPoolAddressSet(stability_pool_address)

    ownable.owner = empty(address)

@external
def issue_gov() -> uint256:
    self._require_caller_is_stability_pool()
    latest_total_gov_issued: uint256 = LQTY_SUPPLY_CAP * self._get_cumulative_issuance_fraction() // base.DECIMAL_PRECISION
    issuance: uint256 = latest_total_gov_issued - self.total_gov_issued

    self.total_gov_issued = latest_total_gov_issued
    log TotalLQTYIssuedUpdated(latest_total_gov_issued)
    
    return issuance

@internal
@view
def _get_cumulative_issuance_fraction() -> uint256:
    time_passed_in_minutes: uint256 = (block.timestamp - self.deployment_time) // SECONDS_IN_ONE_MINUTE
    power: uint256 = math._dec_pow(ISSUANCE_FACTOR, time_passed_in_minutes)
    cumulative_issuance_fraction: uint256 = base.DECIMAL_PRECISION - power
    assert cumulative_issuance_fraction <= base.DECIMAL_PRECISION
    return cumulative_issuance_fraction

@external
def send_gov(account: address, gov_amount: uint256):
    self._require_caller_is_stability_pool()
    assert extcall ILQTYToken(self.gov_token).transfer(account, gov_amount)

@internal
@view
def _require_caller_is_stability_pool():
    assert msg.sender == self.stability_pool_address, "CommunityIssuance: caller is not SP"

