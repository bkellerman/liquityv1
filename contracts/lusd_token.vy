# SPDX-License-Identifier: MIT
# pragma version ~=0.4.0

from snekmate.tokens import erc20
from snekmate.auth import ownable

initializes: ownable
initializes: erc20[ownable := ownable]

exports: erc20.balanceOf

# Comment from Liquity
# --- Functionality added specific to the LUSDToken ---
# 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external
# transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending LUSD directly to a Liquity
# core contract, when they should rather call the right function.
# 2) sendToPool() and returnFromPool(): functions callable only Liquity core contracts, which move LUSD tokens between Liquity <-> user.
#

# Addresses ---
trove_manager_address: public(immutable(address))
stability_pool_address: public(immutable(address))
borrower_operations_address: public(immutable(address))

# Events
event TroveManagerAddressChanged:
    trove_manager_address: address
event StabilityPoolAddressChanged:
    stability_pool_address: address
event BorrowerOperationsAddressChanged:
    borrower_operations_address: address

@deploy
def __init__(
    _trove_manager_address: address,
    _stability_pool_address: address,
    _borrower_operations_address: address,
):
    ownable.__init__()
    erc20.__init__("LUSD Stablecoin", "LUSD", 18, "Liquity", "1")

    assert _trove_manager_address.is_contract, "Trove Manager Address is not contract"
    assert _stability_pool_address.is_contract, "Stability Pool Address is not contract"
    assert _borrower_operations_address.is_contract, "Borrower Operations Address is not contract"

    trove_manager_address = _trove_manager_address
    stability_pool_address = _stability_pool_address
    borrower_operations_address = _borrower_operations_address

    log TroveManagerAddressChanged(trove_manager_address)
    log StabilityPoolAddressChanged(stability_pool_address)
    log BorrowerOperationsAddressChanged(borrower_operations_address)


@internal
@view
def _require_valid_recipient(_recipient: address):
    assert (
        _recipient != trove_manager_address
        and _recipient != stability_pool_address
        and _recipient != borrower_operations_address
    ), "RD: cannot transfer tokens to trove_manager, stability_pool, or borrower_operations"

@internal
@view
def _require_caller_is_stability_pool():
    assert (
        msg.sender == stability_pool_address
    ), "RD: caller is not stability_pool"


@internal
@view
def _require_caller_is_borrower_operations():
    assert (
        msg.sender == borrower_operations_address
    ), "RD: caller is not borrower_operations"


@internal
@view
def _require_caller_is_trove_mgr_or_stability_pool():
    assert (
        msg.sender == trove_manager_address
        or msg.sender == stability_pool_address
    ), "RD: caller is not trove_manager or istability_pool"

@internal
@view
def _require_caller_is_trove_mgr_or_stability_pool_or_bo():
    assert (
        msg.sender == trove_manager_address
        or msg.sender == stability_pool_address
        or msg.sender == borrower_operations_address
    ), "RD: caller is not trove_manager or stability_pool or borrower operations"

 
@external
def send_to_pool(_sender: address, _pool_address: address, _amount: uint256):
    self._require_caller_is_stability_pool()
    erc20._transfer(_sender, _pool_address, _amount)

@external
def return_from_pool(_pool_address: address, _receiver: address, _amount: uint256):
    self._require_caller_is_trove_mgr_or_stability_pool()
    erc20._transfer(_pool_address, _receiver, _amount)


@external
def transfer(_to: address, _amount: uint256) -> bool:
    self._require_valid_recipient(_to)
    erc20._transfer(msg.sender, _to, _amount)
    return True

@external
def mint(_account: address, _amount: uint256):
    self._require_caller_is_borrower_operations()
    erc20._mint(_account, _amount)

@external
def burn(_account: address, _amount: uint256):
    self._require_caller_is_trove_mgr_or_stability_pool_or_bo()
    erc20._burn(_account, _amount)

@internal
def _transfer_from(owner: address, to: address, amount: uint256):
    erc20._spend_allowance(owner, msg.sender, amount)
    erc20._transfer(owner, to, amount)

@external
def transferFrom(_sender: address, _recipient: address, _amount: uint256) -> bool:
    self._require_valid_recipient(_recipient)
    self._transfer_from(_sender, _recipient, _amount)
    return True

@external
def increase_allowance(spender: address, added_value: uint256) -> bool:
    erc20._approve(msg.sender, spender, erc20.allowance[msg.sender][spender] + added_value)
    return True

@external
def decrease_allowance(spender: address, subtracted_value: uint256) -> bool:
    assert erc20.allowance[msg.sender][spender] - subtracted_value >=0, "ERC20: decreased allowance below zero"
    erc20._approve(msg.sender, spender, erc20.allowance[msg.sender][spender] - subtracted_value)
    return True
