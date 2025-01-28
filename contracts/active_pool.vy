# pragma version ~=0.4.0
# SPDX-License-Identifier: MIT

from snekmate.auth import ownable

initializes: ownable

# --- Constants ---
name: public(constant(String[10])) = "ActivePool"
borrower_operations_address: public(address)
trove_manager_address: public(address)
stability_pool_address: public(address)
default_pool_address: public(address)
eth_balance: uint256  # deposited ether tracker
lusd_debt: uint256

# --- Events ---
event BorrowerOperationsAddressChanged:
    new_address: address

event TroveManagerAddressChanged:
    new_address: address

event ActivePoolRDDebtUpdated:
    lusd_debt: uint256

event ActivePoolETHBalanceUpdated:
    eth_balance: uint256

event EtherSent:
    account: address
    amount: uint256

event StabilityPoolAddressChanged:
    new_address: address

event DefaultPoolAddressChanged:
    new_address: address


@deploy
def __init__():
    ownable.__init__()

@view
def _require_caller_is_bo_or_trove_mor_sp():
    assert msg.sender == self.borrower_operations_address or \
           msg.sender == self.trove_manager_address or \
           msg.sender == self.stability_pool_address, "Caller is neither BorrowerOperations, TroveManager nor StabilityPool"

@view
def _require_caller_is_bo_or_trove_m():
    assert msg.sender == self.borrower_operations_address or \
           msg.sender == self.trove_manager_address, "Caller is neither BorrowerOperations nor TroveManager"

@view
def _require_caller_is_borrower_operations_or_default_pool():
    assert msg.sender == self.borrower_operations_address or \
           msg.sender == self.default_pool_address, "Caller is neither BorrowerOperations nor DefaultPool"

# --- Setters for Contract Addresses ---
@external
def set_addresses(
    borrower_operations_address: address, 
    trove_manager_address: address, 
    stability_pool_address: address, 
    default_pool_address: address
):

    ownable._check_owner()
    
    assert borrower_operations_address.is_contract, "ActivePool: borrower operations address is not contract"
    assert trove_manager_address.is_contract, "ActivePool: trove manager address address is not contract"
    assert stability_pool_address.is_contract, "ActivePool: stability pool address is not contract"
    assert default_pool_address.is_contract, "ActivePool: default pool address is not contract"

    self.borrower_operations_address = borrower_operations_address
    self.trove_manager_address = trove_manager_address
    self.stability_pool_address = stability_pool_address
    self.default_pool_address = default_pool_address

    log BorrowerOperationsAddressChanged(borrower_operations_address)
    log TroveManagerAddressChanged(trove_manager_address)
    log StabilityPoolAddressChanged(stability_pool_address)
    log DefaultPoolAddressChanged(default_pool_address)

# --- Getters for public variables. Required by IPool interface ---

##
# Returns the ETH state variable.
#
#Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
##
@external
@view
def get_eth() -> uint256:
    return self.eth_balance

@external
@view
def get_lusd_debt() -> uint256:
    return self.lusd_debt

# --- Pool Functions ---
@external
def send_eth(account: address, amount: uint256):
    self._require_caller_is_bo_or_trove_mor_sp()
    self.eth_balance -= amount
    log ActivePoolETHBalanceUpdated(self.eth_balance)
    log EtherSent(account, amount)
    raw_call(account, b"", value=amount, revert_on_failure=True)
    #send(account, amount)

@external
def increase_lusd_debt(amount: uint256):
    self._require_caller_is_bo_or_trove_m()
    self.lusd_debt += amount
    log ActivePoolRDDebtUpdated(self.lusd_debt)

@external
def decrease_lusd_debt(amount: uint256):
    self._require_caller_is_bo_or_trove_mor_sp()
    self.lusd_debt -= amount
    log ActivePoolRDDebtUpdated(self.lusd_debt)

# --- Fallback Function ---
@external
@payable
def __default__():
    self._require_caller_is_borrower_operations_or_default_pool()
    self.eth_balance += msg.value
    log ActivePoolETHBalanceUpdated(self.eth_balance)

