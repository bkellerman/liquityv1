# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable
initializes: ownable

from interfaces import ILUSDToken
from interfaces import ILQTYToken

import math

# Constants
NAME: constant(String[12]) = "LQTYStaking"
DECIMAL_PRECISION: constant(uint256) = 10 ** 18

# State variables
stakes: public(HashMap[address, uint256])
total_gov_staked: public(uint256)
f_eth: public(uint256)
f_rd: public(uint256)

gov_token: public(ILQTYToken)
lusd_token: public(ILUSDToken)
trove_manager_address: public(address)
borrower_operations_address: public(address)
active_pool_address: public(address)

struct Snapshot:
    f_eth_snapshot: uint256
    f_lusd_snapshot: uint256

snapshots: public(HashMap[address, Snapshot])

# Events
event LQTYTokenAddressSet:
    gov_token_address: address

event LUSDTokenAddressSet:
    lusd_token_address: address

event TroveManagerAddressSet:
    trove_manager_address: address

event BorrowerOperationsAddressSet:
    borrower_operations_address: address

event ActivePoolAddressSet:
    active_pool_address: address

event StakeChanged:
    staker: address
    new_stake: uint256

event StakingGainsWithdrawn:
    staker: address
    lusd_gain: uint256
    eth_gain: uint256

event F_ETHUpdated:
    f_eth: uint256

event F_RDUpdated:
    f_rd: uint256

event TotalLQTYStakedUpdated:
    total_gov_staked: uint256

event EtherSent:
    account: address
    amount: uint256

@deploy
def __init__():
    ownable.__init__()

@external
def set_addresses(
    gov_token_address: address,
    lusd_token_address: address,
    trove_manager_address: address,
    borrower_operations_address: address,
    active_pool_address: address
):
    ownable._check_owner()

    self.gov_token = ILQTYToken(gov_token_address)
    self.lusd_token = ILUSDToken(lusd_token_address)
    self.trove_manager_address = trove_manager_address
    self.borrower_operations_address = borrower_operations_address
    self.active_pool_address = active_pool_address

    log LQTYTokenAddressSet(gov_token_address)
    log LUSDTokenAddressSet(lusd_token_address)
    log TroveManagerAddressSet(trove_manager_address)
    log BorrowerOperationsAddressSet(borrower_operations_address)
    log ActivePoolAddressSet(active_pool_address)

    ownable.owner = empty(address)

@external
def stake(amount: uint256):
    assert amount > 0, "LQTYStaking: Amount must be non-zero"
    current_stake: uint256 = self.stakes[msg.sender]
    eth_gain: uint256 = self._get_pending_eth_gain(msg.sender)
    lusd_gain: uint256 = self._get_pending_lusd_gain(msg.sender)
    
    self._update_user_snapshots(msg.sender)
    new_stake: uint256 = current_stake + amount
    self.stakes[msg.sender] = new_stake
    self.total_gov_staked += amount

    extcall self.gov_token.send_to_gov_staking(msg.sender, amount)

    log StakeChanged(msg.sender, new_stake)
    log StakingGainsWithdrawn(msg.sender, lusd_gain, eth_gain)

    if current_stake > 0:
        extcall self.lusd_token.transfer(msg.sender, lusd_gain)
        raw_call(msg.sender, b"", value=eth_gain, revert_on_failure=True)
        #send(msg.sender, eth_gain)

@external
def unstake(gov_amount: uint256):
    current_stake: uint256 = self.stakes[msg.sender]
    assert current_stake > 0, "User has no stake"

    eth_gain: uint256 = self._get_pending_eth_gain(msg.sender)
    lusd_gain: uint256 = self._get_pending_lusd_gain(msg.sender)

    self._update_user_snapshots(msg.sender)

    if gov_amount > 0:
        gov_to_withdraw: uint256 = min(gov_amount, current_stake)
        new_stake: uint256 = current_stake - gov_to_withdraw

        self.stakes[msg.sender] = new_stake
        self.total_gov_staked -= gov_to_withdraw
        log TotalLQTYStakedUpdated(self.total_gov_staked)

        extcall self.gov_token.transfer(msg.sender, gov_to_withdraw)
        log StakeChanged(msg.sender, new_stake)

    log StakingGainsWithdrawn(msg.sender, lusd_gain, eth_gain)

    extcall self.lusd_token.transfer(msg.sender, lusd_gain)
    self._send_eth_gain_to_user(eth_gain)

@external
def increase_f_eth(eth_fee: uint256):
    self._require_caller_is_trove_manager()

    eth_fee_per_gov_staked: uint256 = 0
    if self.total_gov_staked > 0:
        eth_fee_per_gov_staked = eth_fee * DECIMAL_PRECISION // self.total_gov_staked

    self.f_eth += eth_fee_per_gov_staked
    log F_ETHUpdated(self.f_eth)

@external
def increase_f_rd(lusd_fee: uint256):
    self._require_caller_is_borrower_operations()


    lusd_fee_per_gov_staked: uint256 = 0
    if self.total_gov_staked > 0:
        lusd_fee_per_gov_staked = lusd_fee * DECIMAL_PRECISION // self.total_gov_staked

    self.f_rd += lusd_fee_per_gov_staked
    log F_RDUpdated(self.f_rd)

@external
def get_pending_eth_gain(user: address) -> uint256:
    return self._get_pending_eth_gain(user)

@internal
def _get_pending_eth_gain(user: address) -> uint256:
    return self.stakes[user] * (self.f_eth - self.snapshots[user].f_eth_snapshot) // DECIMAL_PRECISION

@external
def get_pending_lusd_gain(user: address) -> uint256:
    return self._get_pending_lusd_gain(user)

@internal
def _get_pending_lusd_gain(user: address) -> uint256:
    return self.stakes[user] * (self.f_rd - self.snapshots[user].f_lusd_snapshot) // DECIMAL_PRECISION

@internal
def _update_user_snapshots(user: address):
    self.snapshots[user] = Snapshot(f_eth_snapshot=self.f_eth, f_lusd_snapshot=self.f_rd)

@internal
def _send_eth_gain_to_user(eth_gain: uint256):
    log EtherSent(msg.sender, eth_gain)
    raw_call(msg.sender, b"", value=eth_gain, revert_on_failure=True)
    #send(msg.sender, eth_gain)

@internal
@view
def _require_caller_is_trove_manager():
    assert msg.sender == self.trove_manager_address, "LQTYStaking: caller is not TroveManager"

@internal
@view
def _require_caller_is_borrower_operations():
    assert msg.sender == self.borrower_operations_address, "LQTYStaking: caller is not BorrowerOperations"

@internal
@view
def _require_caller_is_active_pool():
    assert msg.sender == self.active_pool_address, "LQTYStaking: caller is not ActivePool"

@payable
@external
def __default__():
    self._require_caller_is_active_pool()
