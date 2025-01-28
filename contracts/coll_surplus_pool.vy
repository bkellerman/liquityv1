# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.auth import ownable

from interfaces import ITroveManager
import base

initializes: ownable

# Constants
NAME: constant(String[16]) = "CollSurplusPool"

# State variables
borrower_operations_address: public(address)
trove_manager_address: public(address)
active_pool_address: public(address)
eth_balance: uint256
balances: public(HashMap[address, uint256])

# Events
event BorrowerOperationsAddressChanged:
    new_borrower_operations_address: address

event TroveManagerAddressChanged:
    new_trove_manager_address: address

event ActivePoolAddressChanged:
    new_active_pool_address: address

event CollBalanceUpdated:
    account: address
    new_balance: uint256

event EtherSent:
    to: address
    amount: uint256

@deploy
def __init__():
    ownable.__init__()

@external
def set_addresses(
    borrower_operations: address,
    trove_manager: address,
    active_pool: address
):
    #assert msg.sender == self.owner, "Only the owner can call this function"
    ownable._check_owner()

    self.borrower_operations_address = borrower_operations
    self.trove_manager_address = trove_manager
    self.active_pool_address = active_pool

    log BorrowerOperationsAddressChanged(borrower_operations)
    log TroveManagerAddressChanged(trove_manager)
    log ActivePoolAddressChanged(active_pool)

    #self._renounce_ownership()
    ownable.owner = empty(address)

@external
@view
def get_eth() -> uint256:
    return self.eth_balance

@external
@view
def get_collateral(account: address) -> uint256:
    return self.balances[account]

@external
def account_surplus(account: address, amount: uint256):
    self._require_caller_is_trove_manager()

    new_amount: uint256 = self.balances[account] + amount
    self.balances[account] = new_amount

    log CollBalanceUpdated(account, new_amount)

@external
def claim_coll(account: address):
    self._require_caller_is_borrower_operations()
    claimable_coll: uint256 = self.balances[account]
    assert claimable_coll > 0, "CollSurplusPool: No collateral available to claim"

    self.balances[account] = 0
    log CollBalanceUpdated(account, 0)

    self.eth_balance -= claimable_coll
    log EtherSent(account, claimable_coll)

    raw_call(account, b"", value=claimable_coll, revert_on_failure=True)
    #send(account, claimable_coll)

@internal
@view
def _require_caller_is_borrower_operations():
    assert msg.sender == self.borrower_operations_address, "CollSurplusPool: Caller is not Borrower Operations"

@internal
@view
def _require_caller_is_trove_manager():
    assert msg.sender == self.trove_manager_address, "CollSurplusPool: Caller is not TroveManager"

@internal
@view
def _require_caller_is_active_pool():
    assert msg.sender == self.active_pool_address, "CollSurplusPool: Caller is not Active Pool"

@payable
@external
def __default__():
    self._require_caller_is_active_pool()
    self.eth_balance += msg.value

