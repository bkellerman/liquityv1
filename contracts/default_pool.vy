# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable
initializes: ownable

from interfaces import ITroveManager
from interfaces import ILUSDToken
from interfaces import IActivePool
from interfaces import IDefaultPool
from interfaces import IPriceFeed
from interfaces import ISortedTroves
from interfaces import ILQTYStaking
from interfaces import ICollSurplusPool

import math

# Constants
NAME: constant(String[12]) = "DefaultPool"

# State variables
trove_manager_address: public(address)
active_pool_address: public(address)
eth_balance: public(uint256)
lusd_debt: public(uint256)

# Events
event TroveManagerAddressChanged:
    new_address: address

event DefaultPoolRDDebtUpdated:
    lusd_debt: uint256

event DefaultPoolETHBalanceUpdated:
    eth_balance: uint256

event EtherSent:
    to: address
    amount: uint256

@deploy
def __init__():
    ownable.__init__()

@external
def set_addresses(
    trove_manager: address,
    active_pool: address
):
    ownable._check_owner()
    self.trove_manager_address = trove_manager
    self.active_pool_address = active_pool
    log TroveManagerAddressChanged(trove_manager)
    log DefaultPoolETHBalanceUpdated(self.eth_balance)

    ownable.owner = empty(address)

@external
@view
def get_eth() -> uint256:
    return self.eth_balance

@external
@view
def get_lusd_debt() -> uint256:
    return self.lusd_debt

@external
def send_eth_to_active_pool(amount: uint256):
    self._require_caller_is_trove_manager()
    #if amount == 0:
    #    return
    self.eth_balance -= amount
    log DefaultPoolETHBalanceUpdated(self.eth_balance)
    log EtherSent(self.active_pool_address, amount)
    raw_call(self.active_pool_address, b"", value=amount, revert_on_failure=True)
    #send(self.active_pool_address, amount)

@external
def increase_lusd_debt(amount: uint256):
    self._require_caller_is_trove_manager()
    self.lusd_debt += amount
    log DefaultPoolRDDebtUpdated(self.lusd_debt)

@external
def decrease_lusd_debt(amount: uint256):
    self._require_caller_is_trove_manager()
    self.lusd_debt -= amount
    log DefaultPoolRDDebtUpdated(self.lusd_debt)

@internal
@view
def _require_caller_is_active_pool():
    assert msg.sender == self.active_pool_address, "DefaultPool: Caller is not the ActivePool"

@internal
@view
def _require_caller_is_trove_manager():
    assert msg.sender == self.trove_manager_address, "DefaultPool: Caller is not the TroveManager"

@payable
@external
def __default__():
    self._require_caller_is_active_pool()
    self.eth_balance += msg.value
    log DefaultPoolETHBalanceUpdated(self.eth_balance)

